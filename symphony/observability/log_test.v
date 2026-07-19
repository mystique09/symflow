module observability

fn test_render_redacts_secrets_and_keeps_stable_correlation_fields() {
	line := render(Record{
		timestamp:        '2026-07-18T00:00:00Z'
		level:            'info'
		event:            'attempt_finished'
		issue_id:         'issue-1'
		issue_identifier: 'SYM-1'
		attempt:          2
		session_id:       'thread-1'
		thread_id:        'thread-1'
		turn_id:          'turn-2'
		message:          'request used secret-token'
	}, ['secret-token'])
	assert line.contains('"event":"attempt_finished"')
	assert line.contains('"issue_id":"issue-1"')
	assert line.contains('"issue_identifier":"SYM-1"')
	assert line.contains('"attempt":2')
	assert line.contains('"session_id":"thread-1"')
	assert line.contains('"turn_id":"turn-2"')
	assert line.contains('[REDACTED]')
	assert !line.contains('secret-token')
}

fn test_render_ignores_blank_secrets() {
	line := render(Record{
		event:   'workflow_loaded'
		message: 'ordinary message'
	}, ['', '   '])
	assert line.contains('ordinary message')
}
