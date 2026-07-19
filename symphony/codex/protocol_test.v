module codex

import json2

fn decode_object(value string) map[string]json2.Any {
	return json2.decode[json2.Any](value) or { panic(err) }.as_map()
}

fn test_request_builders_match_installed_v2_protocol_shape() {
	initialize := decode_object(initialize_request(1))
	assert (initialize['method'] or { panic('method') }).str() == 'initialize'
	assert (initialize['id'] or { panic('id') }).int() == 1
	initialize_params := (initialize['params'] or { panic('params') }).as_map()
	capabilities := (initialize_params['capabilities'] or { panic('capabilities') }).as_map()
	assert (capabilities['experimentalApi'] or { panic('experimentalApi') }).bool()

	thread_request :=
		decode_object(thread_start_request(2, '/tmp/work', 'never', 'workspace-write'))
	assert (thread_request['method'] or { panic('method') }).str() == 'thread/start'
	thread_params := (thread_request['params'] or { panic('params') }).as_map()
	assert (thread_params['cwd'] or { panic('cwd') }).str() == '/tmp/work'
	assert (thread_params['approvalPolicy'] or { panic('approval') }).str() == 'never'
	assert (thread_params['sandbox'] or { panic('sandbox') }).str() == 'workspace-write'

	turn := decode_object(turn_start_request(3, 'thread-1', 'Do the work', '/tmp/work', 'never',
		'workspaceWrite'))
	assert (turn['method'] or { panic('method') }).str() == 'turn/start'
	turn_params := (turn['params'] or { panic('params') }).as_map()
	assert (turn_params['threadId'] or { panic('threadId') }).str() == 'thread-1'
	assert (turn_params['input'] or { panic('input') }).as_array().len == 1
	assert (turn_params['cwd'] or { panic('cwd') }).str() == '/tmp/work'
	assert (turn_params['approvalPolicy'] or { panic('approval') }).str() == 'never'
	sandbox_policy := (turn_params['sandboxPolicy'] or { panic('sandboxPolicy') }).as_map()
	assert (sandbox_policy['type'] or { panic('type') }).str() == 'workspaceWrite'
	assert (sandbox_policy['writableRoots'] or { panic('roots') }).as_array()[0].str() == '/tmp/work'

	interrupt := decode_object(turn_interrupt_request(4, 'thread-1', 'turn-1'))
	assert (interrupt['method'] or { panic('method') }).str() == 'turn/interrupt'
	assert initialized_notification() == '{"method":"initialized"}'
}

fn test_dynamic_tool_calls_are_classified_and_have_a_safe_failure_response() {
	event := interpret('{"id":77,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","tool":"unknown","arguments":{"value":1}}}') or {
		panic(err)
	}
	assert event.kind == .tool_call
	assert event.request_id == '77'
	assert event.thread_id == 'thread-1'
	assert event.turn_id == 'turn-1'
	response := decode_object(dynamic_tool_failure_response('77', 'unsupported tool'))
	result := (response['result'] or { panic('result') }).as_map()
	assert !(result['success'] or { panic('success') }).bool()
	items := (result['contentItems'] or { panic('contentItems') }).as_array()
	first := items[0].as_map()
	assert (first['text'] or { panic('text') }).str().contains('unsupported tool')
}

fn test_turn_builder_passes_through_schema_owned_policy_objects() {
	turn := decode_object(turn_start_request(3, 'thread-1', 'Do it', '/tmp/work',
		'{"granular":{"mcp_elicitation":"never"}}',
		'{"type":"workspaceWrite","networkAccess":false,"excludeSlashTmp":true}'))
	params := (turn['params'] or { panic('params') }).as_map()
	approval := (params['approvalPolicy'] or { panic('approval') }).as_map()
	granular := (approval['granular'] or { panic('granular') }).as_map()
	assert (granular['mcp_elicitation'] or { panic('mcp_elicitation') }).str() == 'never'
	policy := (params['sandboxPolicy'] or { panic('sandbox') }).as_map()
	assert (policy['type'] or { panic('type') }).str() == 'workspaceWrite'
	assert !(policy['networkAccess'] or { panic('network') }).bool()
	assert (policy['excludeSlashTmp'] or { panic('tmp') }).bool()
}

fn test_protocol_interpreter_correlates_responses_and_extracts_ids() {
	response := interpret('{"id":2,"result":{"thread":{"id":"thread-1"}}}') or { panic(err) }
	assert response.kind == .response
	assert response.request_id == '2'
	assert response.thread_id == 'thread-1'

	started := interpret('{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"inProgress","items":[]}}}') or {
		panic(err)
	}
	assert started.kind == .turn_started
	assert started.thread_id == 'thread-1'
	assert started.turn_id == 'turn-1'
}

fn test_protocol_interpreter_maps_completion_tokens_rate_limits_and_blocking_requests() {
	completed := interpret('{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"failed","items":[],"error":{"message":"boom"}}}}') or {
		panic(err)
	}
	assert completed.kind == .turn_completed
	assert completed.status == 'failed'
	assert completed.error_message == 'boom'

	tokens := interpret('{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-1","turnId":"turn-1","tokenUsage":{"last":{"inputTokens":2,"cachedInputTokens":0,"outputTokens":3,"reasoningOutputTokens":0,"totalTokens":5},"total":{"inputTokens":20,"cachedInputTokens":0,"outputTokens":30,"reasoningOutputTokens":0,"totalTokens":50}}}}') or {
		panic(err)
	}
	assert tokens.kind == .token_usage
	assert tokens.tokens.input == 20
	assert tokens.tokens.output == 30
	assert tokens.tokens.total == 50

	rate := interpret('{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":25,"resetsAt":123}}}}') or {
		panic(err)
	}
	assert rate.kind == .rate_limits
	assert rate.rate_used_percent == 25
	assert rate.rate_resets_at == 123

	blocked := interpret('{"id":99,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1"}}') or {
		panic(err)
	}
	assert blocked.kind == .blocked
	assert blocked.request_id == '99'
}

fn test_unknown_notification_stays_diagnostic() {
	event := interpret('{"method":"future/event","params":{"huge":"bounded by JSONL"}}') or {
		panic(err)
	}
	assert event.kind == .notification
	assert event.method == 'future/event'
}
