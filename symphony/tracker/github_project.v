module tracker

import json2
import symphony.domain
import symphony.observability

const github_project_page_size = 100
const github_project_max_pages = 100

const github_project_selection = 'projectV2(number: $number) { id number field(name: $statusField) { ... on ProjectV2SingleSelectField { id name options { id name } } } items(first: $first, after: $after, orderBy: {field: POSITION, direction: ASC}) { nodes { id type fieldValueByName(name: $statusField) { ... on ProjectV2ItemFieldSingleSelectValue { name optionId } } content { ... on Issue { id number title body state url createdAt updatedAt repository { nameWithOwner } assignees(first: 1) { nodes { login } } labels(first: 100) { nodes { name } pageInfo { hasNextPage } } } } } pageInfo { hasNextPage endCursor } } }'

const github_project_mutation = 'mutation SymphonyGitHubProjectOutcome($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) { updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: {singleSelectOptionId: $optionId}}) { projectV2Item { id } } }'

struct GitHubProjectVariables {
	owner        string
	number       int
	first        int
	after        json2.Any
	status_field string @[json: statusField]
}

struct GitHubProjectPayload {
	query     string
	variables GitHubProjectVariables
}

struct GitHubProjectMutationVariables {
	project_id string @[json: projectId]
	item_id    string @[json: itemId]
	field_id   string @[json: fieldId]
	option_id  string @[json: optionId]
}

struct GitHubProjectMutationPayload {
	query     string
	variables GitHubProjectMutationVariables
}

struct GitHubProjectSnapshot {
	issues          []domain.Issue
	project_id      string
	status_field_id string
	option_ids      map[string]string
}

struct GitHubProjectPage {
	issues          []domain.Issue
	project_id      string
	status_field_id string
	option_ids      map[string]string
	has_next_page   bool
	end_cursor      string
}

pub struct GitHubProjectClient {
pub:
	endpoint        string
	token           string
	token_env       string
	owner_type      string
	owner           string
	project_number  int
	status_field    string
	state_options   map[string]string
	closed_state    string
	write_outcomes  bool
	success_state   string
	blocked_state   string
	active_states   []string
	terminal_states []string
	transport       GitHubTransport = default_github_transport
}

pub fn (client GitHubProjectClient) fetch_issues_by_states(states []string) ![]domain.Issue {
	if states.len == 0 {
		return []domain.Issue{}
	}
	client.validate()!
	wanted := states.map(domain.normalize_name(it))
	snapshot := client.fetch_snapshot(map[string]bool{})!
	return snapshot.issues.filter(it.normalized_state() in wanted)
}

pub fn (client GitHubProjectClient) fetch_completed_issues(terminal_states []string) ![]domain.Issue {
	states := if client.write_outcomes { [client.success_state] } else { terminal_states }
	return client.fetch_issues_by_states(states)
}

pub fn (client GitHubProjectClient) fetch_issues_by_ids(ids []string) ![]domain.Issue {
	if ids.len == 0 {
		return []domain.Issue{}
	}
	client.validate()!
	mut unique_ids := []string{}
	mut strict_ids := map[string]bool{}
	for id in ids {
		parse_github_project_issue_id(id)!
		if id !in unique_ids {
			unique_ids << id
			strict_ids[id] = true
		}
	}
	snapshot := client.fetch_snapshot(strict_ids)!
	mut by_id := map[string]domain.Issue{}
	for issue in snapshot.issues {
		by_id[issue.id] = issue
	}
	mut ordered := []domain.Issue{}
	for id in unique_ids {
		if issue := by_id[id] {
			ordered << issue
		}
	}
	return ordered
}

pub fn (client GitHubProjectClient) record_outcome(issue domain.Issue, outcome domain.AttemptOutcome) !bool {
	client.validate()!
	if issue.id == '' || outcome.issue_id != issue.id {
		return error('tracker_outcome: GitHub Project outcome identity does not match the issue')
	}
	if !client.write_outcomes {
		return false
	}
	target_state := match outcome.kind {
		.succeeded { client.success_state }
		.blocked { client.blocked_state }
		else { return false }
	}
	snapshot := client.fetch_snapshot({
		issue.id: true
	})!
	current := snapshot.issues.filter(it.id == issue.id)
	if current.len != 1 {
		return error('tracker_outcome: GitHub Project issue is no longer in the configured project')
	}
	option_name := client.option_for_state(target_state)!
	option_id := snapshot.option_ids[domain.normalize_name(option_name)] or {
		return error('tracker_response: GitHub Project status option was not returned by the provider')
	}
	item_id := string_value(current[0].native_ref, 'project_item_id')
	if item_id == '' || snapshot.project_id == '' || snapshot.status_field_id == '' {
		return error('tracker_response: GitHub Project outcome metadata was incomplete')
	}
	payload := json2.encode(GitHubProjectMutationPayload{
		query:     github_project_mutation
		variables: GitHubProjectMutationVariables{
			project_id: snapshot.project_id
			item_id:    item_id
			field_id:   snapshot.status_field_id
			option_id:  option_id
		}
	})
	response := client.request(payload)!
	client.ensure_graphql_success(response.body, item_id)!
	return outcome.kind == .succeeded
}

pub fn (client GitHubProjectClient) secret_environment_names() []string {
	return if client.token_env == '' { []string{} } else { [client.token_env] }
}

pub fn (client GitHubProjectClient) secret_values() []string {
	return if client.token == '' { []string{} } else { [client.token] }
}

// validate_scope verifies the project, status field, and configured options live.
pub fn (client GitHubProjectClient) validate_scope() ! {
	client.validate()!
	client.fetch_page('', map[string]bool{})!
}

fn (client GitHubProjectClient) fetch_snapshot(strict_ids map[string]bool) !GitHubProjectSnapshot {
	mut cursor := ''
	mut seen_cursors := map[string]bool{}
	mut issues := []domain.Issue{}
	mut project_id := ''
	mut status_field_id := ''
	mut option_ids := map[string]string{}
	for _ in 0 .. github_project_max_pages {
		page := client.fetch_page(cursor, strict_ids)!
		if project_id == '' {
			project_id = page.project_id
			status_field_id = page.status_field_id
			option_ids = page.option_ids.clone()
		} else if page.project_id != project_id || page.status_field_id != status_field_id
			|| !github_string_maps_equal(page.option_ids, option_ids) {
			return error('tracker_response: GitHub Project scope changed during pagination')
		}
		issues << page.issues
		if !page.has_next_page {
			mut ranked := []domain.Issue{cap: issues.len}
			for index, issue in issues {
				ranked << domain.Issue{
					...issue
					queue_rank: index
				}
			}
			return GitHubProjectSnapshot{
				issues:          ranked
				project_id:      project_id
				status_field_id: status_field_id
				option_ids:      option_ids
			}
		}
		if page.end_cursor == '' {
			return error('tracker_pagination: GitHub Project response omitted endCursor')
		}
		if seen_cursors[page.end_cursor] {
			return error('tracker_pagination: GitHub Project repeated an endCursor')
		}
		seen_cursors[page.end_cursor] = true
		cursor = page.end_cursor
	}
	return error('tracker_pagination: GitHub Project pagination exceeded ${github_project_max_pages} pages')
}

fn (client GitHubProjectClient) fetch_page(after string, strict_ids map[string]bool) !GitHubProjectPage {
	after_value := if after == '' { json2.Any(json2.null) } else { json2.Any(after) }
	payload := json2.encode(GitHubProjectPayload{
		query:     client.project_query()!
		variables: GitHubProjectVariables{
			owner:        client.owner
			number:       client.project_number
			first:        github_project_page_size
			after:        after_value
			status_field: client.status_field
		}
	})
	response := client.request(payload)!
	return client.decode_page(response.body, strict_ids)
}

fn (client GitHubProjectClient) project_query() !string {
	root := match client.owner_type {
		'organization' { 'organization' }
		'user' { 'user' }
		else { return error('invalid_tracker_config: GitHub Project owner_type must be organization or user') }
	}
	return 'query SymphonyGitHubProject($owner: String!, $number: Int!, $first: Int!, $after: String, $statusField: String!) { ${root}(login: $owner) { ${github_project_selection} } }'
}

fn (client GitHubProjectClient) request(body string) !GitHubResponse {
	response := client.transport(GitHubRequest{
		method: 'POST'
		url:    client.endpoint
		token:  client.token
		body:   body
	}) or { return error('tracker_request: GitHub Project transport failed') }
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
			return error('tracker_permission: GitHub denied access to the configured project')
		}
		429 {
			return error('tracker_rate_limited: GitHub rate limit was reached')
		}
		else {
			return error('tracker_status: GitHub returned HTTP ${response.status}')
		}
	}
}

fn (client GitHubProjectClient) decode_page(body string, strict_ids map[string]bool) !GitHubProjectPage {
	root := client.decode_graphql_root(body)!
	data := map_value(root, 'data')
	owner := map_value(data, client.owner_type)
	project := map_value(owner, 'projectV2')
	project_id := string_value(project, 'id').trim_space()
	if project_id == '' || github_int_value(project, 'number') != client.project_number {
		return error('tracker_scope: GitHub Project was not found under the configured owner')
	}
	field := map_value(project, 'field')
	status_field_id := string_value(field, 'id').trim_space()
	if status_field_id == ''
		|| domain.normalize_name(string_value(field, 'name')) != domain.normalize_name(client.status_field) {
		return error('tracker_scope: GitHub Project status field was not found or is not single-select')
	}
	options := github_required_array(field, 'options',
		'data.${client.owner_type}.projectV2.field.options')!
	mut option_ids := map[string]string{}
	for option_value in options {
		if option_value !is map[string]json2.Any {
			return error('tracker_response: GitHub Project status options must be objects')
		}
		option := option_value.as_map()
		name := string_value(option, 'name').trim_space()
		id := string_value(option, 'id').trim_space()
		if name != '' && id != '' {
			option_ids[domain.normalize_name(name)] = id
		}
	}
	client.validate_provider_options(option_ids)!
	items := github_required_map(project, 'items', 'data.${client.owner_type}.projectV2.items')!
	nodes := github_required_array(items, 'nodes',
		'data.${client.owner_type}.projectV2.items.nodes')!
	mut issues := []domain.Issue{}
	for item_value in nodes {
		if item_value !is map[string]json2.Any {
			return error('tracker_response: GitHub Project item nodes must be objects')
		}
		item := item_value.as_map()
		if string_value(item, 'type') != 'ISSUE' {
			continue
		}
		issue := client.normalize_project_issue(item, project_id, status_field_id) or {
			malformed_id := github_project_item_issue_id(item)
			if malformed_id in strict_ids {
				return error('tracker_response: GitHub Project returned a malformed requested issue record')
			}
			observability.emit(observability.Record{
				level:            'warn'
				event:            'tracker_record_omitted'
				issue_identifier: malformed_id.trim_string_left('github:')
				message:          'GitHub Project issue omitted because its content or status was malformed'
			}, client.secret_values())
			continue
		}
		issues << issue
	}
	page_info := github_required_map(items, 'pageInfo',
		'data.${client.owner_type}.projectV2.items.pageInfo')!
	has_next_page := github_required_bool(page_info, 'hasNextPage',
		'data.${client.owner_type}.projectV2.items.pageInfo.hasNextPage')!
	return GitHubProjectPage{
		issues:          issues
		project_id:      project_id
		status_field_id: status_field_id
		option_ids:      option_ids
		has_next_page:   has_next_page
		end_cursor:      string_value(page_info, 'endCursor')
	}
}

fn github_project_item_issue_id(item map[string]json2.Any) string {
	content := map_value(item, 'content')
	repository := string_value(map_value(content, 'repository'), 'nameWithOwner').trim_space()
	number := github_int_value(content, 'number')
	if repository == '' || number <= 0 {
		return ''
	}
	return github_issue_id(repository, number)
}

fn (client GitHubProjectClient) normalize_project_issue(item map[string]json2.Any, project_id string, status_field_id string) !domain.Issue {
	project_item_id := string_value(item, 'id').trim_space()
	status_value := map_value(item, 'fieldValueByName')
	option_name := string_value(status_value, 'name').trim_space()
	option_id := string_value(status_value, 'optionId').trim_space()
	content := map_value(item, 'content')
	repository := string_value(map_value(content, 'repository'), 'nameWithOwner').trim_space()
	validate_github_repository(repository)!
	number := github_int_value(content, 'number')
	title := string_value(content, 'title').trim_space()
	provider_state := string_value(content, 'state').trim_space().to_upper()
	url := string_value(content, 'url').trim_space()
	github_node_id := string_value(content, 'id').trim_space()
	created_at := valid_timestamp(string_value(content, 'createdAt'))
	updated_at := valid_timestamp(string_value(content, 'updatedAt'))
	if project_item_id == '' || number <= 0 || title == ''
		|| provider_state !in ['OPEN', 'CLOSED'] || url == '' || github_node_id == ''
		|| created_at == '' || updated_at == ''
		|| (provider_state == 'OPEN' && (option_name == '' || option_id == '')) {
		return error('malformed project issue')
	}
	state := if provider_state == 'CLOSED' {
		client.closed_state
	} else {
		client.state_for_option(option_name)!
	}
	labels_connection := github_required_map(content, 'labels', 'Project Issue labels')!
	if github_required_bool(github_required_map(labels_connection, 'pageInfo',
		'Project Issue labels.pageInfo')!, 'hasNextPage',
		'Project Issue labels.pageInfo.hasNextPage')!
	{
		return error('Project Issue labels exceeded the bounded query')
	}
	label_nodes := github_required_array(labels_connection, 'nodes', 'Project Issue labels.nodes')!
	mut labels := []string{cap: label_nodes.len}
	for label_value in label_nodes {
		if label_value !is map[string]json2.Any {
			return error('Project Issue label nodes must be objects')
		}
		labels << string_value(label_value.as_map(), 'name')
	}
	assignees_connection := github_required_map(content, 'assignees', 'Project Issue assignees')!
	assignees := github_required_array(assignees_connection, 'nodes',
		'Project Issue assignees.nodes')!
	if assignees.len > 0 && assignees[0] !is map[string]json2.Any {
		return error('Project Issue assignee nodes must be objects')
	}
	assignee := if assignees.len == 0 { '' } else { string_value(assignees[0].as_map(), 'login') }
	id := github_issue_id(repository, number)
	return domain.Issue{
		id:           id
		identifier:   '${repository}#${number}'
		title:        title
		description:  string_value(content, 'body')
		state:        state
		url:          url
		labels:       domain.normalize_labels(labels)
		created_at:   created_at
		updated_at:   updated_at
		assignee_id:  assignee
		native_ref:   {
			'github_node_id':   json2.Any(github_node_id)
			'repository':       json2.Any(repository)
			'number':           json2.Any(number)
			'project_id':       json2.Any(project_id)
			'project_number':   json2.Any(client.project_number)
			'project_item_id':  json2.Any(project_item_id)
			'status_field_id':  json2.Any(status_field_id)
			'status_option_id': json2.Any(option_id)
		}
		dispatchable: provider_state == 'OPEN'
			&& domain.normalize_name(state) in client.active_states.map(domain.normalize_name(it))
	}
}

fn (client GitHubProjectClient) decode_graphql_root(body string) !map[string]json2.Any {
	decoded := json2.decode[json2.Any](body) or {
		return error('tracker_response: GitHub Project response was not valid JSON')
	}
	if decoded !is map[string]json2.Any {
		return error('tracker_response: GitHub Project response must be an object')
	}
	root := decoded.as_map()
	if errors_value := root['errors'] {
		if errors_value !is []json2.Any {
			return error('tracker_response: GitHub Project GraphQL errors must be an array')
		}
		errors := errors_value.as_array()
		if errors.len > 0 {
			mut error_types := []string{}
			for error_value in errors {
				if error_value !is map[string]json2.Any {
					return error('tracker_response: GitHub Project GraphQL errors must be objects')
				}
				error_types << string_value(error_value.as_map(), 'type').trim_space().to_upper()
			}
			if 'RATE_LIMITED' in error_types {
				return error('tracker_rate_limited: GitHub Project GraphQL rate limit was reached')
			}
			if 'FORBIDDEN' in error_types {
				return error('tracker_permission: GitHub denied access to the configured project')
			}
			if 'NOT_FOUND' in error_types {
				return error('tracker_scope: GitHub Project was not found under the configured owner')
			}
			return error('tracker_response: GitHub Project returned GraphQL errors')
		}
	}
	return root
}

fn (client GitHubProjectClient) ensure_graphql_success(body string, expected_item_id string) ! {
	root := client.decode_graphql_root(body)!
	updated := map_value(map_value(root, 'data'), 'updateProjectV2ItemFieldValue')
	if string_value(map_value(updated, 'projectV2Item'), 'id').trim_space() != expected_item_id {
		return error('tracker_response: GitHub Project outcome response identified the wrong item')
	}
}

fn github_required_map(values map[string]json2.Any, key string, path string) !map[string]json2.Any {
	value := values[key] or {
		return error('tracker_response: GitHub Project response omitted ${path}')
	}
	if value !is map[string]json2.Any {
		return error('tracker_response: GitHub Project ${path} must be an object')
	}
	return value.as_map()
}

fn github_required_array(values map[string]json2.Any, key string, path string) ![]json2.Any {
	value := values[key] or {
		return error('tracker_response: GitHub Project response omitted ${path}')
	}
	if value !is []json2.Any {
		return error('tracker_response: GitHub Project ${path} must be an array')
	}
	return value.as_array()
}

fn github_required_bool(values map[string]json2.Any, key string, path string) !bool {
	value := values[key] or {
		return error('tracker_response: GitHub Project response omitted ${path}')
	}
	if value is bool {
		return value
	}
	return error('tracker_response: GitHub Project ${path} must be a boolean')
}

fn github_string_maps_equal(left map[string]string, right map[string]string) bool {
	if left.len != right.len {
		return false
	}
	for key, value in left {
		if right[key] or { return false } != value {
			return false
		}
	}
	return true
}

fn (client GitHubProjectClient) state_for_option(option string) !string {
	normalized := domain.normalize_name(option)
	for state, configured_option in client.state_options {
		if domain.normalize_name(configured_option) == normalized {
			return state.trim_space()
		}
	}
	return error('unmapped project status')
}

fn (client GitHubProjectClient) option_for_state(state string) !string {
	normalized := domain.normalize_name(state)
	for configured_state, option in client.state_options {
		if domain.normalize_name(configured_state) == normalized {
			return option.trim_space()
		}
	}
	return error('invalid_tracker_config: GitHub Project outcome state has no status option mapping')
}

fn (client GitHubProjectClient) validate_provider_options(option_ids map[string]string) ! {
	for _, configured_option in client.state_options {
		if domain.normalize_name(configured_option) !in option_ids {
			return error('tracker_scope: GitHub Project status option `${configured_option}` was not found')
		}
	}
}

fn (client GitHubProjectClient) validate() ! {
	if client.endpoint.trim_space() == '' {
		return error('invalid_tracker_config: GitHub endpoint is required')
	}
	if client.token.trim_space() == '' {
		return error('missing_tracker_secret: GitHub token is required')
	}
	client.project_query()!
	validate_github_owner(client.owner)!
	if client.project_number <= 0 {
		return error('invalid_tracker_config: GitHub project_number must be positive')
	}
	if client.status_field.trim_space() == '' || client.state_options.len == 0 {
		return error('invalid_tracker_config: GitHub Project status_field and state_options are required')
	}
	mut normalized_states := map[string]bool{}
	mut normalized_options := map[string]bool{}
	for state, option in client.state_options {
		state_key := domain.normalize_name(state)
		option_key := domain.normalize_name(option)
		if state_key == '' || option_key == '' || normalized_states[state_key]
			|| normalized_options[option_key] {
			return error('invalid_tracker_config: GitHub Project state and status option mappings must be unique and non-empty')
		}
		normalized_states[state_key] = true
		normalized_options[option_key] = true
	}
	for state in client.active_states {
		if domain.normalize_name(state) !in normalized_states {
			return error('invalid_tracker_config: every active GitHub Project state needs a status option mapping')
		}
	}
	if domain.normalize_name(client.closed_state) !in client.terminal_states.map(domain.normalize_name(it)) {
		return error('invalid_tracker_config: GitHub Project closed_state must be terminal')
	}
	if client.write_outcomes {
		client.validate_outcome_state('success_state', client.success_state, normalized_states)!
		client.validate_outcome_state('blocked_state', client.blocked_state, normalized_states)!
		if domain.normalize_name(client.success_state) == domain.normalize_name(client.blocked_state) {
			return error('invalid_tracker_config: GitHub Project success_state and blocked_state must differ')
		}
	}
}

fn (client GitHubProjectClient) validate_outcome_state(field string, state string, normalized_states map[string]bool) ! {
	key := domain.normalize_name(state)
	if key == '' || key !in normalized_states {
		return error('invalid_tracker_config: GitHub Project ${field} needs a status option mapping')
	}
	if key in client.active_states.map(domain.normalize_name(it))
		|| key !in client.terminal_states.map(domain.normalize_name(it)) {
		return error('invalid_tracker_config: GitHub Project ${field} must be terminal and not active')
	}
}

fn validate_github_owner(owner string) ! {
	trimmed := owner.trim_space()
	if trimmed == '' || trimmed.contains('/') || trimmed.contains(' ') || trimmed.starts_with('-')
		|| trimmed.ends_with('-') {
		return error('invalid_tracker_config: GitHub Project owner must be a user or organization login')
	}
	for value in trimmed.bytes() {
		if !((value >= `A` && value <= `Z`) || (value >= `a` && value <= `z`)
			|| (value >= `0` && value <= `9`) || value == `-`) {
			return error('invalid_tracker_config: GitHub Project owner must be a user or organization login')
		}
	}
}

fn parse_github_project_issue_id(id string) !(string, int) {
	if !id.starts_with('github:') {
		return error('invalid_tracker_id: GitHub Project issue ID is invalid')
	}
	separator := id.last_index('#') or {
		return error('invalid_tracker_id: GitHub Project issue ID is invalid')
	}
	repository := id['github:'.len..separator]
	validate_github_repository(repository)!
	number_text := id[separator + 1..]
	number := number_text.int()
	if number <= 0 || number.str() != number_text {
		return error('invalid_tracker_id: GitHub Project issue ID has an invalid issue number')
	}
	return repository, number
}
