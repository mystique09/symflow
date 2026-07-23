module tracker

import os
import time
import yaml
import symphony.domain
import symphony.workflow

fn test_file_client_reads_pending_markdown_and_filters_states() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending',
		'Full description')!
	write_file_ticket(dir, 'SYM-401.md', 'opaque-401', 'SYM-401', 'In Progress', 'completed',
		'Already handled')!

	client := new_file_client(dir)!
	issues := client.fetch_issues_by_states(['Todo', 'In Progress'])!

	assert issues.len == 1
	assert issues[0].id == 'opaque-400'
	assert issues[0].identifier == 'SYM-400'
	assert issues[0].state == 'Todo'
	assert issues[0].description == 'Full description'
	assert issues[0].dispatchable
}

fn test_file_client_id_refresh_preserves_requested_order_and_completed_visibility() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending', 'First')!
	write_file_ticket(dir, 'SYM-401.md', 'opaque-401', 'SYM-401', 'In Progress', 'completed',
		'Second')!
	client := new_file_client(dir)!

	issues := client.fetch_issues_by_ids(['opaque-401', 'missing', 'opaque-400'])!

	assert issues.map(it.identifier) == ['SYM-401', 'SYM-400']
	assert !issues[0].dispatchable
	assert issues[1].dispatchable
}

fn test_file_client_lists_only_persisted_completions() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending', 'Pending')!
	completed_path := write_file_ticket(dir, 'SYM-401.md', 'opaque-401', 'SYM-401', 'In Progress',
		'completed', 'Completed')!
	write_file_ticket(dir, 'SYM-402.md', 'opaque-402', 'SYM-402', 'In Review', 'blocked', 'Blocked')!
	content := os.read_file(completed_path)!
	os.write_file(completed_path, content.replace('completed_at: ""',
		'completed_at: "2026-07-23T01:00:00Z"'))!
	client := new_file_client(dir)!

	completed := client.fetch_completed_issues(['Done'])!

	assert completed.map(it.identifier) == ['SYM-401']
	assert completed[0].completed_at == '2026-07-23T01:00:00Z'
	assert !completed[0].dispatchable
}

fn test_file_client_id_refresh_returns_each_requested_ticket_once() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending', 'First')!
	client := new_file_client(dir)!

	issues := client.fetch_issues_by_ids(['opaque-400', 'opaque-400'])!

	assert issues.map(it.identifier) == ['SYM-400']
}

fn test_file_client_marks_todo_with_open_or_unknown_blockers_not_dispatchable() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	open_path := write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending',
		'Open blocker')!
	unknown_path := write_file_ticket(dir, 'SYM-401.md', 'opaque-401', 'SYM-401', 'Todo',
		'pending', 'Unknown blocker state')!
	terminal_path := write_file_ticket(dir, 'SYM-402.md', 'opaque-402', 'SYM-402', 'Todo',
		'pending', 'Terminal blocker')!
	set_file_ticket_blocker(open_path, 'In Progress')!
	set_file_ticket_blocker(unknown_path, '')!
	set_file_ticket_blocker(terminal_path, 'Done')!
	client := new_file_client(dir)!

	issues := client.fetch_issues_by_states(['Todo'])!
	assert issues.map(it.identifier) == ['SYM-400', 'SYM-401', 'SYM-402']
	assert issues[0].blocked_by.len == 1
	assert issues[0].blocked_by[0].state == 'In Progress'
	assert issues[1].blocked_by.len == 1
	assert issues[1].blocked_by[0].state == ''
	assert issues[2].blocked_by.len == 1
	assert issues[2].blocked_by[0].state == 'Done'
	assert !issues[0].dispatchable
	assert !issues[1].dispatchable
	assert issues[2].dispatchable
}

fn test_file_client_rejects_duplicate_ids() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	write_file_ticket(dir, 'SYM-400.md', 'same-id', 'SYM-400', 'Todo', 'pending', 'First')!
	write_file_ticket(dir, 'SYM-401.md', 'same-id', 'SYM-401', 'Todo', 'pending', 'Second')!
	client := new_file_client(dir)!

	client.fetch_issues_by_states(['Todo']) or {
		assert err.msg().contains('file_tracker_duplicate_error')
		assert err.msg().contains('SYM-401.md')
		assert !err.msg().contains('First')
		return
	}
	assert false
}

fn test_file_client_rejects_malformed_and_invalid_status_tickets() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'unknown',
		'Secret body')!
	client := new_file_client(dir)!

	client.fetch_issues_by_states(['Todo']) or {
		assert err.msg().contains('file_tracker_status_error')
		assert err.msg().contains(os.file_name(path))
		assert !err.msg().contains('Secret body')
		return
	}
	assert false
}

fn test_adapter_factory_selects_file_without_tracker_secrets() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	adapter := new_adapter(workflow.TrackerConfig{
		kind:     'file'
		provider: {
			'root': yaml.Any(dir)
		}
	})!
	assert adapter.secret_environment_names() == []
	assert adapter.secret_values() == []
	assert adapter.fetch_issues_by_states(['Todo'])! == []
}

fn test_file_adapter_uses_configured_terminal_states_for_blockers() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending',
		'Custom terminal blocker')!
	set_file_ticket_blocker(path, 'Released')!
	adapter := new_adapter(workflow.TrackerConfig{
		kind:            'file'
		provider:        {
			'root': yaml.Any(dir)
		}
		terminal_states: ['Released']
	})!

	issues := adapter.fetch_issues_by_states(['Todo'])!
	assert issues.len == 1
	assert issues[0].dispatchable
}

fn test_tracker_interface_records_file_completion() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending', 'Body')!
	adapter := new_adapter(workflow.TrackerConfig{
		kind:     'file'
		provider: {
			'root': yaml.Any(dir)
		}
	})!
	issue := adapter.fetch_issues_by_ids(['opaque-400'])![0]

	completed := adapter.record_outcome(issue, domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	})!

	assert completed
}

fn test_file_outcome_completion_is_atomic_and_preserves_body() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending',
		'Full description that must survive')!
	client := new_file_client(dir)!
	issue := client.fetch_issues_by_ids(['opaque-400'])![0]

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	})!

	assert completed
	refreshed := client.fetch_issues_by_ids([issue.id])!
	assert refreshed.len == 1
	assert !refreshed[0].dispatchable
	content := os.read_file(path)!
	assert content.contains('dispatch_status: completed')
	assert content.contains('Full description that must survive')
}

fn test_file_outcome_blocked_persists_reason() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path :=
		write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending', 'Body')!
	client := new_file_client(dir)!
	issue := client.fetch_issues_by_ids(['opaque-400'])![0]

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:          .blocked
		issue_id:      issue.id
		error_message: 'operator input needed'
	})!

	assert !completed
	content := os.read_file(path)!
	assert content.contains('dispatch_status: blocked')
	assert content.contains('last_error: "operator input needed"')
}

fn test_file_outcome_failure_remains_pending() {
	dir := file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path :=
		write_file_ticket(dir, 'SYM-400.md', 'opaque-400', 'SYM-400', 'Todo', 'pending', 'Body')!
	client := new_file_client(dir)!
	issue := client.fetch_issues_by_ids(['opaque-400'])![0]

	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind:          .failed
		issue_id:      issue.id
		error_message: 'verification failed'
	})!

	assert !completed
	content := os.read_file(path)!
	assert content.contains('dispatch_status: pending')
	assert content.contains('last_error: "verification failed"')
}

fn write_file_ticket(dir string, filename string, id string, identifier string, state string, dispatch_status string, description string) !string {
	path := os.join_path(dir, filename)
	content := '---\nschema_version: 1\nid: "${id}"\nidentifier: ${identifier}\ntitle: "Ticket ${identifier}"\nstate: "${state}"\npriority: 2\nlabels:\n  - Bug\n  - rsvp\nbranch_name: "branch/${identifier.to_lower()}"\nsource_url: "https://linear.example/${identifier}"\nassignee_id: "user-1"\nassignee_name: "Benjie"\nparent_identifier: ""\ncreated_at: "2026-07-15T00:00:00Z"\nupdated_at: "2026-07-16T00:00:00Z"\ndispatch_status: ${dispatch_status}\nlast_error: ""\ncompleted_at: ""\nblocked_by: []\n---\n\n${description}\n'
	os.write_file(path, content)!
	return path
}

fn set_file_ticket_blocker(path string, state string) ! {
	content := os.read_file(path)!
	blockers := 'blocked_by:\n  - id: "opaque-blocker"\n    identifier: "SYM-399"\n    state: "${state}"\n    created_at: ""\n    updated_at: ""'
	os.write_file(path, content.replace('blocked_by: []', blockers))!
}

fn file_tracker_test_dir() string {
	path := os.join_path(os.temp_dir(),
		'symphony-file-tracker-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}
