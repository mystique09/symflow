module orchestrator

import time
import symphony.codex
import symphony.domain
import symphony.observability
import symphony.prompt
import symphony.scheduler
import symphony.tracker
import symphony.workflow
import symphony.workspace

const service_tick = 25 * time.millisecond
const shutdown_timeout = 10 * time.second
const service_message_limit = 8 * 1024

struct WorkerEvent {
	definition workflow.WorkflowDefinition
	issue      domain.Issue
	outcome    domain.AttemptOutcome
}

struct DefinitionReloadDecision {
	definition    workflow.WorkflowDefinition
	error_message string
}

pub struct ServiceOptions {
pub:
	workflow_path string
	once          bool
}

pub fn run_service(options ServiceOptions, runtime Runtime, refresh chan bool, shutdown chan bool) ! {
	mut store := workflow.new_store(options.workflow_path, .dispatch)
	mut definition := store.reload()!
	tracker.activate_adapter(definition.config.tracker)!
	cleanup_terminal_workspaces(definition) or {
		emit(definition, 'warn', 'startup_cleanup_failed', domain.Issue{}, 0, err.msg())
	}
	events := chan WorkerEvent{cap: definition.config.agent.max_concurrent_agents * 4}
	mut cancellations := map[string]chan bool{}
	mut remove_after_finish := map[string]bool{}
	mut next_poll_ms := i64(0)
	mut dispatched_once := false
	for {
		now_ms := time.now().unix_milli()
		if now_ms >= next_poll_ms {
			if next := store.reload() {
				decision := select_effective_definition(definition, next)
				if decision.error_message != '' {
					emit(definition, 'error', 'workflow_reload_failed', domain.Issue{}, 0,
						decision.error_message)
				}
				definition = decision.definition
			} else {
				emit(definition, 'error', 'workflow_reload_failed', domain.Issue{}, 0, err.msg())
			}
			poll_and_dispatch(definition, runtime, events, mut cancellations, mut
				remove_after_finish) or {
				emit(definition, 'error', 'poll_failed', domain.Issue{}, 0, err.msg())
			}
			dispatched_once = true
			next_poll_ms = now_ms + i64(definition.config.polling.interval_ms)
		}
		if options.once && dispatched_once && runtime.snapshot(now_ms).running.len == 0 {
			return
		}
		select {
			event := <-events {
				handle_worker_event(runtime, event, mut cancellations, mut remove_after_finish)
			}
			_ := <-refresh {
				released := runtime.release_blocked()
				if released > 0 {
					emit(definition, 'info', 'blocked_claims_released', domain.Issue{}, 0,
						'released ${released} blocked claim(s)')
				}
				next_poll_ms = 0
			}
			_ := <-shutdown {
				cancel_all(cancellations)
				drain_workers(runtime, events, mut cancellations, mut remove_after_finish)
				return
			}
			service_tick {}
		}
	}
}

fn select_effective_definition(current workflow.WorkflowDefinition, next workflow.WorkflowDefinition) DefinitionReloadDecision {
	// Provider scope is live-validated only when tracker front matter may have
	// changed. A rejected replacement leaves the last-known-good queue active.
	if next.raw_front_matter != current.raw_front_matter {
		tracker.activate_adapter(next.config.tracker) or {
			return DefinitionReloadDecision{
				definition:    current
				error_message: err.msg()
			}
		}
	}
	return DefinitionReloadDecision{
		definition: next
	}
}

fn poll_and_dispatch(definition workflow.WorkflowDefinition, runtime Runtime, events chan WorkerEvent, mut cancellations map[string]chan bool, mut remove_after_finish map[string]bool) ! {
	config := definition.config
	if !runtime.reconfigure(config.agent.max_concurrent_agents, config.agent.max_retry_backoff_ms) {
		return error('orchestrator_config_error: runtime rejected the reloaded limits')
	}
	client := tracker.new_adapter(config.tracker)!
	policy := scheduling_policy(config)
	reconcile_running(definition, runtime, client, policy, mut cancellations, mut
		remove_after_finish)!
	reconcile_blocked(definition, runtime, client, policy)!
	activate_due_retries(definition, runtime, client, policy, events, mut cancellations)!
	dispatch_candidates(definition, runtime, client, policy, events, mut cancellations)!
}

fn reconcile_blocked(definition workflow.WorkflowDefinition, runtime Runtime, client tracker.Tracker, policy scheduler.Policy) ! {
	snapshot := runtime.snapshot(time.now().unix_milli())
	if snapshot.blocked.len == 0 {
		return
	}
	refreshed := client.fetch_issues_by_ids(snapshot.blocked.map(it.issue_id))!
	mut by_id := map[string]domain.Issue{}
	for issue in refreshed {
		by_id[issue.id] = issue
	}
	for blocked in snapshot.blocked {
		issue := by_id[blocked.issue_id] or {
			runtime.release(blocked.issue_id)
			continue
		}
		if policy.is_terminal(issue.state) {
			remove_issue_workspace(definition, issue) or {
				emit(definition, 'warn', 'workspace_cleanup_failed', issue, blocked.attempt,
					err.msg())
			}
			runtime.release(issue.id)
			continue
		}
		if !policy.is_active(issue.state) || !scheduler.is_routable(issue, policy)
			|| (issue.updated_at != '' && issue.updated_at != blocked.updated_at) {
			runtime.release(issue.id)
		}
	}
}

fn cleanup_terminal_workspaces(definition workflow.WorkflowDefinition) ! {
	client := tracker.new_adapter(definition.config.tracker)!
	issues := client.fetch_issues_by_states(definition.config.tracker.terminal_states)!
	for issue in issues {
		remove_issue_workspace(definition, issue) or {
			emit(definition, 'warn', 'workspace_cleanup_failed', issue, 0, err.msg())
		}
	}
}

fn reconcile_running(definition workflow.WorkflowDefinition, runtime Runtime, client tracker.Tracker, policy scheduler.Policy, mut cancellations map[string]chan bool, mut remove_after_finish map[string]bool) ! {
	snapshot := runtime.snapshot(time.now().unix_milli())
	if snapshot.running.len == 0 {
		return
	}
	ids := snapshot.running.map(it.issue_id)
	refreshed := client.fetch_issues_by_ids(ids)!
	mut by_id := map[string]domain.Issue{}
	for issue in refreshed {
		by_id[issue.id] = issue
	}
	for running in snapshot.running {
		issue := by_id[running.issue_id] or {
			request_cancel(cancellations[running.issue_id] or { continue })
			continue
		}
		match scheduler.reconciliation_action(true, issue, policy) {
			.update_active {
				runtime.update_issue(issue)
			}
			.cancel_preserve {
				request_cancel(cancellations[running.issue_id] or { continue })
			}
			.cancel_remove {
				remove_after_finish[running.issue_id] = true
				request_cancel(cancellations[running.issue_id] or { continue })
			}
		}
	}
	_ = definition
}

fn activate_due_retries(definition workflow.WorkflowDefinition, runtime Runtime, client tracker.Tracker, policy scheduler.Policy, events chan WorkerEvent, mut cancellations map[string]chan bool) ! {
	now_ms := time.now().unix_milli()
	snapshot := runtime.snapshot(now_ms)
	due := snapshot.retrying.filter(it.due_at_ms <= now_ms)
	if due.len == 0 {
		return
	}
	refreshed := client.fetch_issues_by_ids(due.map(it.issue_id))!
	mut by_id := map[string]domain.Issue{}
	for issue in refreshed {
		by_id[issue.id] = issue
	}
	for retry in due {
		issue := by_id[retry.issue_id] or {
			runtime.release(retry.issue_id)
			continue
		}
		if !scheduler.is_eligible(issue, policy, map[string]bool{}) {
			if policy.is_terminal(issue.state) {
				remove_issue_workspace(definition, issue) or {
					emit(definition, 'warn', 'workspace_cleanup_failed', issue, retry.attempt,
						err.msg())
				}
			}
			runtime.release(issue.id)
			continue
		}
		current := runtime.snapshot(now_ms)
		if scheduler.available_slots(definition.config.agent.max_concurrent_agents,
			current.running, issue.state, definition.config.agent.max_concurrent_agents_by_state) <= 0 {
			runtime.defer_retry(issue.id, now_ms + scheduler.continuation_delay_ms(),
				'no available orchestrator slots')
			continue
		}
		runtime.update_issue(issue)
		attempt := runtime.activate_retry(issue.id, now_ms) or { continue }
		spawn_worker(definition, runtime, attempt.issue, attempt.attempt, events, mut cancellations)
	}
}

fn dispatch_candidates(definition workflow.WorkflowDefinition, runtime Runtime, client tracker.Tracker, policy scheduler.Policy, events chan WorkerEvent, mut cancellations map[string]chan bool) ! {
	candidates :=
		scheduler.sort_candidates(client.fetch_issues_by_states(definition.config.tracker.active_states)!)
	for issue in candidates {
		now_ms := time.now().unix_milli()
		snapshot := runtime.snapshot(now_ms)
		mut claimed := map[string]bool{}
		for running in snapshot.running {
			claimed[running.issue_id] = true
		}
		for retry in snapshot.retrying {
			claimed[retry.issue_id] = true
		}
		for blocked in snapshot.blocked {
			claimed[blocked.issue_id] = true
		}
		if !scheduler.is_eligible(issue, policy, claimed) {
			continue
		}
		if scheduler.available_slots(definition.config.agent.max_concurrent_agents,
			snapshot.running, issue.state, definition.config.agent.max_concurrent_agents_by_state) <= 0 {
			continue
		}
		if runtime.claim(issue, 0, now_ms) {
			spawn_worker(definition, runtime, issue, 0, events, mut cancellations)
		}
	}
}

fn spawn_worker(definition workflow.WorkflowDefinition, runtime Runtime, issue domain.Issue, attempt int, events chan WorkerEvent, mut cancellations map[string]chan bool) {
	cancel := chan bool{cap: 1}
	cancellations[issue.id] = cancel
	spawn run_worker(definition, runtime, issue, attempt, events, cancel)
}

fn run_worker(definition workflow.WorkflowDefinition, runtime Runtime, issue domain.Issue, attempt int, events chan WorkerEvent, cancel chan bool) {
	started := time.now()
	tracker_secret_names := secret_environment_names(definition.config) or {
		send_failure(definition, events, issue, attempt, started, err.msg())
		return
	}
	prepared := prepare_worker_workspace(definition, issue, tracker_secret_names, cancel) or {
		send_failure(definition, events, issue, attempt, started, err.msg())
		return
	}
	space := prepared.space
	prepared_branch := prepared.branch
	prompt_attempt := if attempt == 0 { -1 } else { attempt }
	rendered := prompt.render(definition.prompt_template, issue, prompt_attempt) or {
		workspace.run_after_sanitized(space, definition.config.hooks, tracker_secret_names)
		send_failure(definition, events, issue, attempt, started, err.msg())
		return
	}
	workspace_prompt := prepend_workspace_git_policy(rendered, prepared_branch,
		definition.config.workspace.base_branch)
	result := codex.run_session_observed(codex.ClientConfig{
		command:                  definition.config.codex.command
		cwd:                      space.path
		approval_policy:          definition.config.codex.approval_policy
		thread_sandbox:           definition.config.codex.thread_sandbox
		turn_sandbox_policy:      definition.config.codex.turn_sandbox_policy
		read_timeout_ms:          definition.config.codex.read_timeout_ms
		turn_timeout_ms:          definition.config.codex.turn_timeout_ms
		stall_timeout_ms:         definition.config.codex.stall_timeout_ms
		secret_environment_names: tracker_secret_names
	}, workspace_prompt, codex.SessionPolicy{
		max_turns:           definition.config.agent.max_turns
		continuation_prompt: 'Continue working on the same issue in this existing thread. Re-check the task state, complete the remaining work, and run the relevant verification.'
	}, cancel, fn [definition, issue] (_ int) bool {
		return issue_still_active_and_routable(definition, issue)
	}, fn [definition, runtime, issue, attempt] (update domain.SessionUpdate) {
		runtime.update_session(domain.SessionUpdate{
			...update
			issue_id: issue.id
		})
		emit_session(definition, update.event, issue, attempt, update)
	}) or {
		workspace.run_after_sanitized(space, definition.config.hooks, tracker_secret_names)
		send_failure(definition, events, issue, attempt, started, err.msg())
		return
	}
	warnings := workspace.run_after_sanitized(space, definition.config.hooks, tracker_secret_names)
	mut message := result.error_message
	if warnings.len > 0 {
		message = [message, warnings.join('; ')].filter(it != '').join('; ')
	}
	events <- WorkerEvent{
		definition: definition
		issue:      issue
		outcome:    domain.AttemptOutcome{
			kind:              result.outcome
			issue_id:          issue.id
			attempt:           attempt
			error_message:     bounded_message(message)
			runtime_seconds:   time.since(started).seconds()
			tokens:            result.tokens
			rate_used_percent: result.rate_used_percent
			rate_resets_at:    result.rate_resets_at
		}
	}
}

struct PreparedWorkerWorkspace {
	space  workspace.Workspace
	branch string
}

fn prepare_worker_workspace(definition workflow.WorkflowDefinition, issue domain.Issue, tracker_secret_names []string, cancel chan bool) !PreparedWorkerWorkspace {
	space := workspace.prepare_cancelable_sanitized(definition.config.workspace.root,
		issue.identifier, definition.config.hooks, tracker_secret_names, cancel)!
	workspace.prepare_issue_branch_cancelable_sanitized(space, issue, definition.config.workspace,
		tracker_secret_names, cancel) or {
		workspace.run_after_sanitized(space, definition.config.hooks, tracker_secret_names)
		return err
	}
	workspace.run_before_cancelable_sanitized(space, definition.config.hooks, tracker_secret_names,
		cancel) or {
		workspace.run_after_sanitized(space, definition.config.hooks, tracker_secret_names)
		return err
	}
	branch := workspace.prepare_issue_branch_cancelable_sanitized(space, issue,
		definition.config.workspace, tracker_secret_names, cancel) or {
		workspace.run_after_sanitized(space, definition.config.hooks, tracker_secret_names)
		return err
	}
	return PreparedWorkerWorkspace{
		space:  space
		branch: branch
	}
}

fn prepend_workspace_git_policy(rendered string, branch string, base_branch string) string {
	if branch == '' {
		return rendered
	}
	return 'Git workspace policy:\n- Work only on the prepared issue branch `${branch}`.\n- Do not switch to, commit on, or push the protected base branch `${base_branch}`, `main`, or `master`.\n- Do not push any branch unless the issue or workflow explicitly requires it.\n\n${rendered}'
}

fn emit_session(definition workflow.WorkflowDefinition, event string, issue domain.Issue, attempt int, update domain.SessionUpdate) {
	client := tracker.new_adapter(definition.config.tracker) or { return }
	observability.emit(observability.Record{
		level:            'info'
		event:            event
		issue_id:         issue.id
		issue_identifier: issue.identifier
		attempt:          attempt
		session_id:       update.thread_id
		thread_id:        update.thread_id
		turn_id:          update.turn_id
		message:          bounded_message(update.message)
	}, client.secret_values())
}

fn issue_still_active_and_routable(definition workflow.WorkflowDefinition, issue domain.Issue) bool {
	client := tracker.new_adapter(definition.config.tracker) or { return false }
	refreshed := client.fetch_issues_by_ids([issue.id]) or { return false }
	if refreshed.len != 1 {
		return false
	}
	policy := scheduling_policy(definition.config)
	return policy.is_active(refreshed[0].state) && scheduler.is_routable(refreshed[0], policy)
}

fn send_failure(definition workflow.WorkflowDefinition, events chan WorkerEvent, issue domain.Issue, attempt int, started time.Time, message string) {
	kind := failure_outcome_kind(message)
	events <- WorkerEvent{
		definition: definition
		issue:      issue
		outcome:    domain.AttemptOutcome{
			kind:            kind
			issue_id:        issue.id
			attempt:         attempt
			error_message:   bounded_message(message)
			runtime_seconds: time.since(started).seconds()
		}
	}
}

fn failure_outcome_kind(message string) domain.AttemptOutcomeKind {
	if message.contains('hook_canceled') || message.contains('workspace_git_canceled') {
		return .canceled
	}
	return .failed
}

fn handle_worker_event(runtime Runtime, event WorkerEvent, mut cancellations map[string]chan bool, mut remove_after_finish map[string]bool) {
	definition := event.definition
	cancellations.delete(event.issue.id)
	completion_persisted := persist_tracker_outcome(definition, event)
	runtime.finish(event.outcome, time.now().unix_milli())
	if completion_persisted && event.outcome.kind == .succeeded {
		runtime.release(event.issue.id)
	}
	if remove_after_finish[event.issue.id] {
		remove_issue_workspace(definition, event.issue) or {
			emit(definition, 'warn', 'workspace_cleanup_failed', event.issue,
				event.outcome.attempt, err.msg())
		}
		remove_after_finish.delete(event.issue.id)
		runtime.release(event.issue.id)
	}
	level := if event.outcome.kind in [.succeeded, .canceled] { 'info' } else { 'error' }
	emit(definition, level, 'attempt_finished', event.issue, event.outcome.attempt,
		event.outcome.error_message)
}

fn persist_tracker_outcome(definition workflow.WorkflowDefinition, event WorkerEvent) bool {
	client := tracker.new_adapter(definition.config.tracker) or {
		emit(definition, 'error', 'tracker_outcome_persist_failed', event.issue,
			event.outcome.attempt, err.msg())
		return false
	}
	return client.record_outcome(event.issue, event.outcome) or {
		emit(definition, 'error', 'tracker_outcome_persist_failed', event.issue,
			event.outcome.attempt, err.msg())
		false
	}
}

fn cancel_all(cancellations map[string]chan bool) {
	for _, cancel in cancellations {
		request_cancel(cancel)
	}
}

fn drain_workers(runtime Runtime, events chan WorkerEvent, mut cancellations map[string]chan bool, mut remove_after_finish map[string]bool) {
	deadline := time.now().add(shutdown_timeout)
	for cancellations.len > 0 && time.now() < deadline {
		select {
			event := <-events {
				handle_worker_event(runtime, event, mut cancellations, mut remove_after_finish)
			}
			service_tick {}
		}
	}
	for issue_id, _ in cancellations {
		runtime.release(issue_id)
	}
}

fn request_cancel(cancel chan bool) {
	select {
		cancel <- true {}
		else {}
	}
}

fn remove_issue_workspace(definition workflow.WorkflowDefinition, issue domain.Issue) ! {
	path := workspace.path_for(definition.config.workspace.root, issue.identifier)!
	warnings := workspace.remove_sanitized(workspace.Workspace{
		root: definition.config.workspace.root
		path: path
		key:  workspace.workspace_key(issue.identifier)
	}, definition.config.hooks, secret_environment_names(definition.config)!)!
	for warning in warnings {
		emit(definition, 'warn', 'workspace_cleanup_hook_failed', issue, 0, warning)
	}
}

fn scheduling_policy(config workflow.Config) scheduler.Policy {
	return scheduler.Policy{
		active_states:   config.tracker.active_states
		terminal_states: config.tracker.terminal_states
		required_labels: config.tracker.required_labels
	}
}

fn secret_environment_names(config workflow.Config) ![]string {
	client := tracker.new_adapter(config.tracker)!
	return client.secret_environment_names()
}

fn emit(definition workflow.WorkflowDefinition, level string, event string, issue domain.Issue, attempt int, message string) {
	client := tracker.new_adapter(definition.config.tracker) or {
		observability.emit(observability.Record{
			level:            level
			event:            event
			issue_id:         issue.id
			issue_identifier: issue.identifier
			attempt:          attempt
			message:          bounded_message(message)
		}, []string{})
		return
	}
	observability.emit(observability.Record{
		level:            level
		event:            event
		issue_id:         issue.id
		issue_identifier: issue.identifier
		attempt:          attempt
		message:          bounded_message(message)
	}, client.secret_values())
}

fn bounded_message(value string) string {
	return if value.len <= service_message_limit { value } else { value[..service_message_limit] }
}
