module tracker

import json2
import net.http
import symphony.domain
import symphony.observability
import time

const issue_page_size = 50
const relation_page_size = 50

const candidate_query = 'query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) { issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) { nodes { id identifier title description priority state { name } branchName url assignee { id } labels { nodes { name } } inverseRelations(first: $relationFirst) { nodes { type issue { id identifier state { name } } } } createdAt updatedAt } pageInfo { hasNextPage endCursor } } }'

const issues_by_id_query = 'query SymphonyLinearIssuesById($ids: [ID!]!, $projectSlug: String!, $first: Int!, $relationFirst: Int!) { issues(filter: {id: {in: $ids}, project: {slugId: {eq: $projectSlug}}}, first: $first) { nodes { id identifier title description priority state { name } branchName url assignee { id } labels { nodes { name } } inverseRelations(first: $relationFirst) { nodes { type issue { id identifier state { name } } } } createdAt updatedAt } } }'

const team_candidate_query = 'query SymphonyLinearTeamPoll($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) { issues(filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) { nodes { id identifier title description priority state { name } branchName url assignee { id } labels { nodes { name } } inverseRelations(first: $relationFirst) { nodes { type issue { id identifier state { name } } } } createdAt updatedAt } pageInfo { hasNextPage endCursor } } }'

const team_issues_by_id_query = 'query SymphonyLinearTeamIssuesById($ids: [ID!]!, $teamKey: String!, $first: Int!, $relationFirst: Int!) { issues(filter: {id: {in: $ids}, team: {key: {eq: $teamKey}}}, first: $first) { nodes { id identifier title description priority state { name } branchName url assignee { id } labels { nodes { name } } inverseRelations(first: $relationFirst) { nodes { type issue { id identifier state { name } } } } createdAt updatedAt } } }'

const project_scope_query = 'query SymphonyLinearProjectScope($projectSlug: String!) { projects(filter: {slugId: {eq: $projectSlug}}, first: 1) { nodes { id } } }'
const team_scope_query = 'query SymphonyLinearTeamScope($teamKey: String!) { teams(filter: {key: {eq: $teamKey}}, first: 1) { nodes { id } } }'

pub struct TransportResponse {
pub:
	status int
	body   string
}

pub type GraphqlTransport = fn (endpoint string, api_key string, body string) !TransportResponse

pub struct LinearClient {
pub:
	endpoint        string
	api_key         string
	project_slug    string
	team_key        string
	assignee        string
	active_states   []string
	terminal_states []string         = ['Closed', 'Cancelled', 'Canceled', 'Duplicate', 'Done']
	api_key_env     string           = 'LINEAR_API_KEY'
	transport       GraphqlTransport = default_graphql_transport
}

struct CandidateVariables {
	project_slug   string   @[json: projectSlug]
	state_names    []string @[json: stateNames]
	first          int
	relation_first int @[json: relationFirst]
	after          json2.Any
}

struct CandidatePayload {
	query     string
	variables CandidateVariables
}

struct TeamCandidateVariables {
	team_key       string   @[json: teamKey]
	state_names    []string @[json: stateNames]
	first          int
	relation_first int @[json: relationFirst]
	after          json2.Any
}

struct TeamCandidatePayload {
	query     string
	variables TeamCandidateVariables
}

struct IdVariables {
	ids            []string
	project_slug   string @[json: projectSlug]
	first          int
	relation_first int @[json: relationFirst]
}

struct IdPayload {
	query     string
	variables IdVariables
}

struct TeamIdVariables {
	ids            []string
	team_key       string @[json: teamKey]
	first          int
	relation_first int @[json: relationFirst]
}

struct TeamIdPayload {
	query     string
	variables TeamIdVariables
}

struct ProjectScopeVariables {
	project_slug string @[json: projectSlug]
}

struct ProjectScopePayload {
	query     string
	variables ProjectScopeVariables
}

struct TeamScopeVariables {
	team_key string @[json: teamKey]
}

struct TeamScopePayload {
	query     string
	variables TeamScopeVariables
}

pub struct LinearPage {
pub:
	issues        []domain.Issue
	has_next_page bool
	end_cursor    string
}

pub fn build_candidate_payload(project_slug string, states []string, after string) string {
	after_value := if after == '' { json2.Any(json2.null) } else { json2.Any(after) }
	return json2.encode(CandidatePayload{
		query:     candidate_query
		variables: CandidateVariables{
			project_slug:   project_slug
			state_names:    states
			first:          issue_page_size
			relation_first: relation_page_size
			after:          after_value
		}
	})
}

fn build_team_candidate_payload(team_key string, states []string, after string) string {
	after_value := if after == '' { json2.Any(json2.null) } else { json2.Any(after) }
	return json2.encode(TeamCandidatePayload{
		query:     team_candidate_query
		variables: TeamCandidateVariables{
			team_key:       team_key
			state_names:    states
			first:          issue_page_size
			relation_first: relation_page_size
			after:          after_value
		}
	})
}

fn build_ids_payload(project_slug string, ids []string) string {
	return json2.encode(IdPayload{
		query:     issues_by_id_query
		variables: IdVariables{
			ids:            ids
			project_slug:   project_slug
			first:          ids.len
			relation_first: relation_page_size
		}
	})
}

fn build_team_ids_payload(team_key string, ids []string) string {
	return json2.encode(TeamIdPayload{
		query:     team_issues_by_id_query
		variables: TeamIdVariables{
			ids:            ids
			team_key:       team_key
			first:          ids.len
			relation_first: relation_page_size
		}
	})
}

fn default_graphql_transport(endpoint string, api_key string, body string) !TransportResponse {
	mut header := http.new_header(key: .content_type, value: 'application/json')
	header.add_custom('Authorization', api_key)!
	response := http.fetch(
		url:                  endpoint
		method:               .post
		header:               header
		data:                 body
		read_timeout:         i64(30 * time.second)
		write_timeout:        i64(30 * time.second)
		stop_receiving_limit: 8 * 1024 * 1024
	) or { return error('tracker_request: Linear transport failed: ${err.msg()}') }
	return TransportResponse{
		status: response.status_code
		body:   response.body
	}
}

pub fn (client LinearClient) fetch_issues_by_states(states []string) ![]domain.Issue {
	if states.len == 0 {
		return []domain.Issue{}
	}
	client.validate()!
	mut issues := []domain.Issue{}
	mut cursor := ''
	mut seen_cursors := map[string]bool{}
	for {
		body := if client.team_key != '' {
			build_team_candidate_payload(client.team_key, states, cursor)
		} else {
			build_candidate_payload(client.project_slug, states, cursor)
		}
		response := client.post(body)!
		page := decode_page_with_terminal_states(response.body, false, client.assignee,
			client.terminal_states)!
		issues << page.issues
		if !page.has_next_page {
			break
		}
		if page.end_cursor == '' {
			return error('tracker_pagination: Linear paginated response omitted endCursor')
		}
		if seen_cursors[page.end_cursor] {
			return error('tracker_pagination: Linear repeated an endCursor')
		}
		seen_cursors[page.end_cursor] = true
		cursor = page.end_cursor
	}
	return issues
}

pub fn (client LinearClient) fetch_completed_issues(terminal_states []string) ![]domain.Issue {
	return client.fetch_issues_by_states(terminal_states)
}

// completed_issues_preserve_workspaces is false for Linear's read-only history.
pub fn (_ LinearClient) completed_issues_preserve_workspaces() bool {
	return false
}

pub fn (client LinearClient) fetch_issues_by_ids(ids []string) ![]domain.Issue {
	if ids.len == 0 {
		return []domain.Issue{}
	}
	client.validate()!
	mut unique_ids := []string{}
	for id in ids {
		if id !in unique_ids {
			unique_ids << id
		}
	}
	mut by_id := map[string]domain.Issue{}
	for offset := 0; offset < unique_ids.len; offset += issue_page_size {
		end := min_int(offset + issue_page_size, unique_ids.len)
		batch := unique_ids[offset..end].clone()
		body := if client.team_key != '' {
			build_team_ids_payload(client.team_key, batch)
		} else {
			build_ids_payload(client.project_slug, batch)
		}
		response := client.post(body)!
		page := decode_page_with_terminal_states(response.body, true, client.assignee,
			client.terminal_states)!
		for issue in page.issues {
			by_id[issue.id] = issue
		}
	}
	mut ordered := []domain.Issue{}
	for id in unique_ids {
		if issue := by_id[id] {
			ordered << issue
		}
	}
	return ordered
}

pub fn (client LinearClient) secret_environment_names() []string {
	return if client.api_key_env == '' { []string{} } else { [client.api_key_env] }
}

pub fn (client LinearClient) secret_values() []string {
	return if client.api_key == '' { []string{} } else { [client.api_key] }
}

// validate_scope verifies that the exact configured Linear project or team exists.
pub fn (client LinearClient) validate_scope() ! {
	client.validate()!
	body := if client.team_key != '' {
		json2.encode(TeamScopePayload{
			query:     team_scope_query
			variables: TeamScopeVariables{
				team_key: client.team_key
			}
		})
	} else {
		json2.encode(ProjectScopePayload{
			query:     project_scope_query
			variables: ProjectScopeVariables{
				project_slug: client.project_slug
			}
		})
	}
	response := client.post(body)!
	decoded := json2.decode[json2.Any](response.body) or {
		return error('tracker_response: Linear scope response was not valid JSON')
	}
	root := decoded.as_map()
	if errors_value := root['errors'] {
		if errors_value.as_array().len > 0 {
			return error('tracker_response: Linear returned GraphQL errors')
		}
	}
	data := map_value(root, 'data')
	collection_name := if client.team_key != '' { 'teams' } else { 'projects' }
	nodes := array_value(map_value(data, collection_name), 'nodes')
	if nodes.len != 1 || string_value(nodes[0].as_map(), 'id').trim_space() == '' {
		scope_name := if client.team_key != '' { 'team' } else { 'project' }
		return error('tracker_scope: configured Linear ${scope_name} was not found')
	}
}

// record_outcome preserves the Linear adapter's read-only behavior.
pub fn (_ LinearClient) record_outcome(_ domain.Issue, _ domain.AttemptOutcome) !bool {
	return false
}

fn (client LinearClient) validate() ! {
	if client.endpoint.trim_space() == '' {
		return error('invalid_tracker_config: Linear endpoint is required')
	}
	if client.api_key.trim_space() == '' {
		return error('missing_tracker_secret: Linear API key is required')
	}
	project_configured := client.project_slug.trim_space() != ''
	team_configured := client.team_key.trim_space() != ''
	if project_configured == team_configured {
		return error('invalid_tracker_config: Linear requires exactly one of project_slug or team_key')
	}
}

fn (client LinearClient) post(body string) !TransportResponse {
	response := client.transport(client.endpoint, client.api_key, body)!
	match response.status {
		200 {}
		401, 403 { return error('tracker_status: Linear rejected the configured credential') }
		429 { return error('tracker_rate_limited: Linear rate limit was reached') }
		else { return error('tracker_status: Linear returned HTTP ${response.status}') }
	}
	return response
}

pub fn decode_page(body string, strict bool, assignee string) !LinearPage {
	return decode_page_with_terminal_states(body, strict, assignee, ['Closed', 'Cancelled',
		'Canceled', 'Duplicate', 'Done'])
}

fn decode_page_with_terminal_states(body string, strict bool, assignee string, terminal_states []string) !LinearPage {
	decoded := json2.decode[json2.Any](body) or {
		return error('tracker_response: Linear response was not valid JSON')
	}
	root := decoded.as_map()
	if errors_value := root['errors'] {
		if errors_value.as_array().len > 0 {
			return error('tracker_response: Linear returned GraphQL errors')
		}
	}
	data := map_value(root, 'data')
	issues_data := map_value(data, 'issues')
	nodes_value := issues_data['nodes'] or {
		return error('tracker_response: Linear response omitted data.issues.nodes')
	}
	if nodes_value !is []json2.Any {
		return error('tracker_response: Linear data.issues.nodes must be an array')
	}
	mut issues := []domain.Issue{}
	mut malformed := 0
	for node_value in nodes_value.as_array() {
		node := node_value.as_map()
		issue := normalize_issue(node, assignee, terminal_states) or {
			malformed++
			if !strict {
				observability.emit(observability.Record{
					level:            'warn'
					event:            'tracker_record_omitted'
					issue_id:         string_value(node, 'id')
					issue_identifier: string_value(node, 'identifier')
					message:          'Linear candidate omitted because a required field was malformed'
				}, []string{})
			}
			continue
		}
		issues << issue
	}
	if strict && malformed > 0 {
		return error('tracker_response: Linear returned a malformed requested issue record')
	}
	page_info := map_value(issues_data, 'pageInfo')
	return LinearPage{
		issues:        issues
		has_next_page: bool_value(page_info, 'hasNextPage')
		end_cursor:    string_value(page_info, 'endCursor')
	}
}

fn normalize_issue(node map[string]json2.Any, configured_assignee string, terminal_states []string) !domain.Issue {
	id := string_value(node, 'id').trim_space()
	identifier := string_value(node, 'identifier').trim_space()
	title := string_value(node, 'title').trim_space()
	state := string_value(map_value(node, 'state'), 'name').trim_space()
	if id == '' || identifier == '' || title == '' || state == '' {
		return error('malformed issue')
	}
	assignee_id := string_value(map_value(node, 'assignee'), 'id').trim_space()
	assigned := configured_assignee.trim_space() == ''
		|| assignee_id == configured_assignee.trim_space()
	mut issue := domain.Issue{
		id:          id
		identifier:  identifier
		title:       title
		description: string_value(node, 'description')
		priority:    priority_value(node, 'priority')
		state:       state
		branch_name: string_value(node, 'branchName')
		url:         string_value(node, 'url')
		labels:      extract_labels(node)
		blocked_by:  extract_blockers(node)
		created_at:  valid_timestamp(string_value(node, 'createdAt'))
		updated_at:  valid_timestamp(string_value(node, 'updatedAt'))
		assignee_id: assignee_id
		native_ref:  {
			'linear_issue_id': json2.Any(id)
		}
	}
	issue = domain.Issue{
		...issue
		dispatchable: assigned
			&& (issue.normalized_state() != 'todo' || !issue.has_open_blockers(terminal_states))
	}
	return issue
}

fn extract_labels(node map[string]json2.Any) []string {
	labels_data := map_value(node, 'labels')
	mut labels := []string{}
	for label_value in array_value(labels_data, 'nodes') {
		name := string_value(label_value.as_map(), 'name')
		labels << name
	}
	return domain.normalize_labels(labels)
}

fn extract_blockers(node map[string]json2.Any) []domain.BlockerRef {
	relations := map_value(node, 'inverseRelations')
	mut blockers := []domain.BlockerRef{}
	for relation_value in array_value(relations, 'nodes') {
		relation := relation_value.as_map()
		if string_value(relation, 'type').trim_space().to_lower() != 'blocks' {
			continue
		}
		blocker := map_value(relation, 'issue')
		blockers << domain.BlockerRef{
			id:         string_value(blocker, 'id')
			identifier: string_value(blocker, 'identifier')
			state:      string_value(map_value(blocker, 'state'), 'name')
		}
	}
	return blockers
}

fn priority_value(values map[string]json2.Any, key string) int {
	value := values[key] or { return -1 }
	return match value {
		int { value }
		i64 { int(value) }
		i32 { int(value) }
		u64 { int(value) }
		u32 { int(value) }
		else { -1 }
	}
}

fn min_int(left int, right int) int {
	return if left < right { left } else { right }
}
