module scheduler

import symphony.domain

pub struct Policy {
pub:
	active_states   []string
	terminal_states []string
	required_labels []string
}

pub enum ReconciliationAction {
	update_active
	cancel_preserve
	cancel_remove
}

pub fn (policy Policy) is_active(state string) bool {
	normalized := domain.normalize_name(state)
	return normalized in policy.active_states.map(domain.normalize_name(it))
}

pub fn (policy Policy) is_terminal(state string) bool {
	normalized := domain.normalize_name(state)
	return normalized in policy.terminal_states.map(domain.normalize_name(it))
}

pub fn is_eligible(issue domain.Issue, policy Policy, claimed map[string]bool) bool {
	if issue.id.trim_space() == '' || issue.identifier.trim_space() == ''
		|| issue.title.trim_space() == '' || issue.state.trim_space() == '' {
		return false
	}
	if claimed[issue.id] || !issue.dispatchable || !policy.is_active(issue.state)
		|| policy.is_terminal(issue.state) {
		return false
	}
	if !issue.has_required_labels(policy.required_labels) {
		return false
	}
	return true
}

pub fn is_routable(issue domain.Issue, policy Policy) bool {
	return issue.dispatchable && issue.has_required_labels(policy.required_labels)
}

fn compare_issues(left &domain.Issue, right &domain.Issue) int {
	left_ranked := left.queue_rank >= 0
	right_ranked := right.queue_rank >= 0
	if left_ranked != right_ranked {
		return if left_ranked { -1 } else { 1 }
	}
	if left_ranked && left.queue_rank != right.queue_rank {
		return if left.queue_rank < right.queue_rank { -1 } else { 1 }
	}
	left_unknown := left.priority < 1 || left.priority > 4
	right_unknown := right.priority < 1 || right.priority > 4
	if left_unknown != right_unknown {
		return if left_unknown { 1 } else { -1 }
	}
	if !left_unknown && left.priority != right.priority {
		return if left.priority < right.priority { -1 } else { 1 }
	}
	if left.created_at != right.created_at {
		if left.created_at == '' {
			return 1
		}
		if right.created_at == '' {
			return -1
		}
		return if left.created_at < right.created_at { -1 } else { 1 }
	}
	if left.identifier == right.identifier {
		return 0
	}
	return if left.identifier < right.identifier { -1 } else { 1 }
}

pub fn sort_candidates(issues []domain.Issue) []domain.Issue {
	mut sorted := issues.clone()
	sorted.sort_with_compare(compare_issues)
	return sorted
}

pub fn available_slots(max_global int, running []domain.RunningSnapshot, state string, state_limits map[string]int) int {
	global_available := max_int(max_global - running.len, 0)
	state_key := domain.normalize_name(state)
	state_limit := state_limits[state_key] or { max_global }
	mut state_count := 0
	for entry in running {
		if domain.normalize_name(entry.state) == state_key {
			state_count++
		}
	}
	state_available := max_int(state_limit - state_count, 0)
	return min_int(global_available, state_available)
}

pub fn continuation_delay_ms() i64 {
	return 1_000
}

pub fn failure_retry_delay_ms(attempt int, max_backoff_ms int) i64 {
	cap := i64(max_int(max_backoff_ms, 0))
	if cap == 0 {
		return 0
	}
	mut delay := i64(10_000)
	mut remaining := max_int(attempt, 1) - 1
	for remaining > 0 && delay < cap {
		if delay > cap / 2 {
			delay = cap
			break
		}
		delay *= 2
		remaining--
	}
	return if delay > cap { cap } else { delay }
}

pub fn is_stalled(started_at_ms i64, last_activity_ms i64, now_ms i64, timeout_ms int) bool {
	if timeout_ms <= 0 {
		return false
	}
	basis := if last_activity_ms > 0 { last_activity_ms } else { started_at_ms }
	return now_ms - basis > i64(timeout_ms)
}

pub fn reconciliation_action(found bool, refreshed domain.Issue, policy Policy) ReconciliationAction {
	if !found {
		return .cancel_preserve
	}
	if policy.is_terminal(refreshed.state) {
		return .cancel_remove
	}
	if policy.is_active(refreshed.state) {
		return if is_routable(refreshed, policy) { .update_active } else { .cancel_preserve }
	}
	return .cancel_preserve
}

fn max_int(left int, right int) int {
	return if left > right { left } else { right }
}

fn min_int(left int, right int) int {
	return if left < right { left } else { right }
}
