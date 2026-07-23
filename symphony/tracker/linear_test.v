module tracker

import json2
import os
import yaml
import symphony.domain
import symphony.workflow

const first_page = '{"data":{"issues":{"nodes":[{"id":"1","identifier":"OPS-1","title":"First","description":null,"priority":1,"state":{"name":"Todo"},"branchName":"ops-1","url":"https://linear.test/OPS-1","assignee":{"id":"user-1"},"labels":{"nodes":[{"name":" Backend "},{"name":"URGENT"}]},"inverseRelations":{"nodes":[{"type":"blocks","issue":{"id":"9","identifier":"OPS-9","state":{"name":"Done"}}}]},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z"},{"id":"bad","title":"Missing identifier","state":{"name":"Todo"}}],"pageInfo":{"hasNextPage":true,"endCursor":"cursor-1"}}}}'

const second_page = '{"data":{"issues":{"nodes":[{"id":"2","identifier":"OPS-2","title":"Second","priority":2,"state":{"name":"In Progress"},"assignee":{"id":"user-1"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]},"createdAt":"2026-01-03T00:00:00Z","updatedAt":"2026-01-04T00:00:00Z"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'

fn paged_transport(_ string, token string, body string) !TransportResponse {
	assert token == 'secret'
	payload := json2.decode[json2.Any](body) or { panic(err) }.as_map()
	variables := (payload['variables'] or { panic('variables') }).as_map()
	after := (variables['after'] or { json2.Any(json2.null) })
	if after is string && after == 'cursor-1' {
		return TransportResponse{
			status: 200
			body:   second_page
		}
	}
	return TransportResponse{
		status: 200
		body:   first_page
	}
}

fn completed_transport(_ string, token string, body string) !TransportResponse {
	assert token == 'secret'
	payload := json2.decode[json2.Any](body) or { panic(err) }.as_map()
	variables := (payload['variables'] or { panic('variables') }).as_map()
	states := (variables['stateNames'] or { panic('stateNames') }).as_array().map(it.str())
	assert states == ['Done']
	return TransportResponse{
		status: 200
		body:   '{"data":{"issues":{"nodes":[{"id":"3","identifier":"OPS-3","title":"Done issue","state":{"name":"Done"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]},"createdAt":"2026-07-20T00:00:00Z","updatedAt":"2026-07-23T01:00:00Z"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
	}
}

fn unauthorized_transport(_ string, _ string, _ string) !TransportResponse {
	return TransportResponse{
		status: 401
		body:   '{"error":"nope"}'
	}
}

fn team_candidate_transport(_ string, _ string, body string) !TransportResponse {
	payload := json2.decode[json2.Any](body) or { panic(err) }.as_map()
	query := (payload['query'] or { panic('query') }).str()
	variables := (payload['variables'] or { panic('variables') }).as_map()
	assert query.contains('team: {key: {eq: $teamKey}}')
	assert !query.contains('project: {slugId:')
	assert (variables['teamKey'] or { panic('teamKey') }).str() == 'ENG'
	return TransportResponse{
		status: 200
		body:   '{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
	}
}

fn team_id_transport(_ string, _ string, body string) !TransportResponse {
	payload := json2.decode[json2.Any](body) or { panic(err) }.as_map()
	query := (payload['query'] or { panic('query') }).str()
	variables := (payload['variables'] or { panic('variables') }).as_map()
	assert query.contains('team: {key: {eq: $teamKey}}')
	assert !query.contains('project: {slugId:')
	assert (variables['teamKey'] or { panic('teamKey') }).str() == 'ENG'
	return TransportResponse{
		status: 200
		body:   '{"data":{"issues":{"nodes":[]}}}'
	}
}

fn linear_scope_transport(_ string, _ string, body string) !TransportResponse {
	payload := json2.decode[json2.Any](body) or { panic(err) }.as_map()
	query := string_value(payload, 'query')
	assert query.contains('projects(filter: {slugId: {eq: $projectSlug}}')
	return TransportResponse{
		status: 200
		body:   '{"data":{"projects":{"nodes":[{"id":"project-1"}]}}}'
	}
}

fn linear_missing_scope_transport(_ string, _ string, _ string) !TransportResponse {
	return TransportResponse{
		status: 200
		body:   '{"data":{"projects":{"nodes":[]}}}'
	}
}

fn test_candidate_payload_uses_specified_linear_filter_and_variables() {
	body := build_candidate_payload('demo-project', ['Todo', 'In Progress'], '')
	payload := json2.decode[json2.Any](body) or { panic(err) }.as_map()
	query := (payload['query'] or { panic('query') }).str()
	assert query.contains('project: {slugId: {eq: $projectSlug}}')
	assert query.contains('inverseRelations')
	variables := (payload['variables'] or { panic('variables') }).as_map()
	assert (variables['projectSlug'] or { panic('slug') }).str() == 'demo-project'
	assert (variables['stateNames'] or { panic('states') }).as_array().len == 2
}

fn test_team_scope_filters_candidate_reads_by_exact_team_key() {
	client := LinearClient{
		endpoint:  'https://linear.test/graphql'
		api_key:   'secret'
		team_key:  'ENG'
		transport: team_candidate_transport
	}

	issues := client.fetch_issues_by_states(['Todo']) or { panic(err) }

	assert issues == []domain.Issue{}
}

fn test_team_scope_filters_id_refreshes_by_exact_team_key() {
	client := LinearClient{
		endpoint:  'https://linear.test/graphql'
		api_key:   'secret'
		team_key:  'ENG'
		transport: team_id_transport
	}

	issues := client.fetch_issues_by_ids(['opaque-1']) or { panic(err) }

	assert issues == []domain.Issue{}
}

fn test_linear_scope_validation_rejects_unknown_project() {
	valid := LinearClient{
		endpoint:     'https://linear.test/graphql'
		api_key:      'secret'
		project_slug: 'demo-project'
		transport:    linear_scope_transport
	}
	valid.validate_scope() or { panic(err) }

	missing := LinearClient{
		...valid
		transport: linear_missing_scope_transport
	}
	missing.validate_scope() or {
		assert err.msg().contains('tracker_scope')
		assert err.msg().contains('project')
		return
	}
	assert false, 'unknown Linear project scopes must be rejected before activation'
}

fn test_pagination_preserves_order_and_drops_malformed_candidates() {
	client := LinearClient{
		endpoint:      'https://linear.test/graphql'
		api_key:       'secret'
		project_slug:  'demo-project'
		active_states: ['Todo', 'In Progress']
		transport:     paged_transport
	}
	issues := client.fetch_issues_by_states(['Todo', 'In Progress']) or { panic(err) }
	assert issues.map(it.id) == ['1', '2']
	assert issues[0].labels == ['backend', 'urgent']
	assert issues[0].blocked_by.len == 1
	assert issues[0].blocked_by[0].identifier == 'OPS-9'
	assert (issues[0].native_ref['linear_issue_id'] or { panic('linear_issue_id') }).str() == '1'
	assert issues[0].dispatchable
}

fn test_linear_completed_query_uses_terminal_states() {
	client := LinearClient{
		endpoint:        'https://linear.test/graphql'
		api_key:         'secret'
		project_slug:    'demo-project'
		terminal_states: ['Done']
		transport:       completed_transport
	}

	completed := client.fetch_completed_issues(['Done'])!

	assert completed.map(it.identifier) == ['OPS-3']
	assert completed[0].state == 'Done'
}

fn test_configured_assignee_controls_dispatchable_normalization() {
	page := decode_page(first_page, false, 'other-user') or { panic(err) }
	assert page.issues.len == 1
	assert !page.issues[0].dispatchable
}

fn test_strict_refresh_rejects_any_malformed_requested_record() {
	decode_page(first_page, true, '') or {
		assert err.msg().contains('tracker_response')
		return
	}
	assert false, 'strict refresh must reject malformed records'
}

fn test_http_statuses_have_distinct_safe_categories() {
	client := LinearClient{
		endpoint:      'https://linear.test/graphql'
		api_key:       'secret'
		project_slug:  'demo-project'
		active_states: ['Todo']
		transport:     unauthorized_transport
	}
	client.fetch_issues_by_states(['Todo']) or {
		assert err.msg().contains('tracker_status')
		assert !err.msg().contains('secret')
		return
	}
	assert false, 'authentication failure should be classified'
}

fn test_empty_queries_do_not_validate_or_contact_the_provider() {
	client := LinearClient{}
	assert client.fetch_issues_by_states([]) or { panic(err) } == []
	assert client.fetch_issues_by_ids([]) or { panic(err) } == []
}

fn test_id_refresh_treats_duplicate_input_as_a_set() {
	client := LinearClient{
		endpoint:     'https://linear.test/graphql'
		api_key:      'secret'
		project_slug: 'demo-project'
		transport:    fn (_ string, _ string, _ string) !TransportResponse {
			return TransportResponse{
				status: 200
				body:   '{"data":{"issues":{"nodes":[{"id":"1","identifier":"OPS-1","title":"First","state":{"name":"Todo"},"labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}]}}}'
			}
		}
	}
	issues := client.fetch_issues_by_ids(['1', '1']) or { panic(err) }
	assert issues.map(it.id) == ['1']
}

fn test_adapter_factory_resolves_provider_secret_and_rejects_unknown_kind() {
	defer {
		os.unsetenv('SYMPHONY_TRACKER_TEST_KEY')
	}
	provider := {
		'api_key':      yaml.Any('$SYMPHONY_TRACKER_TEST_KEY')
		'project_slug': yaml.Any('demo-project')
	}
	os.setenv('SYMPHONY_TRACKER_TEST_KEY', 'factory-secret', true)
	adapter := new_adapter(workflow.TrackerConfig{
		kind:     'linear'
		provider: provider
	}) or { panic(err) }
	assert adapter.secret_environment_names() == ['SYMPHONY_TRACKER_TEST_KEY']
	assert adapter.secret_values() == ['factory-secret']
	assert adapter.fetch_issues_by_states([]) or { panic(err) } == []domain.Issue{}

	new_adapter(workflow.TrackerConfig{ kind: 'unknown' }) or {
		assert err.msg().contains('unsupported_tracker_kind')
		return
	}
	assert false, 'unknown tracker kinds must fail at adapter selection'
}

fn test_adapter_factory_rejects_non_string_provider_values() {
	new_adapter(workflow.TrackerConfig{
		kind:     'linear'
		provider: {
			'api_key':      yaml.Any('secret')
			'project_slug': yaml.Any(42)
		}
	}) or {
		assert err.msg().contains('invalid_tracker_config')
		assert err.msg().contains('project_slug')
		return
	}
	assert false, 'provider keys with the wrong type must fail adapter validation'
}

fn test_linear_adapter_accepts_team_scope() {
	adapter := new_adapter(workflow.TrackerConfig{
		kind:     'linear'
		provider: {
			'api_key':  yaml.Any('secret')
			'team_key': yaml.Any('ENG')
		}
	}) or { panic(err) }

	assert adapter.fetch_issues_by_states([]) or { panic(err) } == []domain.Issue{}
}

fn test_linear_adapter_rejects_project_and_team_scope_together() {
	new_adapter(workflow.TrackerConfig{
		kind:     'linear'
		provider: {
			'api_key':      yaml.Any('secret')
			'project_slug': yaml.Any('demo-project')
			'team_key':     yaml.Any('ENG')
		}
	}) or {
		assert err.msg().contains('invalid_tracker_config')
		assert err.msg().contains('exactly one')
		return
	}
	assert false, 'Linear project and team scope must be mutually exclusive'
}
