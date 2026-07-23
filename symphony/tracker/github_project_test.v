module tracker

import json2
import os
import yaml
import symphony.domain
import symphony.workflow

const github_project_page_one = '{"data":{"organization":{"projectV2":{"id":"PVT_project","number":7,"field":{"id":"PVTF_status","name":"Status","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_progress","name":"In Progress"},{"id":"opt_review","name":"In Review"},{"id":"opt_done","name":"Done"},{"id":"opt_blocked","name":"Blocked"}]},"items":{"nodes":[{"id":"PVTI_3","type":"ISSUE","fieldValueByName":{"name":"Todo","optionId":"opt_todo"},"content":{"id":"I_node_3","number":3,"title":"Third issue","body":"Third body","state":"OPEN","url":"https://github.test/octo/example/issues/3","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","repository":{"nameWithOwner":"octo/example"},"assignees":{"nodes":[{"login":"octocat"}]},"labels":{"nodes":[{"name":" Bug "},{"name":"RSVP"}],"pageInfo":{"hasNextPage":false}}}},{"id":"PVTI_pr","type":"PULL_REQUEST","fieldValueByName":{"name":"In Review","optionId":"opt_review"},"content":{"id":"PR_node"}},{"id":"PVTI_draft","type":"DRAFT_ISSUE","fieldValueByName":{"name":"Todo","optionId":"opt_todo"},"content":{"id":"DI_node"}},{"id":"PVTI_unmapped","type":"ISSUE","fieldValueByName":null,"content":{"id":"I_node_11","number":11,"title":"Unmapped","body":"","state":"OPEN","url":"https://github.test/octo/example/issues/11","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-02T00:00:00Z","repository":{"nameWithOwner":"octo/example"},"assignees":{"nodes":[]},"labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}],"pageInfo":{"hasNextPage":true,"endCursor":"CURSOR_1"}}}}}}'

const github_project_page_two = '{"data":{"organization":{"projectV2":{"id":"PVT_project","number":7,"field":{"id":"PVTF_status","name":"Status","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_progress","name":"In Progress"},{"id":"opt_review","name":"In Review"},{"id":"opt_done","name":"Done"},{"id":"opt_blocked","name":"Blocked"}]},"items":{"nodes":[{"id":"PVTI_2","type":"ISSUE","fieldValueByName":{"name":"In Progress","optionId":"opt_progress"},"content":{"id":"I_node_2","number":2,"title":"Second issue","body":null,"state":"OPEN","url":"https://github.test/octo/other/issues/2","createdAt":"2026-07-03T00:00:00Z","updatedAt":"2026-07-04T00:00:00Z","repository":{"nameWithOwner":"octo/other"},"assignees":{"nodes":[]},"labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}}},{"id":"PVTI_13","type":"ISSUE","fieldValueByName":null,"content":{"id":"I_node_13","number":13,"title":"Closed issue","body":"","state":"CLOSED","url":"https://github.test/octo/example/issues/13","createdAt":"2026-07-01T00:00:00Z","updatedAt":"2026-07-05T00:00:00Z","repository":{"nameWithOwner":"octo/example"},"assignees":{"nodes":[]},"labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'

const github_project_mutation_response = '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_3"}}}}'

fn github_project_transport(request GitHubRequest) !GitHubResponse {
	assert request.method == 'POST'
	assert request.url == 'https://api.github.test/graphql'
	assert request.token == 'secret'
	payload := json2.decode[json2.Any](request.body) or { panic(err) }.as_map()
	query := string_value(payload, 'query')
	variables := map_value(payload, 'variables')
	if query.contains('mutation SymphonyGitHubProjectOutcome') {
		assert string_value(variables, 'projectId') == 'PVT_project'
		assert string_value(variables, 'itemId') == 'PVTI_3'
		assert string_value(variables, 'fieldId') == 'PVTF_status'
		assert string_value(variables, 'optionId') == 'opt_done'
		return GitHubResponse{
			status: 200
			body:   github_project_mutation_response
		}
	}
	assert query.contains('organization(login: $owner)')
	assert string_value(variables, 'owner') == 'octo'
	assert github_int_value(variables, 'number') == 7
	assert string_value(variables, 'statusField') == 'Status'
	if request.body.contains('"after":"CURSOR_1"') {
		return GitHubResponse{
			status: 200
			body:   github_project_page_two
		}
	}
	assert request.body.contains('"after":null')
	return GitHubResponse{
		status: 200
		body:   github_project_page_one
	}
}

fn github_project_test_client(transport GitHubTransport) GitHubProjectClient {
	return GitHubProjectClient{
		endpoint:        'https://api.github.test/graphql'
		token:           'secret'
		owner_type:      'organization'
		owner:           'octo'
		project_number:  7
		status_field:    'Status'
		state_options:   {
			'Todo':        'Todo'
			'In Progress': 'In Progress'
			'In Review':   'In Review'
			'Done':        'Done'
			'Blocked':     'Blocked'
		}
		closed_state:    'Closed'
		active_states:   ['Todo', 'In Progress', 'In Review']
		terminal_states: ['Done', 'Blocked', 'Closed']
		transport:       transport
	}
}

fn contract_linear_transport(endpoint string, token string, body string) !TransportResponse {
	assert endpoint == 'https://linear.test/graphql'
	assert token == 'secret'
	payload := json2.decode[json2.Any](body) or { panic(err) }.as_map()
	query := string_value(payload, 'query')
	variables := map_value(payload, 'variables')
	assert query.contains('project: {slugId: {eq: $projectSlug}}')
	assert string_value(variables, 'projectSlug') == 'demo-project'
	if query.contains('SymphonyLinearIssuesById') {
		return TransportResponse{
			status: 200
			body:   '{"data":{"issues":{"nodes":[{"id":"linear-1","identifier":"OPS-1","title":"Linear first","state":{"name":"Todo"},"url":"https://linear.test/OPS-1","labels":{"nodes":[{"name":"Backend"}]},"inverseRelations":{"nodes":[]}},{"id":"linear-2","identifier":"OPS-2","title":"Linear second","state":{"name":"In Progress"},"url":"https://linear.test/OPS-2","labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}]}}}'
		}
	}
	assert query.contains('SymphonyLinearPoll')
	if body.contains('"after":"LINEAR_CURSOR"') {
		return TransportResponse{
			status: 200
			body:   '{"data":{"issues":{"nodes":[{"id":"linear-2","identifier":"OPS-2","title":"Linear second","state":{"name":"In Progress"},"url":"https://linear.test/OPS-2","labels":{"nodes":[]},"inverseRelations":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}'
		}
	}
	return TransportResponse{
		status: 200
		body:   '{"data":{"issues":{"nodes":[{"id":"linear-1","identifier":"OPS-1","title":"Linear first","state":{"name":"Todo"},"url":"https://linear.test/OPS-1","labels":{"nodes":[{"name":"Backend"}]},"inverseRelations":{"nodes":[]}}],"pageInfo":{"hasNextPage":true,"endCursor":"LINEAR_CURSOR"}}}}'
	}
}

fn contract_github_transport(_ GitHubRequest) !GitHubResponse {
	return error('contract transport must not be contacted')
}

fn github_project_graphql_rate_limit_transport(_ GitHubRequest) !GitHubResponse {
	return GitHubResponse{
		status: 200
		body:   '{"errors":[{"type":"RATE_LIMITED","message":"sensitive provider detail"}]}'
	}
}

fn github_project_blocked_transport(request GitHubRequest) !GitHubResponse {
	if request.body.contains('mutation SymphonyGitHubProjectOutcome') {
		variables := map_value(json2.decode[json2.Any](request.body)!.as_map(), 'variables')
		assert string_value(variables, 'optionId') == 'opt_blocked'
		return GitHubResponse{
			status: 200
			body:   github_project_mutation_response
		}
	}
	return github_project_transport(request)
}

fn github_project_completion_history_transport(request GitHubRequest) !GitHubResponse {
	response := github_project_transport(request)!
	body := if request.body.contains('"after":"CURSOR_1"') {
		response.body.replace('"fieldValueByName":{"name":"In Progress","optionId":"opt_progress"},"content":{"id":"I_node_2"',
			'"fieldValueByName":{"name":"Done","optionId":"opt_done"},"content":{"id":"I_node_2"')
	} else {
		response.body.replace('"fieldValueByName":{"name":"Todo","optionId":"opt_todo"},"content":{"id":"I_node_3"',
			'"fieldValueByName":{"name":"Blocked","optionId":"opt_blocked"},"content":{"id":"I_node_3"')
	}
	return GitHubResponse{
		...response
		body: body
	}
}

fn github_project_mutation_failure_transport(request GitHubRequest) !GitHubResponse {
	if request.body.contains('mutation SymphonyGitHubProjectOutcome') {
		return GitHubResponse{
			status: 500
			body:   '{"message":"failed"}'
		}
	}
	return github_project_transport(request)
}

fn github_project_wrong_mutation_item_transport(request GitHubRequest) !GitHubResponse {
	if request.body.contains('mutation SymphonyGitHubProjectOutcome') {
		return GitHubResponse{
			status: 200
			body:   '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"PVTI_other"}}}}'
		}
	}
	return github_project_transport(request)
}

fn github_project_malformed_connection_transport(_ GitHubRequest) !GitHubResponse {
	return GitHubResponse{
		status: 200
		body:   '{"data":{"organization":{"projectV2":{"id":"PVT_project","number":7,"field":{"id":"PVTF_status","name":"Status","options":[{"id":"opt_todo","name":"Todo"},{"id":"opt_progress","name":"In Progress"},{"id":"opt_review","name":"In Review"},{"id":"opt_done","name":"Done"},{"id":"opt_blocked","name":"Blocked"}]},"items":{"nodes":[]}}}}}'
	}
}

fn github_project_overflow_labels_transport(request GitHubRequest) !GitHubResponse {
	if request.body.contains('"after":"CURSOR_1"') {
		return github_project_transport(request)
	}
	return GitHubResponse{
		status: 200
		body:   github_project_page_one.replace('"labels":{"nodes":[{"name":" Bug "},{"name":"RSVP"}],"pageInfo":{"hasNextPage":false}}',
			'"labels":{"nodes":[{"name":" Bug "},{"name":"RSVP"}],"pageInfo":{"hasNextPage":true}}')
	}
}

fn github_project_bad_timestamp_transport(request GitHubRequest) !GitHubResponse {
	if request.body.contains('"after":"CURSOR_1"') {
		return github_project_transport(request)
	}
	return GitHubResponse{
		status: 200
		body:   github_project_page_one.replace('"createdAt":"2026-07-01T00:00:00Z"',
			'"createdAt":"not-a-timestamp"')
	}
}

fn github_project_missing_scope_transport(_ GitHubRequest) !GitHubResponse {
	return GitHubResponse{
		status: 200
		body:   '{"data":{"organization":{"projectV2":null}}}'
	}
}

fn github_user_project_transport(request GitHubRequest) !GitHubResponse {
	assert request.body.contains('user(login: $owner)')
	page := if request.body.contains('"after":"CURSOR_1"') {
		github_project_page_two
	} else {
		github_project_page_one
	}
	return GitHubResponse{
		status: 200
		body:   page.replace('"organization"', '"user"')
	}
}

fn test_github_project_factory_selects_project_items_scope() {
	defer {
		os.unsetenv('SYMPHONY_GITHUB_PROJECT_TEST_TOKEN')
	}
	os.setenv('SYMPHONY_GITHUB_PROJECT_TEST_TOKEN', 'project-secret', true)
	adapter := new_adapter(workflow.TrackerConfig{
		kind:            'github'
		provider:        {
			'owner_type':     yaml.Any('organization')
			'owner':          yaml.Any('octo')
			'project_number': yaml.Any(7)
			'token':          yaml.Any('$SYMPHONY_GITHUB_PROJECT_TEST_TOKEN')
			'status_field':   yaml.Any('Status')
			'state_options':  yaml.Any({
				'Todo':        yaml.Any('Todo')
				'In Progress': yaml.Any('In Progress')
				'Done':        yaml.Any('Done')
			})
		}
		active_states:   ['Todo', 'In Progress']
		terminal_states: ['Done', 'Closed']
	}) or { panic(err) }

	assert adapter is GitHubProjectClient
	assert adapter.secret_environment_names() == [
		'SYMPHONY_GITHUB_PROJECT_TEST_TOKEN',
	]
	assert adapter.secret_values() == ['project-secret']
}

fn test_github_project_poll_reads_only_issue_items_and_uses_project_status() {
	client := github_project_test_client(github_project_transport)

	issues := client.fetch_issues_by_states(['Todo', 'In Progress']) or { panic(err) }

	assert issues.map(it.id) == ['github:octo/example#3', 'github:octo/other#2']
	assert issues.map(it.state) == ['Todo', 'In Progress']
	assert issues[0].identifier == 'octo/example#3'
	assert issues[0].description == 'Third body'
	assert issues[0].url == 'https://github.test/octo/example/issues/3'
	assert issues[0].labels == ['bug', 'rsvp']
	assert issues[0].assignee_id == 'octocat'
	assert issues[0].dispatchable
	assert issues.map(it.queue_rank) == [0, 1]
	assert string_value(issues[0].native_ref, 'project_item_id') == 'PVTI_3'
	assert string_value(issues[0].native_ref, 'project_id') == 'PVT_project'
}

fn test_github_project_completed_query_uses_terminal_states() {
	client := github_project_test_client(github_project_transport)

	completed := client.fetch_completed_issues(['Closed'])!

	assert completed.map(it.identifier) == ['octo/example#13']
	assert completed[0].state == 'Closed'
}

fn test_github_project_completed_query_uses_success_state_when_writing_outcomes() {
	client := GitHubProjectClient{
		...github_project_test_client(github_project_completion_history_transport)
		write_outcomes: true
		success_state:  'Done'
		blocked_state:  'Blocked'
	}

	completed := client.fetch_completed_issues(['Done', 'Blocked', 'Closed'])!

	assert completed.map(it.identifier) == ['octo/other#2']
	assert completed.map(it.state) == ['Done']
}

fn test_github_project_closed_issue_normalizes_to_closed_terminal_state() {
	client := github_project_test_client(github_project_transport)

	issues := client.fetch_issues_by_states(['Closed']) or { panic(err) }

	assert issues.map(it.id) == ['github:octo/example#13']
	assert !issues[0].dispatchable
}

fn test_github_project_refresh_is_project_scoped_ordered_and_deduplicated() {
	client := github_project_test_client(github_project_transport)

	issues := client.fetch_issues_by_ids([
		'github:octo/other#2',
		'github:octo/example#3',
		'github:octo/other#2',
		'github:octo/example#99',
	]) or { panic(err) }

	assert issues.map(it.id) == ['github:octo/other#2', 'github:octo/example#3']
}

fn test_github_project_success_updates_status_field_without_closing_issue() {
	client := GitHubProjectClient{
		...github_project_test_client(github_project_transport)
		write_outcomes: true
		success_state:  'Done'
		blocked_state:  'Blocked'
	}
	issue := client.fetch_issues_by_ids(['github:octo/example#3'])![0]

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	}) or { panic(err) }

	assert completed
}

fn test_github_project_blocked_outcome_updates_distinct_status_without_completion() {
	client := GitHubProjectClient{
		...github_project_test_client(github_project_blocked_transport)
		write_outcomes: true
		success_state:  'Done'
		blocked_state:  'Blocked'
	}
	issue := client.fetch_issues_by_ids(['github:octo/example#3'])![0]

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .blocked
		issue_id: issue.id
	}) or { panic(err) }

	assert !completed
}

fn test_github_project_abnormal_outcomes_do_not_contact_provider() {
	client := GitHubProjectClient{
		...github_project_test_client(contract_github_transport)
		write_outcomes: true
		success_state:  'Done'
		blocked_state:  'Blocked'
	}
	issue := domain.Issue{
		id: 'github:octo/example#3'
	}

	assert !client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .failed
		issue_id: issue.id
	}) or { panic(err) }
}

fn test_github_project_failed_mutation_is_not_persisted_completion() {
	client := GitHubProjectClient{
		...github_project_test_client(github_project_mutation_failure_transport)
		write_outcomes: true
		success_state:  'Done'
		blocked_state:  'Blocked'
	}
	issue := client.fetch_issues_by_ids(['github:octo/example#3'])![0]

	client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	}) or {
		assert err.msg().contains('tracker_status')
		return
	}
	assert false, 'failed Project mutations must not count as persisted completion'
}

fn test_github_project_mutation_acknowledges_the_expected_item() {
	client := GitHubProjectClient{
		...github_project_test_client(github_project_wrong_mutation_item_transport)
		write_outcomes: true
		success_state:  'Done'
		blocked_state:  'Blocked'
	}
	issue := client.fetch_issues_by_ids(['github:octo/example#3'])![0]

	client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	}) or {
		assert err.msg().contains('wrong item')
		return
	}
	assert false, 'a mutation response for another Project item must not count as persisted'
}

fn test_github_project_rejects_malformed_item_connection() {
	client := github_project_test_client(github_project_malformed_connection_transport)

	client.fetch_issues_by_states(['Todo']) or {
		assert err.msg().contains('tracker_response')
		assert err.msg().contains('pageInfo')
		return
	}
	assert false, 'a truncated Project connection must not become an empty queue'
}

fn test_github_project_omits_items_when_label_routing_would_be_truncated() {
	client := github_project_test_client(github_project_overflow_labels_transport)

	issues := client.fetch_issues_by_states(['Todo', 'In Progress']) or { panic(err) }
	assert issues.map(it.id) == ['github:octo/other#2']
}

fn test_github_project_strict_refresh_rejects_invalid_timestamps() {
	client := github_project_test_client(github_project_bad_timestamp_transport)

	client.fetch_issues_by_ids(['github:octo/example#3']) or {
		assert err.msg().contains('malformed requested')
		return
	}
	assert false, 'invalid Project Issue timestamps must fail strict refresh'
}

fn test_github_project_strict_refresh_rejects_requested_unmapped_item() {
	client := github_project_test_client(github_project_transport)

	client.fetch_issues_by_ids(['github:octo/example#11']) or {
		assert err.msg().contains('malformed requested')
		return
	}
	assert false, 'strict Project refresh must reject a malformed requested item'
}

fn test_github_project_live_scope_validation_rejects_missing_project() {
	client := github_project_test_client(github_project_missing_scope_transport)

	client.validate_scope() or {
		assert err.msg().contains('tracker_scope')
		assert err.msg().contains('not found')
		return
	}
	assert false, 'missing Projects must fail live scope validation'
}

fn test_github_project_user_owner_builds_user_scoped_query() {
	client := GitHubProjectClient{
		...github_project_test_client(github_user_project_transport)
		owner_type: 'user'
	}

	issues := client.fetch_issues_by_states(['Todo', 'In Progress']) or { panic(err) }
	assert issues.map(it.id) == ['github:octo/example#3', 'github:octo/other#2']
}

fn test_github_project_write_states_must_be_distinct() {
	client := GitHubProjectClient{
		...github_project_test_client(github_project_transport)
		write_outcomes: true
		success_state:  'Done'
		blocked_state:  'Done'
	}

	client.validate() or {
		assert err.msg().contains('must differ')
		return
	}
	assert false, 'success and blocked project states must be distinct'
}

fn test_github_project_graphql_rate_limit_has_safe_error_category() {
	client := github_project_test_client(github_project_graphql_rate_limit_transport)

	client.fetch_issues_by_states(['Todo']) or {
		assert err.msg().contains('tracker_rate_limited')
		assert !err.msg().contains('sensitive provider detail')
		return
	}
	assert false, 'GraphQL rate limits must be classified safely'
}

fn test_github_http_secondary_rate_limits_are_detected_safely() {
	assert github_is_rate_limited(403, '4999', '60', '')
	assert github_is_rate_limited(403, '0', '', '')
	assert github_is_rate_limited(403, '4999', '',
		'{"message":"You have exceeded a secondary rate limit","documentation_url":"https://docs.github.com/rest/using-the-rest-api/rate-limits-for-the-rest-api"}')
	assert !github_is_rate_limited(403, '4999', '', '{"message":"Resource not accessible"}')
	assert !github_is_rate_limited(401, '0', '60', '')
}

struct ReadOnlyTrackerContract {
	states             []string
	candidate_ids      []string
	refresh_ids        []string
	refreshed_ids      []string
	first_label        string
	secret_environment string
}

fn assert_read_only_tracker_contract(client Tracker, expected ReadOnlyTrackerContract) {
	candidates := client.fetch_issues_by_states(expected.states) or { panic(err) }
	assert candidates.map(it.id) == expected.candidate_ids
	assert candidates[0].title != ''
	assert candidates[0].state != ''
	assert candidates[0].url != ''
	assert expected.first_label in candidates[0].labels
	refreshed := client.fetch_issues_by_ids(expected.refresh_ids) or { panic(err) }
	assert refreshed.map(it.id) == expected.refreshed_ids
	assert !client.record_outcome(candidates[0], domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: candidates[0].id
	}) or { panic(err) }
	assert client.secret_environment_names() == [expected.secret_environment]
	assert client.secret_values() == ['secret']
	assert client.fetch_issues_by_states([]) or { panic(err) } == []domain.Issue{}
	assert client.fetch_issues_by_ids([]) or { panic(err) } == []domain.Issue{}
}

fn test_linear_and_github_project_share_full_read_only_tracker_contract() {
	linear := Tracker(LinearClient{
		endpoint:     'https://linear.test/graphql'
		api_key:      'secret'
		api_key_env:  'CONTRACT_LINEAR_TOKEN'
		project_slug: 'demo-project'
		transport:    contract_linear_transport
	})
	github := Tracker(GitHubProjectClient{
		...github_project_test_client(github_project_transport)
		token_env: 'CONTRACT_GITHUB_TOKEN'
	})

	assert_read_only_tracker_contract(linear, ReadOnlyTrackerContract{
		states:             ['Todo', 'In Progress']
		candidate_ids:      ['linear-1', 'linear-2']
		refresh_ids:        ['linear-2', 'linear-1', 'linear-2', 'linear-missing']
		refreshed_ids:      ['linear-2', 'linear-1']
		first_label:        'backend'
		secret_environment: 'CONTRACT_LINEAR_TOKEN'
	})
	assert_read_only_tracker_contract(github, ReadOnlyTrackerContract{
		states:             ['Todo', 'In Progress']
		candidate_ids:      ['github:octo/example#3', 'github:octo/other#2']
		refresh_ids:        ['github:octo/other#2', 'github:octo/example#3', 'github:octo/other#2',
			'github:octo/example#99']
		refreshed_ids:      ['github:octo/other#2', 'github:octo/example#3']
		first_label:        'bug'
		secret_environment: 'CONTRACT_GITHUB_TOKEN'
	})
}
