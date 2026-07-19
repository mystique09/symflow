module scheduler

import symphony.domain

fn scheduler_policy() Policy {
	return Policy{
		active_states:   ['Todo', 'In Progress']
		terminal_states: ['Done', 'Cancelled']
		required_labels: ['backend']
	}
}

fn scheduler_issue(id string, state string, priority int, created_at string) domain.Issue {
	return domain.Issue{
		id:           id
		identifier:   'OPS-${id}'
		title:        'Issue ${id}'
		state:        state
		priority:     priority
		created_at:   created_at
		labels:       ['Backend']
		dispatchable: true
	}
}

fn test_candidate_eligibility_uses_explicit_adapter_dispatchability() {
	policy := scheduler_policy()
	issue := scheduler_issue('1', 'Todo', 1, '2026-01-01T00:00:00Z')
	assert is_eligible(issue, policy, map[string]bool{})
	assert !is_eligible(issue, policy, {
		'1': true
	})
	assert !is_eligible(domain.Issue{
		...issue
		dispatchable: false
	}, policy, map[string]bool{})
	assert !is_eligible(domain.Issue{
		...issue
		labels: ['frontend']
	}, policy, map[string]bool{})
	assert is_eligible(domain.Issue{
		...issue
		blocked_by: [domain.BlockerRef{ identifier: 'OPS-9', state: 'In Progress' }]
	}, policy, map[string]bool{})
}

fn test_candidate_sort_is_priority_then_creation_then_identifier() {
	issues := [
		scheduler_issue('5', 'Todo', 0, '2024-01-01T00:00:00Z'),
		scheduler_issue('4', 'Todo', -1, '2025-01-01T00:00:00Z'),
		scheduler_issue('3', 'Todo', 2, '2026-01-01T00:00:00Z'),
		scheduler_issue('2', 'Todo', 1, '2026-02-01T00:00:00Z'),
		scheduler_issue('1', 'Todo', 1, '2026-01-01T00:00:00Z'),
	]
	sorted := sort_candidates(issues)
	assert sorted.map(it.id) == ['1', '2', '3', '5', '4']
}

fn test_available_slots_honors_global_and_per_state_limits() {
	running := [
		domain.RunningSnapshot{
			issue_id: '1'
			state:    'Todo'
		},
		domain.RunningSnapshot{
			issue_id: '2'
			state:    'In Progress'
		},
	]
	assert available_slots(4, running, 'Todo', {
		'todo': 1
	}) == 0
	assert available_slots(4, running, 'In Progress', {
		'in progress': 3
	}) == 2
	assert available_slots(1, running, 'Todo', map[string]int{}) == 0
}

fn test_retry_delay_is_capped_and_continuation_is_short() {
	assert failure_retry_delay_ms(1, 300_000) == 10_000
	assert failure_retry_delay_ms(2, 300_000) == 20_000
	assert failure_retry_delay_ms(10, 300_000) == 300_000
	assert continuation_delay_ms() == 1_000
}

fn test_stall_detection_uses_last_activity_or_start() {
	assert is_stalled(1_000, 0, 6_001, 5_000)
	assert !is_stalled(1_000, 4_000, 6_001, 5_000)
	assert !is_stalled(1_000, 0, 99_000, 0)
}

fn test_reconciliation_actions_are_explicit() {
	policy := scheduler_policy()
	assert reconciliation_action(false, domain.Issue{}, policy) == .cancel_preserve
	assert reconciliation_action(true, scheduler_issue('1', 'Done', 1, ''), policy) == .cancel_remove
	assert reconciliation_action(true, scheduler_issue('1', 'Paused', 1, ''), policy) == .cancel_preserve
	assert reconciliation_action(true, scheduler_issue('1', 'In Progress', 1, ''), policy) == .update_active
	assert reconciliation_action(true, domain.Issue{
		...scheduler_issue('1', 'In Progress', 1, '')
		dispatchable: false
	}, policy) == .cancel_preserve
	assert reconciliation_action(true, domain.Issue{
		...scheduler_issue('1', 'In Progress', 1, '')
		labels: ['frontend']
	}, policy) == .cancel_preserve
}
