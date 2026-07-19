module tracker

import json2
import os
import yaml
import symphony.domain
import symphony.workflow

const github_candidates_page_one = '[{"id":3003,"node_id":"I_node_3","number":3,"title":"Third issue","body":"Third body","state":"open","html_url":"https://github.test/octo/example/issues/3","labels":[{"name":"status:todo"},{"name":" Bug "},{"name":"RSVP"}],"assignee":{"login":"octocat","node_id":"U_1"},"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-02T00:00:00Z"},{"id":3010,"node_id":"I_pr","number":10,"title":"A pull request","body":"","state":"open","html_url":"https://github.test/octo/example/pull/10","labels":[{"name":"status:todo"}],"pull_request":{"url":"https://api.github.test/pulls/10"},"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-02T00:00:00Z"},{"id":3011,"node_id":"I_unmapped","number":11,"title":"Unmapped","body":"","state":"open","html_url":"https://github.test/octo/example/issues/11","labels":[{"name":"bug"}],"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-02T00:00:00Z"},{"id":3012,"node_id":"I_conflict","number":12,"title":"Conflicting","body":"","state":"open","html_url":"https://github.test/octo/example/issues/12","labels":[{"name":"status:todo"},{"name":"status:in-progress"}],"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-02T00:00:00Z"},{"id":3013,"node_id":"I_closed","number":13,"title":"Closed","body":"","state":"closed","html_url":"https://github.test/octo/example/issues/13","labels":[],"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-02T00:00:00Z"}]'

const github_candidates_page_two = '[{"id":3002,"node_id":"I_node_2","number":2,"title":"Second issue","body":null,"state":"open","html_url":"https://github.test/octo/example/issues/2","labels":[{"name":"status:in-progress"}],"assignee":null,"created_at":"2026-07-03T00:00:00Z","updated_at":"2026-07-04T00:00:00Z"}]'

const github_issue_two = '{"id":3002,"node_id":"I_node_2","number":2,"title":"Second issue","body":null,"state":"open","html_url":"https://github.test/octo/example/issues/2","labels":[{"name":"status:in-progress"}],"assignee":null,"created_at":"2026-07-03T00:00:00Z","updated_at":"2026-07-04T00:00:00Z"}'

const github_issue_three = '{"id":3003,"node_id":"I_node_3","number":3,"title":"Third issue","body":"Third body","state":"open","html_url":"https://github.test/octo/example/issues/3","labels":[{"name":"status:todo"},{"name":"Bug"}],"assignee":{"login":"octocat","node_id":"U_1"},"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-02T00:00:00Z"}'

const github_issue_conflicting = '{"id":3012,"node_id":"I_conflict","number":12,"title":"Conflicting","body":"","state":"open","html_url":"https://github.test/octo/example/issues/12","labels":[{"name":"status:todo"},{"name":"status:in-progress"}],"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-02T00:00:00Z"}'

const github_write_source = '{"id":3003,"node_id":"I_node_3","number":3,"title":"Third issue","body":"Third body","state":"open","html_url":"https://github.test/octo/example/issues/3","labels":[{"name":"status:todo"},{"name":"Bug"},{"name":"RSVP"}],"assignee":{"login":"octocat"},"created_at":"2026-07-01T00:00:00Z","updated_at":"2026-07-02T00:00:00Z"}'

fn github_paged_transport(request GitHubRequest) !GitHubResponse {
	assert request.method == 'GET'
	assert request.token == 'secret'
	if request.url.ends_with('&page=2') {
		return GitHubResponse{
			status: 200
			body:   github_candidates_page_two
		}
	}
	assert request.url == 'https://api.github.test/repos/octo/example/issues?state=all&per_page=100'
	return GitHubResponse{
		status:   200
		body:     github_candidates_page_one
		next_url: '${request.url}&page=2'
	}
}

fn github_refresh_transport(request GitHubRequest) !GitHubResponse {
	assert request.method == 'GET'
	if request.url.ends_with('/issues/2') {
		return GitHubResponse{
			status: 200
			body:   github_issue_two
		}
	}
	if request.url.ends_with('/issues/3') {
		return GitHubResponse{
			status: 200
			body:   github_issue_three
		}
	}
	return GitHubResponse{
		status: 404
		body:   '{"message":"Not Found"}'
	}
}

fn github_failing_transport(request GitHubRequest) !GitHubResponse {
	return error('simulated transport failure containing ${request.token}')
}

fn github_conflicting_refresh_transport(_ GitHubRequest) !GitHubResponse {
	return GitHubResponse{
		status: 200
		body:   github_issue_conflicting
	}
}

fn github_repeating_page_transport(request GitHubRequest) !GitHubResponse {
	return GitHubResponse{
		status:   200
		body:     '[]'
		next_url: request.url
	}
}

fn github_cross_origin_page_transport(request GitHubRequest) !GitHubResponse {
	assert !request.url.starts_with('https://untrusted.test')
	return GitHubResponse{
		status:   200
		body:     '[]'
		next_url: 'https://untrusted.test/issues?page=2'
	}
}

fn github_success_write_transport(request GitHubRequest) !GitHubResponse {
	assert request.url.ends_with('/repos/octo/example/issues/3')
	if request.method == 'GET' {
		return GitHubResponse{
			status: 200
			body:   github_write_source
		}
	}
	assert request.method == 'PATCH'
	payload := json2.decode[json2.Any](request.body) or { panic(err) }.as_map()
	labels := (payload['labels'] or { panic('labels') }).as_array().map(it.str())
	assert labels == ['Bug', 'RSVP', 'status:agent-complete']
	return GitHubResponse{
		status: 200
		body:   github_write_source
	}
}

fn github_blocked_write_transport(request GitHubRequest) !GitHubResponse {
	if request.method == 'GET' {
		return GitHubResponse{
			status: 200
			body:   github_write_source
		}
	}
	payload := json2.decode[json2.Any](request.body) or { panic(err) }.as_map()
	labels := (payload['labels'] or { panic('labels') }).as_array().map(it.str())
	assert labels == ['Bug', 'RSVP', 'status:blocked']
	return GitHubResponse{
		status: 200
		body:   github_write_source
	}
}

fn github_mutation_failure_transport(request GitHubRequest) !GitHubResponse {
	if request.method == 'GET' {
		return GitHubResponse{
			status: 200
			body:   github_write_source
		}
	}
	return GitHubResponse{
		status: 500
		body:   '{"message":"failed"}'
	}
}

fn github_read_test_client(transport GitHubTransport) GitHubClient {
	return GitHubClient{
		endpoint:        'https://api.github.test'
		token:           'secret'
		repository:      'octo/example'
		state_labels:    {
			'Todo':           'status:todo'
			'In Progress':    'status:in-progress'
			'Agent Complete': 'status:agent-complete'
			'Blocked':        'status:blocked'
		}
		closed_state:    'Closed'
		active_states:   ['Todo', 'In Progress']
		terminal_states: ['Closed', 'Agent Complete', 'Blocked']
		transport:       transport
	}
}

fn github_write_test_client(transport GitHubTransport) GitHubClient {
	return GitHubClient{
		...github_read_test_client(transport)
		write_outcomes: true
		success_state:  'Agent Complete'
		blocked_state:  'Blocked'
	}
}

fn test_github_adapter_factory_resolves_repository_scope_and_secret() {
	defer {
		os.unsetenv('SYMPHONY_GITHUB_TEST_TOKEN')
	}
	os.setenv('SYMPHONY_GITHUB_TEST_TOKEN', 'github-secret', true)
	adapter := new_adapter(workflow.TrackerConfig{
		kind:            'github'
		provider:        {
			'repository':   yaml.Any('octo/example')
			'token':        yaml.Any('$SYMPHONY_GITHUB_TEST_TOKEN')
			'state_labels': yaml.Any({
				'Todo':        yaml.Any('status:todo')
				'In Progress': yaml.Any('status:in-progress')
			})
		}
		active_states:   ['Todo', 'In Progress']
		terminal_states: ['Closed']
	}) or { panic(err) }

	assert adapter.secret_environment_names() == ['SYMPHONY_GITHUB_TEST_TOKEN']
	assert adapter.secret_values() == ['github-secret']
	assert adapter.fetch_issues_by_states([]) or { panic(err) } == []domain.Issue{}
	assert adapter.fetch_issues_by_ids([]) or { panic(err) } == []domain.Issue{}
}

fn test_github_adapter_rejects_repository_outside_owner_name_scope() {
	new_adapter(workflow.TrackerConfig{
		kind:            'github'
		provider:        {
			'repository':   yaml.Any('octo/example/extra')
			'token':        yaml.Any('secret')
			'state_labels': yaml.Any({
				'Todo': yaml.Any('status:todo')
			})
		}
		active_states:   ['Todo']
		terminal_states: ['Closed']
	}) or {
		assert err.msg().contains('invalid_tracker_config')
		assert err.msg().contains('owner/name')
		return
	}
	assert false, 'GitHub scope must be exactly one owner and repository'
}

fn test_github_adapter_rejects_duplicate_normalized_status_labels() {
	new_adapter(workflow.TrackerConfig{
		kind:            'github'
		provider:        {
			'repository':   yaml.Any('octo/example')
			'token':        yaml.Any('secret')
			'state_labels': yaml.Any({
				'Todo':        yaml.Any(' Status:Ready ')
				'In Progress': yaml.Any('status:ready')
			})
		}
		active_states:   ['Todo', 'In Progress']
		terminal_states: ['Closed']
	}) or {
		assert err.msg().contains('invalid_tracker_config')
		assert err.msg().contains('unique')
		return
	}
	assert false, 'GitHub status labels must map one-to-one with states'
}

fn test_github_adapter_requires_every_active_state_to_have_a_status_label() {
	new_adapter(workflow.TrackerConfig{
		kind:            'github'
		provider:        {
			'repository':   yaml.Any('octo/example')
			'token':        yaml.Any('secret')
			'state_labels': yaml.Any({
				'Todo': yaml.Any('status:todo')
			})
		}
		active_states:   ['Todo', 'In Progress']
		terminal_states: ['Closed']
	}) or {
		assert err.msg().contains('invalid_tracker_config')
		assert err.msg().contains('In Progress')
		return
	}
	assert false, 'every active GitHub state must have a status label'
}

fn test_github_adapter_requires_closed_state_to_be_terminal() {
	new_adapter(workflow.TrackerConfig{
		kind:            'github'
		provider:        {
			'repository':   yaml.Any('octo/example')
			'token':        yaml.Any('secret')
			'closed_state': yaml.Any('Archived')
			'state_labels': yaml.Any({
				'Todo': yaml.Any('status:todo')
			})
		}
		active_states:   ['Todo']
		terminal_states: ['Closed']
	}) or {
		assert err.msg().contains('invalid_tracker_config')
		assert err.msg().contains('closed_state')
		return
	}
	assert false, 'closed GitHub issues must normalize to a terminal state'
}

fn test_github_write_mode_rejects_active_success_state() {
	new_adapter(workflow.TrackerConfig{
		kind:            'github'
		provider:        {
			'repository':     yaml.Any('octo/example')
			'token':          yaml.Any('secret')
			'write_outcomes': yaml.Any(true)
			'success_state':  yaml.Any('Todo')
			'blocked_state':  yaml.Any('Blocked')
			'state_labels':   yaml.Any({
				'Todo':    yaml.Any('status:todo')
				'Blocked': yaml.Any('status:blocked')
			})
		}
		active_states:   ['Todo']
		terminal_states: ['Closed', 'Blocked']
	}) or {
		assert err.msg().contains('invalid_tracker_config')
		assert err.msg().contains('success_state')
		assert err.msg().contains('terminal')
		return
	}
	assert false, 'GitHub write outcomes must transition out of active states'
}

fn test_github_success_outcome_replaces_status_label_and_preserves_routing_labels() {
	client := github_write_test_client(github_success_write_transport)
	issue := client.fetch_issues_by_ids(['github:octo/example#3'])![0]

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	}) or { panic(err) }

	assert completed
}

fn test_github_blocked_outcome_applies_terminal_label_without_marking_completion() {
	client := github_write_test_client(github_blocked_write_transport)
	issue := client.fetch_issues_by_ids(['github:octo/example#3'])![0]

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:          .blocked
		issue_id:      issue.id
		error_message: 'operator input needed'
	}) or { panic(err) }

	assert !completed
}

fn test_github_abnormal_outcomes_do_not_contact_provider() {
	client := github_write_test_client(github_failing_transport)
	issue := domain.Issue{
		id:         'github:octo/example#3'
		identifier: 'octo/example#3'
	}

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .failed
		issue_id: issue.id
	}) or { panic(err) }

	assert !completed
}

fn test_github_read_only_outcomes_do_not_contact_provider() {
	client := github_read_test_client(github_failing_transport)
	issue := domain.Issue{
		id:         'github:octo/example#3'
		identifier: 'octo/example#3'
	}

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	}) or { panic(err) }

	assert !completed
}

fn test_github_mutation_failure_is_not_treated_as_persisted_completion() {
	client := github_write_test_client(github_mutation_failure_transport)
	issue := client.fetch_issues_by_ids(['github:octo/example#3'])![0]

	client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	}) or {
		assert err.msg().contains('tracker_status')
		return
	}
	assert false, 'failed GitHub mutation must not report persisted completion'
}

fn test_github_candidate_reads_paginate_and_normalize_only_unambiguous_issues() {
	client := github_read_test_client(github_paged_transport)

	issues := client.fetch_issues_by_states(['Todo', 'In Progress']) or { panic(err) }

	assert issues.map(it.id) == ['github:octo/example#2', 'github:octo/example#3']
	assert issues.map(it.identifier) == ['octo/example#2', 'octo/example#3']
	assert issues[1].description == 'Third body'
	assert issues[1].labels == ['bug', 'rsvp']
	assert issues[1].assignee_id == 'octocat'
	assert issues[1].dispatchable
	assert (issues[1].native_ref['github_node_id'] or { panic('github_node_id') }).str() == 'I_node_3'
	assert (issues[1].native_ref['repository'] or { panic('repository') }).str() == 'octo/example'
	assert (issues[1].native_ref['number'] or { panic('number') }).int() == 3
}

fn test_github_id_refresh_preserves_order_deduplicates_and_omits_missing_issues() {
	client := github_read_test_client(github_refresh_transport)

	issues := client.fetch_issues_by_ids([
		'github:octo/example#3',
		'github:octo/example#404',
		'github:octo/example#2',
		'github:octo/example#3',
	]) or { panic(err) }

	assert issues.map(it.id) == ['github:octo/example#3', 'github:octo/example#2']
	assert issues.map(it.state) == ['Todo', 'In Progress']
}

fn test_github_id_refresh_rejects_ambiguous_status_labels() {
	client := github_read_test_client(github_conflicting_refresh_transport)

	client.fetch_issues_by_ids(['github:octo/example#12']) or {
		assert err.msg().contains('tracker_response')
		return
	}
	assert false, 'strict GitHub refresh must reject conflicting workflow labels'
}

fn test_github_id_refresh_rejects_identity_from_another_repository() {
	client := github_read_test_client(github_failing_transport)

	client.fetch_issues_by_ids(['github:another/repository#3']) or {
		assert err.msg().contains('invalid_tracker_id')
		assert err.msg().contains('octo/example')
		return
	}
	assert false, 'GitHub IDs must remain scoped to the configured repository'
}

fn test_github_transport_failures_are_classified_without_leaking_the_token() {
	client := github_read_test_client(github_failing_transport)

	client.fetch_issues_by_states(['Todo']) or {
		assert err.msg().contains('tracker_request')
		assert !err.msg().contains('secret')
		return
	}
	assert false, 'GitHub transport failures must use a safe error category'
}

fn test_github_link_parser_selects_only_the_next_relation() {
	header := '<https://api.github.test/repos/octo/example/issues?page=1>; rel="prev", <https://api.github.test/repos/octo/example/issues?page=3>; rel="next", <https://api.github.test/repos/octo/example/issues?page=9>; rel="last"'

	assert github_next_link(header) == 'https://api.github.test/repos/octo/example/issues?page=3'
	assert github_next_link('<https://api.github.test/issues?page=1>; rel="prev"') == ''
}

fn test_github_candidate_reads_reject_repeated_pagination_urls() {
	client := github_read_test_client(github_repeating_page_transport)

	client.fetch_issues_by_states(['Todo']) or {
		assert err.msg().contains('tracker_pagination')
		assert err.msg().contains('repeated')
		return
	}
	assert false, 'GitHub pagination loops must be rejected'
}

fn test_github_candidate_reads_reject_cross_origin_pagination_urls() {
	client := github_read_test_client(github_cross_origin_page_transport)

	client.fetch_issues_by_states(['Todo']) or {
		assert err.msg().contains('tracker_pagination')
		assert err.msg().contains('scope')
		return
	}
	assert false, 'GitHub pagination must not send credentials outside the configured repository'
}

fn test_github_status_errors_distinguish_auth_permission_and_rate_limits() {
	client := github_read_test_client(github_paged_transport)
	mut categories := []string{}
	client.check_response(GitHubResponse{ status: 401 }) or {
		categories << err.msg().all_before(':')
	}
	client.check_response(GitHubResponse{ status: 403 }) or {
		categories << err.msg().all_before(':')
	}
	client.check_response(GitHubResponse{
		status:       403
		rate_limited: true
	}) or { categories << err.msg().all_before(':') }
	assert categories == ['tracker_authentication', 'tracker_permission', 'tracker_rate_limited']
}

fn test_closed_github_issue_normalizes_to_terminal_state_without_status_label() {
	client := github_read_test_client(github_paged_transport)

	issues := client.fetch_issues_by_states(['Closed']) or { panic(err) }

	assert issues.map(it.identifier) == ['octo/example#13']
	assert issues[0].state == 'Closed'
	assert !issues[0].dispatchable
}
