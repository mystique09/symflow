module orchestrator

import symphony.domain

fn orchestration_issue() domain.Issue {
	return domain.Issue{
		id:         '1'
		identifier: 'OPS-1'
		title:      'Do work'
		state:      'Todo'
		labels:     ['backend']
		updated_at: '2026-07-18T00:00:00Z'
	}
}

fn test_state_claims_once_and_exposes_snapshot_copy() {
	mut state := new_state(2, 300_000)
	state.claim(orchestration_issue(), 0, 1_000) or { panic(err) }
	state.claim(orchestration_issue(), 0, 1_001) or {
		assert err.msg().contains('already claimed')
		snapshot := state.snapshot(2_000)
		assert snapshot.running.len == 1
		assert snapshot.running[0].issue_identifier == 'OPS-1'
		return
	}
	assert false, 'duplicate claim should fail'
}

fn test_success_schedules_short_continuation_and_failure_backs_off() {
	mut success := new_state(2, 300_000)
	success.claim(orchestration_issue(), 0, 1_000) or { panic(err) }
	success.finish(domain.AttemptOutcome{
		kind:              .succeeded
		issue_id:          '1'
		attempt:           0
		tokens:            domain.TokenTotals{
			total: 5
		}
		rate_used_percent: 25
		rate_resets_at:    123
	}, 2_000)
	success_snapshot := success.snapshot(2_000)
	assert success_snapshot.running.len == 0
	assert success_snapshot.retrying[0].attempt == 1
	assert success_snapshot.retrying[0].due_at_ms == 3_000
	assert success_snapshot.rate_limit.used_percent == 25
	assert success_snapshot.rate_limit.resets_at == 123

	mut failed := new_state(2, 300_000)
	failed.claim(orchestration_issue(), 1, 1_000) or { panic(err) }
	failed.finish(domain.AttemptOutcome{
		kind:          .failed
		issue_id:      '1'
		attempt:       1
		error_message: 'boom'
	}, 2_000)
	failed_snapshot := failed.snapshot(2_000)
	assert failed_snapshot.retrying[0].attempt == 2
	assert failed_snapshot.retrying[0].due_at_ms == 22_000
}

fn test_blocked_is_visible_and_terminal_release_clears_claim() {
	mut state := new_state(1, 300_000)
	state.claim(orchestration_issue(), 0, 1_000) or { panic(err) }
	state.finish(domain.AttemptOutcome{
		kind:          .blocked
		issue_id:      '1'
		error_message: 'input required'
	}, 2_000)
	assert state.snapshot(2_000).blocked.len == 1
	assert state.snapshot(2_000).blocked[0].updated_at == '2026-07-18T00:00:00Z'
	assert state.release_blocked() == 1
	assert state.snapshot(2_001).blocked.len == 0
	state.claim(orchestration_issue(), 0, 2_100)!
	state.finish(domain.AttemptOutcome{
		kind:     .blocked
		issue_id: '1'
	}, 2_200)
	state.release('1')
	assert state.snapshot(3_000).blocked.len == 0
	state.claim(orchestration_issue(), 0, 3_000) or { panic(err) }
}

fn test_due_retry_reenters_running_without_releasing_claim() {
	mut state := new_state(1, 300_000)
	state.claim(orchestration_issue(), 0, 1_000)!
	state.finish(domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: '1'
		attempt:  0
	}, 2_000)
	state.activate_retry('1', 2_999) or {
		assert err.msg().contains('not due')
		attempt := state.activate_retry('1', 3_000)!
		assert attempt.issue.identifier == 'OPS-1'
		assert attempt.attempt == 1
		assert state.snapshot(3_000).running.len == 1
		return
	}
	assert false
}

fn test_slot_exhaustion_can_defer_retry_with_an_explicit_reason() {
	mut state := new_state(1, 300_000)
	state.claim(orchestration_issue(), 0, 1_000)!
	state.finish(domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: '1'
	}, 2_000)
	state.defer_retry('1', 4_000, 'no available orchestrator slots')!
	retry := state.snapshot(3_000).retrying[0]
	assert retry.due_at_ms == 4_000
	assert retry.error_message == 'no available orchestrator slots'
}

fn test_update_issue_refreshes_running_state() {
	mut state := new_state(1, 300_000)
	state.claim(orchestration_issue(), 0, 1_000)!
	state.update_issue(domain.Issue{
		...orchestration_issue()
		state: 'In Progress'
	})!
	assert state.snapshot(2_000).running[0].state == 'In Progress'
}

fn test_live_session_updates_use_absolute_token_deltas_and_active_runtime() {
	mut state := new_state(1, 300_000)
	state.claim(orchestration_issue(), 0, 1_000)!
	state.update_session(domain.SessionUpdate{
		issue_id:     '1'
		event:        'turn_started'
		timestamp_ms: 1_500
		pid:          4321
		thread_id:    'thread-1'
		turn_id:      'turn-1'
		message:      'working'
		turn_count:   1
		tokens:       domain.TokenTotals{
			input:  2
			output: 3
			total:  5
		}
	})!
	state.update_session(domain.SessionUpdate{
		issue_id:     '1'
		event:        'token_usage'
		timestamp_ms: 1_750
		tokens:       domain.TokenTotals{
			input:  3
			output: 5
			total:  8
		}
	})!
	snapshot := state.snapshot(2_000)
	assert snapshot.tokens.total == 8
	assert snapshot.runtime_secs == 1.0
	assert snapshot.running[0].pid == 4321
	assert snapshot.running[0].thread_id == 'thread-1'
	assert snapshot.running[0].turn_id == 'turn-1'
	assert snapshot.running[0].last_event == 'token_usage'
	assert snapshot.running[0].last_message == 'working'
	assert snapshot.running[0].turn_count == 1
	assert snapshot.running[0].tokens.total == 8

	state.finish(domain.AttemptOutcome{
		kind:     .canceled
		issue_id: '1'
		tokens:   domain.TokenTotals{
			input:  3
			output: 5
			total:  8
		}
	}, 2_100)
	assert state.snapshot(2_100).tokens.total == 8
}

fn test_reconfigure_applies_new_capacity_and_retry_backoff() {
	mut state := new_state(1, 300_000)
	state.reconfigure(2, 10_000)!
	state.claim(orchestration_issue(), 0, 1_000)!
	state.claim(domain.Issue{
		...orchestration_issue()
		id:         '2'
		identifier: 'OPS-2'
	}, 0, 1_001)!
	assert state.snapshot(1_100).running.len == 2
}

fn test_runtime_loop_serializes_commands() {
	runtime := start_runtime(2, 300_000)
	defer {
		runtime.shutdown()
	}
	assert runtime.claim(orchestration_issue(), 0, 1_000)
	assert !runtime.claim(orchestration_issue(), 0, 1_001)
	assert runtime.snapshot(2_000).running.len == 1
}
