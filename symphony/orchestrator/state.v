module orchestrator

import symphony.domain
import symphony.scheduler

struct RunningEntry {
	issue            domain.Issue
	attempt          int
	started_at_ms    i64
	last_activity_ms i64
	pid              int
	thread_id        string
	turn_id          string
	last_event       string
	last_message     string
	turn_count       int
	tokens           domain.TokenTotals
	rate_limit       domain.RateLimitSnapshot
}

struct RetryEntry {
	issue         domain.Issue
	attempt       int
	due_at_ms     i64
	error_message string
}

struct BlockedEntry {
	issue   domain.Issue
	attempt int
	reason  string
}

pub struct Attempt {
pub:
	issue   domain.Issue
	attempt int
}

pub struct State {
mut:
	max_concurrent  int
	max_backoff_ms  int
	running         map[string]RunningEntry
	claimed         map[string]bool
	retries         map[string]RetryEntry
	blocked         map[string]BlockedEntry
	tokens          domain.TokenTotals
	rate_limit      domain.RateLimitSnapshot
	runtime_seconds f64
}

pub fn (mut state State) reconfigure(max_concurrent int, max_backoff_ms int) ! {
	if max_concurrent <= 0 || max_backoff_ms <= 0 {
		return error('orchestrator_config_error: capacity and retry backoff must be positive')
	}
	state.max_concurrent = max_concurrent
	state.max_backoff_ms = max_backoff_ms
}

pub fn new_state(max_concurrent int, max_backoff_ms int) State {
	return State{
		max_concurrent: max_concurrent
		max_backoff_ms: max_backoff_ms
		running:        map[string]RunningEntry{}
		claimed:        map[string]bool{}
		retries:        map[string]RetryEntry{}
		blocked:        map[string]BlockedEntry{}
	}
}

pub fn (mut state State) claim(issue domain.Issue, attempt int, now_ms i64) ! {
	if state.claimed[issue.id] || issue.id in state.running || issue.id in state.retries
		|| issue.id in state.blocked {
		return error('orchestrator_claim_error: issue is already claimed')
	}
	if state.running.len >= state.max_concurrent {
		return error('orchestrator_capacity_error: no global slot is available')
	}
	state.claimed[issue.id] = true
	state.running[issue.id] = RunningEntry{
		issue:            issue
		attempt:          attempt
		started_at_ms:    now_ms
		last_activity_ms: now_ms
	}
}

pub fn (mut state State) finish(outcome domain.AttemptOutcome, now_ms i64) {
	entry := state.running[outcome.issue_id] or {
		state.release(outcome.issue_id)
		return
	}
	state.running.delete(outcome.issue_id)
	state.add_token_delta(entry.tokens, outcome.tokens)
	state.runtime_seconds += outcome.runtime_seconds
	if outcome.rate_resets_at > 0 || outcome.rate_used_percent > 0 {
		state.rate_limit = domain.RateLimitSnapshot{
			used_percent: outcome.rate_used_percent
			resets_at:    outcome.rate_resets_at
		}
	}
	match outcome.kind {
		.succeeded {
			state.retries[outcome.issue_id] = RetryEntry{
				issue:     entry.issue
				attempt:   1
				due_at_ms: now_ms + scheduler.continuation_delay_ms()
			}
		}
		.blocked {
			state.blocked[outcome.issue_id] = BlockedEntry{
				issue:   entry.issue
				attempt: outcome.attempt
				reason:  outcome.error_message
			}
		}
		.canceled {
			state.release(outcome.issue_id)
		}
		.failed, .timed_out, .stalled, .process_exited {
			next_attempt := max_int(outcome.attempt + 1, 1)
			state.retries[outcome.issue_id] = RetryEntry{
				issue:         entry.issue
				attempt:       next_attempt
				due_at_ms:     now_ms +
					scheduler.failure_retry_delay_ms(next_attempt, state.max_backoff_ms)
				error_message: outcome.error_message
			}
		}
	}
}

pub fn (mut state State) update_session(update domain.SessionUpdate) ! {
	entry := state.running[update.issue_id] or {
		return error('orchestrator_session_error: issue is not running')
	}
	state.add_token_delta(entry.tokens, update.tokens)
	mut next_tokens := entry.tokens
	if update.tokens.input > next_tokens.input {
		next_tokens = domain.TokenTotals{
			...next_tokens
			input: update.tokens.input
		}
	}
	if update.tokens.output > next_tokens.output {
		next_tokens = domain.TokenTotals{
			...next_tokens
			output: update.tokens.output
		}
	}
	if update.tokens.total > next_tokens.total {
		next_tokens = domain.TokenTotals{
			...next_tokens
			total: update.tokens.total
		}
	}
	mut next_rate := entry.rate_limit
	if update.rate_limit.used_percent > 0 || update.rate_limit.resets_at > 0 {
		next_rate = update.rate_limit
		state.rate_limit = update.rate_limit
	}
	state.running[update.issue_id] = RunningEntry{
		...entry
		last_activity_ms: if update.timestamp_ms > 0 {
			update.timestamp_ms
		} else {
			entry.last_activity_ms
		}
		pid:              if update.pid > 0 { update.pid } else { entry.pid }
		thread_id:        if update.thread_id != '' { update.thread_id } else { entry.thread_id }
		turn_id:          if update.turn_id != '' { update.turn_id } else { entry.turn_id }
		last_event:       if update.event != '' { update.event } else { entry.last_event }
		last_message:     if update.message != '' { update.message } else { entry.last_message }
		turn_count:       if update.turn_count > 0 { update.turn_count } else { entry.turn_count }
		tokens:           next_tokens
		rate_limit:       next_rate
	}
}

fn (mut state State) add_token_delta(previous domain.TokenTotals, current domain.TokenTotals) {
	state.tokens = domain.TokenTotals{
		input:  state.tokens.input + positive_delta(current.input, previous.input)
		output: state.tokens.output + positive_delta(current.output, previous.output)
		total:  state.tokens.total + positive_delta(current.total, previous.total)
	}
}

pub fn (mut state State) release(issue_id string) {
	state.running.delete(issue_id)
	state.retries.delete(issue_id)
	state.blocked.delete(issue_id)
	state.claimed.delete(issue_id)
}

pub fn (mut state State) release_blocked() int {
	ids := state.blocked.keys()
	for issue_id in ids {
		state.release(issue_id)
	}
	return ids.len
}

pub fn (mut state State) defer_retry(issue_id string, due_at_ms i64, reason string) ! {
	entry := state.retries[issue_id] or {
		return error('orchestrator_retry_error: issue has no scheduled retry')
	}
	state.retries[issue_id] = RetryEntry{
		...entry
		due_at_ms:     due_at_ms
		error_message: reason
	}
}

pub fn (mut state State) activate_retry(issue_id string, now_ms i64) !Attempt {
	entry := state.retries[issue_id] or {
		return error('orchestrator_retry_error: issue has no scheduled retry')
	}
	if entry.due_at_ms > now_ms {
		return error('orchestrator_retry_error: retry is not due')
	}
	if state.running.len >= state.max_concurrent {
		return error('orchestrator_capacity_error: no global slot is available')
	}
	state.retries.delete(issue_id)
	state.running[issue_id] = RunningEntry{
		issue:            entry.issue
		attempt:          entry.attempt
		started_at_ms:    now_ms
		last_activity_ms: now_ms
	}
	return Attempt{
		issue:   entry.issue
		attempt: entry.attempt
	}
}

pub fn (mut state State) update_issue(issue domain.Issue) ! {
	if entry := state.running[issue.id] {
		state.running[issue.id] = RunningEntry{
			...entry
			issue: issue
		}
		return
	}
	if entry := state.retries[issue.id] {
		state.retries[issue.id] = RetryEntry{
			...entry
			issue: issue
		}
		return
	}
	if entry := state.blocked[issue.id] {
		state.blocked[issue.id] = BlockedEntry{
			...entry
			issue: issue
		}
		return
	}
	return error('orchestrator_update_error: issue is not claimed')
}

pub fn (state &State) snapshot(now_ms i64) domain.RuntimeSnapshot {
	mut running := []domain.RunningSnapshot{}
	mut active_runtime_seconds := f64(0)
	for _, entry in state.running {
		if now_ms > entry.started_at_ms {
			active_runtime_seconds += f64(now_ms - entry.started_at_ms) / 1_000.0
		}
		running << domain.RunningSnapshot{
			issue_id:         entry.issue.id
			issue_identifier: entry.issue.identifier
			issue_url:        entry.issue.url
			state:            entry.issue.state
			attempt:          entry.attempt
			started_at_ms:    entry.started_at_ms
			last_activity_ms: entry.last_activity_ms
			pid:              entry.pid
			thread_id:        entry.thread_id
			turn_id:          entry.turn_id
			last_event:       entry.last_event
			last_message:     entry.last_message
			turn_count:       entry.turn_count
			tokens:           entry.tokens
			rate_limit:       entry.rate_limit
		}
	}
	running.sort(a.issue_identifier < b.issue_identifier)
	mut retrying := []domain.RetrySnapshot{}
	for _, entry in state.retries {
		retrying << domain.RetrySnapshot{
			issue_id:         entry.issue.id
			issue_identifier: entry.issue.identifier
			issue_url:        entry.issue.url
			attempt:          entry.attempt
			due_at_ms:        entry.due_at_ms
			error_message:    entry.error_message
		}
	}
	retrying.sort(a.issue_identifier < b.issue_identifier)
	mut blocked := []domain.BlockedSnapshot{}
	for _, entry in state.blocked {
		blocked << domain.BlockedSnapshot{
			issue_id:         entry.issue.id
			issue_identifier: entry.issue.identifier
			issue_url:        entry.issue.url
			state:            entry.issue.state
			updated_at:       entry.issue.updated_at
			attempt:          entry.attempt
			reason:           entry.reason
		}
	}
	blocked.sort(a.issue_identifier < b.issue_identifier)
	return domain.RuntimeSnapshot{
		running:      running
		retrying:     retrying
		blocked:      blocked
		tokens:       state.tokens
		rate_limit:   state.rate_limit
		runtime_secs: state.runtime_seconds + active_runtime_seconds
		generated_at: now_ms
	}
}

fn positive_delta(current i64, previous i64) i64 {
	return if current > previous { current - previous } else { i64(0) }
}

fn max_int(left int, right int) int {
	return if left > right { left } else { right }
}
