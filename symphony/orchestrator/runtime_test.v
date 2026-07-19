module orchestrator

import symphony.domain

fn runtime_test_issue() domain.Issue {
	return domain.Issue{
		id:         'issue-runtime'
		identifier: 'SYM-42'
		title:      'Exercise the runtime'
		state:      'Todo'
	}
}

fn test_runtime_serializes_claim_finish_snapshot_and_release() {
	runtime := start_runtime(1, 60_000)
	issue := runtime_test_issue()
	assert runtime.claim(issue, 1, 1_000)
	assert !runtime.claim(issue, 1, 1_001)
	runtime.finish(domain.AttemptOutcome{
		kind:     .failed
		issue_id: issue.id
		attempt:  1
		tokens:   domain.TokenTotals{
			input:  2
			output: 3
			total:  5
		}
	}, 2_000)
	snapshot := runtime.snapshot(2_001)
	assert snapshot.running.len == 0
	assert snapshot.retrying.len == 1
	assert snapshot.tokens.total == 5
	attempt := runtime.activate_retry(issue.id, snapshot.retrying[0].due_at_ms)!
	assert attempt.attempt == 2
	runtime.finish(domain.AttemptOutcome{
		kind:     .canceled
		issue_id: issue.id
		attempt:  2
	}, 30_000)
	runtime.release(issue.id)
	assert runtime.snapshot(2_002).retrying.len == 0
	assert runtime.release_blocked() == 0
	runtime.shutdown()
}

fn test_runtime_serializes_session_updates_and_reconfiguration() {
	runtime := start_runtime(1, 60_000)
	defer {
		runtime.shutdown()
	}
	assert runtime.reconfigure(2, 30_000)
	assert runtime.claim(runtime_test_issue(), 0, 1_000)
	assert runtime.update_session(domain.SessionUpdate{
		issue_id:     'issue-runtime'
		event:        'process_started'
		timestamp_ms: 1_100
		pid:          99
	})
	assert runtime.snapshot(1_200).running[0].pid == 99
}

fn test_runtime_serializes_retry_deferral() {
	runtime := start_runtime(1, 60_000)
	defer {
		runtime.shutdown()
	}
	issue := runtime_test_issue()
	assert runtime.claim(issue, 0, 1_000)
	runtime.finish(domain.AttemptOutcome{
		kind:     .succeeded
		issue_id: issue.id
	}, 2_000)
	assert runtime.defer_retry(issue.id, 5_000, 'no available orchestrator slots')
	assert runtime.snapshot(3_000).retrying[0].error_message == 'no available orchestrator slots'
}
