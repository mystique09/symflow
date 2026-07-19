module domain

import json2

fn test_normalize_labels_trims_lowercases_and_discards_blanks() {
	assert normalize_labels([' Backend ', '', 'URGENT', 'backend']) == ['backend', 'urgent']
}

fn test_issue_preserves_opaque_id_and_normalizes_state() {
	issue := Issue{
		id:           'opaque/ID:42'
		identifier:   'OPS-42'
		title:        'Repair scheduler'
		state:        ' In Progress '
		labels:       [' Runtime ']
		dispatchable: true
		native_ref:   {
			'linear_issue_id': json2.Any('underlying-42')
			'project_number':  json2.Any(42)
		}
	}
	assert issue.id == 'opaque/ID:42'
	assert (issue.native_ref['linear_issue_id'] or { panic('linear_issue_id') }).str() == 'underlying-42'
	assert (issue.native_ref['project_number'] or { panic('project_number') }).int() == 42
	assert issue.dispatchable
	assert issue.normalized_state() == 'in progress'
	assert issue.normalized_labels() == ['runtime']
}

fn test_issue_dispatchability_is_explicit_adapter_output() {
	issue := Issue{
		id:           '1'
		identifier:   'OPS-1'
		title:        'Provider-routed task'
		state:        'Todo'
		dispatchable: false
	}
	assert !issue.dispatchable
}

fn test_issue_requires_every_configured_label() {
	issue := Issue{
		id:         '1'
		identifier: 'OPS-1'
		title:      'Do work'
		state:      'Todo'
		labels:     ['backend', 'Urgent']
	}
	assert issue.has_required_labels([' BACKEND ', 'urgent'])
	assert !issue.has_required_labels(['backend', 'security'])
	assert !issue.has_required_labels([''])
}

fn test_open_blockers_ignore_terminal_states() {
	issue := Issue{
		id:         '1'
		identifier: 'OPS-1'
		title:      'Do work'
		state:      'Todo'
		blocked_by: [
			BlockerRef{
				identifier: 'OPS-2'
				state:      'Done'
			},
			BlockerRef{
				identifier: 'OPS-3'
				state:      'In Progress'
			},
		]
	}
	assert issue.has_open_blockers(['Done', 'Cancelled'])
	assert !Issue{
		id:         '2'
		identifier: 'OPS-2'
		title:      'Ready'
		state:      'Todo'
		blocked_by: [BlockerRef{ identifier: 'OPS-4', state: 'Done' }]
	}.has_open_blockers(['done'])
}

fn test_runtime_snapshot_holds_public_copies() {
	running := [
		RunningSnapshot{
			issue_id:         '1'
			issue_identifier: 'OPS-1'
			state:            'Todo'
			attempt:          0
			started_at_ms:    10
			last_activity_ms: 20
		},
	]
	snapshot := RuntimeSnapshot{
		running: running.clone()
		tokens:  TokenTotals{
			input:  3
			output: 2
			total:  5
		}
	}
	assert snapshot.running.len == 1
	assert snapshot.tokens.total == 5
}
