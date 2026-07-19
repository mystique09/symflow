module tracker

import json2
import net.http
import strconv
import time
import symphony.domain
import symphony.observability

const github_page_size = 100
const github_max_pages = 100

pub struct GitHubRequest {
pub:
	method string
	url    string
	token  string
	body   string
}

pub struct GitHubResponse {
pub:
	status       int
	body         string
	next_url     string
	rate_limited bool
}

pub type GitHubTransport = fn (request GitHubRequest) !GitHubResponse

pub struct GitHubClient {
pub:
	endpoint        string
	token           string
	token_env       string
	repository      string
	state_labels    map[string]string
	closed_state    string
	write_outcomes  bool
	success_state   string
	blocked_state   string
	active_states   []string
	terminal_states []string
	transport       GitHubTransport = default_github_transport
}

struct GitHubLabelsPayload {
	labels []string
}

fn default_github_transport(request GitHubRequest) !GitHubResponse {
	method := match request.method {
		'GET' { http.Method.get }
		'PATCH' { http.Method.patch }
		else { return error('unsupported GitHub HTTP method') }
	}
	mut header := http.new_header()
	header.add_custom('Accept', 'application/vnd.github+json')!
	header.add_custom('Authorization', 'Bearer ${request.token}')!
	header.add_custom('X-GitHub-Api-Version', '2022-11-28')!
	header.add_custom('User-Agent', 'symphony-tracker')!
	if request.body != '' {
		header.add_custom('Content-Type', 'application/json')!
	}
	response := http.fetch(
		url:                  request.url
		method:               method
		header:               header
		data:                 request.body
		read_timeout:         i64(30 * time.second)
		write_timeout:        i64(30 * time.second)
		stop_receiving_limit: 8 * 1024 * 1024
	) or { return error('GitHub HTTP request failed') }
	link := response.header.get(.link) or { '' }
	remaining := response.header.get_custom('X-RateLimit-Remaining', http.HeaderQueryConfig{}) or {
		''
	}
	return GitHubResponse{
		status:       response.status_code
		body:         response.body
		next_url:     github_next_link(link)
		rate_limited: response.status_code == 403 && remaining == '0'
	}
}

fn github_next_link(header string) string {
	for part in header.split(',') {
		trimmed := part.trim_space()
		if !trimmed.contains('rel="next"') {
			continue
		}
		open := trimmed.index('<') or { return '' }
		close := trimmed.index_after('>', open + 1) or { return '' }
		if close <= open + 1 {
			return ''
		}
		return trimmed[open + 1..close]
	}
	return ''
}

pub fn (client GitHubClient) fetch_issues_by_states(states []string) ![]domain.Issue {
	if states.len == 0 {
		return []domain.Issue{}
	}
	client.validate()!
	wanted := states.map(domain.normalize_name(it))
	mut url := '${client.endpoint}/repos/${client.repository}/issues?state=all&per_page=${github_page_size}'
	mut seen_urls := map[string]bool{}
	mut issues := []domain.Issue{}
	for page := 0; page < github_max_pages; page++ {
		if seen_urls[url] {
			return error('tracker_pagination: GitHub repeated a pagination URL')
		}
		seen_urls[url] = true
		response := client.request('GET', url, '')!
		for issue in client.decode_issue_list(response.body, false)! {
			if issue.normalized_state() in wanted {
				issues << issue
			}
		}
		if response.next_url == '' {
			issues.sort_with_compare(fn (left &domain.Issue, right &domain.Issue) int {
				return github_issue_number(*left) - github_issue_number(*right)
			})
			return issues
		}
		client.validate_page_url(response.next_url)!
		url = response.next_url
	}
	return error('tracker_pagination: GitHub issue pagination exceeded ${github_max_pages} pages')
}

fn (client GitHubClient) validate_page_url(url string) ! {
	allowed_prefix := '${client.endpoint}/repos/${client.repository}/issues?'
	if !url.starts_with(allowed_prefix) {
		return error('tracker_pagination: GitHub pagination URL escaped the configured repository scope')
	}
}

fn (client GitHubClient) request(method string, url string, body string) !GitHubResponse {
	response := client.send(GitHubRequest{
		method: method
		url:    url
		token:  client.token
		body:   body
	})!
	return client.check_response(response)
}

fn (client GitHubClient) send(request GitHubRequest) !GitHubResponse {
	return client.transport(request) or { return error('tracker_request: GitHub transport failed') }
}

fn (client GitHubClient) check_response(response GitHubResponse) !GitHubResponse {
	match response.status {
		200 {
			return response
		}
		401 {
			return error('tracker_authentication: GitHub rejected the configured credential')
		}
		403 {
			if response.rate_limited {
				return error('tracker_rate_limited: GitHub rate limit was reached')
			}
			return error('tracker_permission: GitHub denied access to the configured repository')
		}
		429 {
			return error('tracker_rate_limited: GitHub rate limit was reached')
		}
		else {
			return error('tracker_status: GitHub returned HTTP ${response.status}')
		}
	}
}

fn (client GitHubClient) decode_single_issue(body string) !domain.Issue {
	decoded := json2.decode[json2.Any](body) or {
		return error('tracker_response: GitHub response was not valid JSON')
	}
	if decoded !is map[string]json2.Any {
		return error('tracker_response: GitHub issue response must be an object')
	}
	node := decoded.as_map()
	if _ := node['pull_request'] {
		return error('tracker_response: GitHub requested issue resolved to a pull request')
	}
	return client.normalize_issue(node) or {
		return error('tracker_response: GitHub returned an ambiguous or malformed requested issue record')
	}
}

fn (client GitHubClient) decode_issue_list(body string, strict bool) ![]domain.Issue {
	decoded := json2.decode[json2.Any](body) or {
		return error('tracker_response: GitHub response was not valid JSON')
	}
	if decoded !is []json2.Any {
		return error('tracker_response: GitHub issue-list response must be an array')
	}
	mut issues := []domain.Issue{}
	mut malformed := 0
	for node_value in decoded.as_array() {
		node := node_value.as_map()
		if _ := node['pull_request'] {
			continue
		}
		issue := client.normalize_issue(node) or {
			malformed++
			if !strict {
				observability.emit(observability.Record{
					level:            'warn'
					event:            'tracker_record_omitted'
					issue_identifier: '${client.repository}#${github_int_value(node, 'number')}'
					message:          'GitHub candidate omitted because its workflow state was missing, conflicting, or malformed'
				}, client.secret_values())
			}
			continue
		}
		issues << issue
	}
	if strict && malformed > 0 {
		return error('tracker_response: GitHub returned an ambiguous or malformed requested issue record')
	}
	return issues
}

fn (client GitHubClient) normalize_issue(node map[string]json2.Any) !domain.Issue {
	number := github_int_value(node, 'number')
	title := string_value(node, 'title').trim_space()
	provider_state := string_value(node, 'state').trim_space().to_lower()
	if number <= 0 || title == '' || provider_state !in ['open', 'closed'] {
		return error('malformed issue')
	}
	status_by_label := client.status_by_label()
	mut recognized_states := []string{}
	mut routing_labels := []string{}
	for label in github_label_names(node) {
		normalized_label := domain.normalize_name(label)
		if state := status_by_label[normalized_label] {
			if state !in recognized_states {
				recognized_states << state
			}
		} else {
			routing_labels << label
		}
	}
	state := if provider_state == 'closed' {
		client.closed_state
	} else {
		if recognized_states.len != 1 {
			return error('ambiguous workflow state')
		}
		recognized_states[0]
	}
	assignee := map_value(node, 'assignee')
	id := github_issue_id(client.repository, number)
	return domain.Issue{
		id:           id
		identifier:   '${client.repository}#${number}'
		title:        title
		description:  string_value(node, 'body')
		state:        state
		url:          string_value(node, 'html_url')
		labels:       domain.normalize_labels(routing_labels)
		created_at:   valid_timestamp(string_value(node, 'created_at'))
		updated_at:   valid_timestamp(string_value(node, 'updated_at'))
		assignee_id:  string_value(assignee, 'login')
		native_ref:   {
			'github_node_id': json2.Any(string_value(node, 'node_id'))
			'repository':     json2.Any(client.repository)
			'number':         json2.Any(number)
		}
		dispatchable: provider_state == 'open'
			&& domain.normalize_name(state) in client.active_states.map(domain.normalize_name(it))
	}
}

fn (client GitHubClient) status_by_label() map[string]string {
	mut result := map[string]string{}
	for state, label in client.state_labels {
		result[domain.normalize_name(label)] = state.trim_space()
	}
	return result
}

fn github_label_names(node map[string]json2.Any) []string {
	mut labels := []string{}
	for label_value in array_value(node, 'labels') {
		if label_value is string {
			labels << label_value
		} else {
			labels << string_value(label_value.as_map(), 'name')
		}
	}
	return labels
}

fn github_issue_id(repository string, number int) string {
	return 'github:${repository}#${number}'
}

fn parse_github_issue_id(id string, repository string) !int {
	prefix := 'github:${repository}#'
	if !id.starts_with(prefix) {
		return error('invalid_tracker_id: GitHub issue ID is outside repository `${repository}`')
	}
	number_text := id[prefix.len..]
	number := strconv.atoi(number_text) or {
		return error('invalid_tracker_id: GitHub issue ID has an invalid issue number')
	}
	if number <= 0 || number_text != number.str() {
		return error('invalid_tracker_id: GitHub issue ID has an invalid issue number')
	}
	return number
}

fn github_issue_number(issue domain.Issue) int {
	return (issue.native_ref['number'] or { return 0 }).int()
}

fn github_int_value(values map[string]json2.Any, key string) int {
	value := values[key] or { return -1 }
	return value.int()
}

pub fn (client GitHubClient) fetch_issues_by_ids(ids []string) ![]domain.Issue {
	if ids.len == 0 {
		return []domain.Issue{}
	}
	client.validate()!
	mut issues := []domain.Issue{}
	mut seen := map[string]bool{}
	for id in ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		number := parse_github_issue_id(id, client.repository)!
		response := client.send(GitHubRequest{
			method: 'GET'
			url:    '${client.endpoint}/repos/${client.repository}/issues/${number}'
			token:  client.token
		})!
		if response.status == 404 {
			continue
		}
		checked := client.check_response(response)!
		issue := client.decode_single_issue(checked.body)!
		if issue.id != id {
			return error('tracker_response: GitHub returned a different requested issue')
		}
		issues << issue
	}
	return issues
}

pub fn (client GitHubClient) record_outcome(issue domain.Issue, outcome domain.AttemptOutcome) !bool {
	client.validate()!
	if issue.id == '' || outcome.issue_id != issue.id {
		return error('tracker_outcome: GitHub outcome identity does not match the issue')
	}
	if !client.write_outcomes {
		return false
	}
	target_state := match outcome.kind {
		.succeeded { client.success_state }
		.blocked { client.blocked_state }
		else { return false }
	}
	number := parse_github_issue_id(issue.id, client.repository)!
	url := '${client.endpoint}/repos/${client.repository}/issues/${number}'
	current := client.request('GET', url, '')!
	decoded := json2.decode[json2.Any](current.body) or {
		return error('tracker_response: GitHub response was not valid JSON')
	}
	if decoded !is map[string]json2.Any {
		return error('tracker_response: GitHub issue response must be an object')
	}
	node := decoded.as_map()
	if _ := node['pull_request'] {
		return error('tracker_response: GitHub requested issue resolved to a pull request')
	}
	if github_int_value(node, 'number') != number {
		return error('tracker_response: GitHub returned a different requested issue')
	}
	status_by_label := client.status_by_label()
	mut labels := []string{}
	for label in github_label_names(node) {
		if domain.normalize_name(label) !in status_by_label && label.trim_space() != '' {
			labels << label
		}
	}
	labels << client.label_for_state(target_state)!
	client.request('PATCH', url, json2.encode(GitHubLabelsPayload{
		labels: labels
	}))!
	return outcome.kind == .succeeded
}

fn (client GitHubClient) label_for_state(state string) !string {
	normalized := domain.normalize_name(state)
	for configured_state, label in client.state_labels {
		if domain.normalize_name(configured_state) == normalized {
			return label.trim_space()
		}
	}
	return error('invalid_tracker_config: GitHub outcome state has no status label mapping')
}

pub fn (client GitHubClient) secret_environment_names() []string {
	return if client.token_env == '' { []string{} } else { [client.token_env] }
}

pub fn (client GitHubClient) secret_values() []string {
	return if client.token == '' { []string{} } else { [client.token] }
}

fn (client GitHubClient) validate() ! {
	if client.endpoint.trim_space() == '' {
		return error('invalid_tracker_config: GitHub endpoint is required')
	}
	if client.token.trim_space() == '' {
		return error('missing_tracker_secret: GitHub token is required')
	}
	validate_github_repository(client.repository)!
	if client.state_labels.len == 0 {
		return error('invalid_tracker_config: GitHub state_labels are required')
	}
	mut normalized_states := map[string]bool{}
	mut normalized_labels := map[string]bool{}
	for state, label in client.state_labels {
		normalized_state := domain.normalize_name(state)
		normalized_label := domain.normalize_name(label)
		if normalized_state == '' || normalized_label == '' {
			return error('invalid_tracker_config: GitHub state_labels cannot contain blank states or labels')
		}
		if normalized_states[normalized_state] || normalized_labels[normalized_label] {
			return error('invalid_tracker_config: GitHub state_labels must map unique states to unique labels')
		}
		normalized_states[normalized_state] = true
		normalized_labels[normalized_label] = true
	}
	for state in client.active_states {
		if !normalized_states[domain.normalize_name(state)] {
			return error('invalid_tracker_config: GitHub active state `${state}` has no status label')
		}
	}
	if client.closed_state.trim_space() == ''
		|| domain.normalize_name(client.closed_state) !in client.terminal_states.map(domain.normalize_name(it)) {
		return error('invalid_tracker_config: GitHub closed_state must be a configured terminal state')
	}
	if client.write_outcomes {
		client.validate_outcome_state(client.success_state, 'success_state', normalized_states)!
		client.validate_outcome_state(client.blocked_state, 'blocked_state', normalized_states)!
	}
}

fn (client GitHubClient) validate_outcome_state(state string, key string, mapped_states map[string]bool) ! {
	normalized := domain.normalize_name(state)
	if normalized == '' || !mapped_states[normalized] {
		return error('invalid_tracker_config: GitHub ${key} must have a status label mapping')
	}
	if normalized in client.active_states.map(domain.normalize_name(it))
		|| normalized !in client.terminal_states.map(domain.normalize_name(it)) {
		return error('invalid_tracker_config: GitHub ${key} must be terminal and not active')
	}
}

fn validate_github_repository(repository string) ! {
	parts := repository.trim_space().split('/')
	if parts.len != 2 || !valid_github_owner(parts[0]) || !valid_github_repo_name(parts[1]) {
		return error('invalid_tracker_config: GitHub repository must use `owner/name` syntax')
	}
}

fn valid_github_owner(value string) bool {
	if value == '' || value.len > 39 || value.starts_with('-') || value.ends_with('-') {
		return false
	}
	for character in value {
		if !character.is_alnum() && character != `-` {
			return false
		}
	}
	return true
}

fn valid_github_repo_name(value string) bool {
	if value == '' || value.len > 100 || value == '.' || value == '..' {
		return false
	}
	for character in value {
		if !character.is_alnum() && character !in [`.`, `-`, `_`] {
			return false
		}
	}
	return true
}
