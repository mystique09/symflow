module orchestrator

import os
import time
import yaml
import symphony.domain
import symphony.tracker
import symphony.workflow

struct NonDispatchableTracker {
	issue domain.Issue
}

fn (client NonDispatchableTracker) fetch_issues_by_states(_ []string) ![]domain.Issue {
	return [client.issue]
}

fn (_ NonDispatchableTracker) fetch_issues_by_ids(_ []string) ![]domain.Issue {
	return []domain.Issue{}
}

fn (_ NonDispatchableTracker) fetch_completed_issues(_ []string) ![]domain.Issue {
	return []domain.Issue{}
}

fn (_ NonDispatchableTracker) record_outcome(_ domain.Issue, _ domain.AttemptOutcome) !bool {
	return false
}

fn (_ NonDispatchableTracker) secret_environment_names() []string {
	return []string{}
}

fn (_ NonDispatchableTracker) secret_values() []string {
	return []string{}
}

fn (_ NonDispatchableTracker) validate_scope() ! {}

fn test_successful_file_outcome_releases_claim_without_continuation() {
	dir := service_file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	ticket_path := os.join_path(dir, 'SYM-400.md')
	os.write_file(ticket_path,
		'---\nschema_version: 1\nid: "opaque-400"\nidentifier: SYM-400\ntitle: "Do local work"\nstate: Todo\ndispatch_status: pending\nlast_error: ""\ncompleted_at: ""\n---\n\nWork locally.\n')!
	definition := workflow.WorkflowDefinition{
		config: workflow.Config{
			tracker: workflow.TrackerConfig{
				kind:     'file'
				provider: {
					'root': yaml.Any(dir)
				}
			}
			agent:   workflow.AgentConfig{
				max_concurrent_agents: 1
				max_retry_backoff_ms:  300_000
			}
		}
	}
	client := tracker.new_adapter(definition.config.tracker)!
	issue := client.fetch_issues_by_states(['Todo'])![0]
	runtime := start_runtime(1, 300_000)
	defer {
		runtime.shutdown()
	}
	assert runtime.claim(issue, 0, 1_000)
	mut cancellations := map[string]chan bool{}
	mut remove_after_finish := map[string]bool{}

	handle_worker_event(runtime, WorkerEvent{
		definition: definition
		issue:      issue
		outcome:    domain.AttemptOutcome{
			kind:     .succeeded
			issue_id: issue.id
		}
	}, mut cancellations, mut remove_after_finish)

	snapshot := runtime.snapshot(2_000)
	assert snapshot.running.len == 0
	assert snapshot.retrying.len == 0
	assert snapshot.completed.map(it.issue_identifier) == ['SYM-400']
	assert os.read_file(ticket_path)!.contains('dispatch_status: completed')
}

fn test_poll_syncs_persisted_file_completions_after_restart() {
	dir := service_file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'SYM-401.md'),
		'---\nschema_version: 1\nid: "opaque-401"\nidentifier: SYM-401\ntitle: "Already done"\nstate: Todo\ndispatch_status: completed\nlast_error: ""\ncompleted_at: "2026-07-23T01:00:00Z"\n---\n\nCompleted earlier.\n')!
	definition := workflow.WorkflowDefinition{
		config: workflow.Config{
			tracker: workflow.TrackerConfig{
				kind:            'file'
				provider:        {
					'root': yaml.Any(dir)
				}
				active_states:   ['Todo']
				terminal_states: ['Done']
			}
			agent:   workflow.AgentConfig{
				max_concurrent_agents: 1
				max_retry_backoff_ms:  300_000
			}
		}
	}
	runtime := start_runtime(1, 300_000)
	defer {
		runtime.shutdown()
	}
	mut cancellations := map[string]chan bool{}
	mut remove_after_finish := map[string]bool{}

	poll_and_dispatch(definition, runtime, chan WorkerEvent{cap: 1}, mut cancellations,
		mut remove_after_finish)!

	completed := runtime.snapshot(2_000).completed
	assert completed.map(it.issue_identifier) == ['SYM-401']
	assert completed[0].completed_at == '2026-07-23T01:00:00Z'
	assert cancellations.len == 0
}

fn test_worker_outcome_stays_bound_to_its_original_tracker_definition() {
	original_dir := service_file_tracker_test_dir()
	reloaded_dir := service_file_tracker_test_dir()
	defer {
		os.rmdir_all(original_dir) or {}
		os.rmdir_all(reloaded_dir) or {}
	}
	ticket := '---\nschema_version: 1\nid: "shared-issue"\nidentifier: SYM-RELOAD\ntitle: "Scoped work"\nstate: Todo\ndispatch_status: pending\nlast_error: ""\ncompleted_at: ""\n---\n\nStay in scope.\n'
	original_path := os.join_path(original_dir, 'SYM-RELOAD.md')
	reloaded_path := os.join_path(reloaded_dir, 'SYM-RELOAD.md')
	os.write_file(original_path, ticket)!
	os.write_file(reloaded_path, ticket)!
	original_definition := workflow.WorkflowDefinition{
		config: workflow.Config{
			tracker: workflow.TrackerConfig{
				kind:     'file'
				provider: {
					'root': yaml.Any(original_dir)
				}
			}
			agent:   workflow.AgentConfig{
				max_concurrent_agents: 1
				max_retry_backoff_ms:  300_000
			}
		}
	}
	issue := tracker.new_adapter(original_definition.config.tracker)!.fetch_issues_by_states([
		'Todo',
	])![0]
	runtime := start_runtime(1, 300_000)
	defer {
		runtime.shutdown()
	}
	assert runtime.claim(issue, 0, 1_000)
	mut cancellations := map[string]chan bool{}
	mut remove_after_finish := map[string]bool{}

	handle_worker_event(runtime, WorkerEvent{
		definition: original_definition
		issue:      issue
		outcome:    domain.AttemptOutcome{
			kind:     .succeeded
			issue_id: issue.id
		}
	}, mut cancellations, mut remove_after_finish)

	assert os.read_file(original_path)!.contains('dispatch_status: completed')
	assert os.read_file(reloaded_path)!.contains('dispatch_status: pending')
}

fn test_non_dispatchable_tracker_issue_never_starts_worker() {
	runtime := start_runtime(1, 300_000)
	defer {
		runtime.shutdown()
	}
	definition := workflow.WorkflowDefinition{
		config: workflow.Config{
			tracker: workflow.TrackerConfig{
				active_states: ['Todo']
			}
			agent:   workflow.AgentConfig{
				max_concurrent_agents: 1
				max_retry_backoff_ms:  300_000
			}
		}
	}
	client := tracker.Tracker(NonDispatchableTracker{
		issue: domain.Issue{
			id:           'provider-1'
			identifier:   'PROVIDER-1'
			title:        'Do not dispatch'
			state:        'Todo'
			dispatchable: false
		}
	})
	mut cancellations := map[string]chan bool{}
	dispatch_candidates(definition, runtime, client, scheduling_policy(definition.config),
		chan WorkerEvent{cap: 1}, mut cancellations) or { panic(err) }

	assert runtime.snapshot(time.now().unix_milli()).running.len == 0
	assert cancellations.len == 0
}

fn service_file_tracker_test_dir() string {
	path := os.join_path(os.temp_dir(),
		'symphony-service-file-tracker-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}

fn test_secret_environment_lookup_fails_closed_for_invalid_adapter() {
	secret_environment_names(workflow.Config{
		tracker: workflow.TrackerConfig{
			kind: 'unsupported'
		}
	}) or {
		assert err.msg().contains('unsupported_tracker_kind')
		return
	}
	assert false, 'invalid adapters must not produce an empty hook secret list'
}

fn test_failed_live_reload_keeps_last_known_good_definition() {
	dir := service_file_tracker_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	current := workflow.WorkflowDefinition{
		raw_front_matter: 'tracker: file'
		prompt_template:  'current prompt'
		config:           workflow.Config{
			tracker: workflow.TrackerConfig{
				kind:     'file'
				provider: {
					'root': yaml.Any(dir)
				}
			}
		}
	}
	next := workflow.WorkflowDefinition{
		raw_front_matter: 'tracker: unsupported'
		prompt_template:  'replacement prompt'
		config:           workflow.Config{
			tracker: workflow.TrackerConfig{
				kind: 'unsupported'
			}
		}
	}

	decision := select_effective_definition(current, next)
	assert decision.error_message.contains('unsupported_tracker_kind')
	assert decision.definition.prompt_template == 'current prompt'
}

fn test_workspace_git_policy_keeps_the_agent_off_protected_branches() {
	prompt := prepend_workspace_git_policy('Implement the ticket.', 'feature/ops-42', 'staging')

	assert prompt.contains('Work only on the prepared issue branch `feature/ops-42`')
	assert prompt.contains('protected base branch `staging`, `main`, or `master`')
	assert prompt.contains('Do not push any branch unless the issue or workflow explicitly requires it')
	assert prompt.ends_with('Implement the ticket.')
	assert prepend_workspace_git_policy('Plain prompt.', '', 'main') == 'Plain prompt.'
}

fn test_workspace_git_cancellation_is_not_retried_as_a_failure() {
	assert failure_outcome_kind('workspace_git_canceled: branch preparation was canceled') == .canceled
	assert failure_outcome_kind('hook_canceled: hook was canceled') == .canceled
	assert failure_outcome_kind('workspace_git_error: checkout failed') == .failed
}

fn test_worker_workspace_revalidates_the_issue_branch_after_before_run() {
	root := service_file_tracker_test_dir()
	defer {
		os.rmdir_all(root) or {}
	}
	definition := workflow.WorkflowDefinition{
		config: workflow.Config{
			workspace: workflow.WorkspaceConfig{
				root:        root
				base_branch: 'main'
			}
			hooks:     workflow.HooksConfig{
				after_create: 'git init -b main && git config user.name "Symphony Test" && git config user.email "symphony@example.test" && printf main > marker.txt && git add marker.txt && git commit -m main && git branch feature/ops-42'
				before_run:   'git switch main'
				timeout_ms:   5_000
			}
		}
	}
	cancel := chan bool{}
	prepared := prepare_worker_workspace(definition, domain.Issue{
		id:          'issue-42'
		identifier:  'OPS-42'
		branch_name: 'feature/ops-42'
	}, []string{}, cancel)!
	command := 'git -C ${os.quoted_path(prepared.space.path)} branch --show-current'
	result := os.execute(command)

	assert result.exit_code == 0
	assert result.output.trim_space() == 'feature/ops-42'
	assert prepared.branch == 'feature/ops-42'
}
