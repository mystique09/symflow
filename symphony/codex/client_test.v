module codex

import os
import time
import symphony.domain

const fixture_response_timeout_ms = 10_000

fn fake_app_server(dir string) string {
	path := os.join_path(dir, 'fake-app-server.sh')
	source := '#!/bin/sh\nmode="$1"\nif [ "$mode" = orphan ]; then\n  (trap "" HUP; sleep 1; printf survived > "$2") &\n  exit 7\nfi\nsecret_value=$(printenv LINEAR_API_KEY 2>/dev/null || printf unset)\nprintf "secret=%s\\n" "$secret_value" >&2\nwhile IFS= read -r line; do\n  case "$line" in\n    *thread/start*) printf \'{"id":2,"result":{"thread":{"id":"thread-1"}}}\\n\' ;;\n    *turn/start*)\n      if [ "$mode" = multi ]; then printf "%s\\n" "$line" >> "$2"; fi\n      printf \'{"id":3,"result":{"turn":{"id":"turn-1","status":"inProgress"}}}\\n\'\n      if [ "$mode" = blocked ]; then\n        printf \'{"id":99,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1"}}\\n\'\n      elif [ "$mode" = stall ]; then\n        sleep 5\n      else\n        printf \'{"method":"thread/tokenUsage/updated","params":{"threadId":"thread-1","turnId":"turn-1","tokenUsage":{"total":{"inputTokens":2,"outputTokens":3,"totalTokens":5}}}}\\n\'\n        printf \'{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","items":[]}}}\\n\'\n      fi ;;\n    *initialize*) printf \'{"id":1,"result":{}}\\n\' ;;\n  esac\ndone\n'
	os.write_file(path, source) or { panic(err) }
	os.chmod(path, 0o700) or { panic(err) }
	return path
}

fn client_test_dir() string {
	path := os.join_path(os.vtmp_dir(), 'symphony_codex_${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}

fn fake_chatty_startup_server(dir string) !string {
	path := os.join_path(dir, 'fake-chatty-app-server.sh')
	source := '#!/bin/sh\nwhile IFS= read -r line; do\n  while :; do\n    printf \'{"method":"account/rateLimits/updated","params":{}}\\n\'\n    sleep 0.02\n  done\ndone\n'
	os.write_file(path, source)!
	os.chmod(path, 0o700)!
	return path
}

fn fake_dynamic_tool_server(dir string) !string {
	path := os.join_path(dir, 'fake-dynamic-tool-server.sh')
	source := '#!/bin/sh\nwhile IFS= read -r line; do\n  case "$line" in\n    *thread/start*) printf \'{"id":2,"result":{"thread":{"id":"thread-1"}}}\\n\' ;;\n    *turn/start*) printf \'{"id":3,"result":{"turn":{"id":"turn-1","status":"inProgress"}}}\\n\'; printf \'{"id":99,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","tool":"unknown","arguments":{}}}\\n\' ;;\n    *\'"id":99\'*) printf \'{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","status":"completed","items":[]}}}\\n\' ;;\n    *initialize*) printf \'{"id":1,"result":{}}\\n\' ;;\n  esac\ndone\n'
	os.write_file(path, source)!
	os.chmod(path, 0o700)!
	return path
}

fn test_client_initializes_runs_turn_tracks_tokens_and_removes_secret() {
	dir := client_test_dir()
	defer {
		os.rmdir_all(dir) or {}
		os.unsetenv('LINEAR_API_KEY')
	}
	os.setenv('LINEAR_API_KEY', 'must-not-leak', true)
	server := fake_app_server(dir)
	cancel := chan bool{cap: 1}
	result := run_attempt(ClientConfig{
		command:                  '${server} success'
		cwd:                      dir
		approval_policy:          'never'
		thread_sandbox:           'workspace-write'
		read_timeout_ms:          fixture_response_timeout_ms
		turn_timeout_ms:          fixture_response_timeout_ms
		stall_timeout_ms:         1_000
		max_line_bytes:           64 * 1024
		secret_environment_names: ['LINEAR_API_KEY']
	}, 'Do the work', cancel) or { panic(err) }
	assert result.outcome == .succeeded, '${result.error_message}; ${result.stderr}'
	assert result.thread_id == 'thread-1'
	assert result.turn_id == 'turn-1'
	assert result.tokens.total == 5
	assert result.stderr.contains('secret=unset')
	assert !result.stderr.contains('must-not-leak')
}

fn test_client_surfaces_blocked_input_and_stops_process() {
	dir := client_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	server := fake_app_server(dir)
	cancel := chan bool{cap: 1}
	result := run_attempt(ClientConfig{
		command:          '${server} blocked'
		cwd:              dir
		read_timeout_ms:  fixture_response_timeout_ms
		turn_timeout_ms:  fixture_response_timeout_ms
		stall_timeout_ms: 1_000
		max_line_bytes:   64 * 1024
	}, 'Do the work', cancel) or { panic(err) }
	assert result.outcome == .blocked, '${result.error_message}; ${result.stderr}'
	assert result.error_message.contains('item/tool/requestUserInput')
}

fn test_client_distinguishes_stall_timeout() {
	dir := client_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	server := fake_app_server(dir)
	cancel := chan bool{cap: 1}
	result := run_attempt(ClientConfig{
		command:          '${server} stall'
		cwd:              dir
		read_timeout_ms:  fixture_response_timeout_ms
		turn_timeout_ms:  fixture_response_timeout_ms
		stall_timeout_ms: 50
		max_line_bytes:   64 * 1024
	}, 'Do the work', cancel) or { panic(err) }
	assert result.outcome == .stalled, '${result.error_message}; ${result.stderr}'
}

fn test_client_kills_process_group_when_leader_exits() {
	dir := client_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	server := fake_app_server(dir)
	marker := os.join_path(dir, 'orphan-marker')
	result := run_attempt(ClientConfig{
		command:          '${server} orphan ${marker}'
		cwd:              dir
		read_timeout_ms:  fixture_response_timeout_ms
		turn_timeout_ms:  fixture_response_timeout_ms
		stall_timeout_ms: 1_000
	}, 'Do the work', chan bool{cap: 1})!
	assert result.outcome == .process_exited
	time.sleep(1_200 * time.millisecond)
	assert !os.exists(marker)
}

fn test_startup_request_timeout_is_not_extended_by_unrelated_messages() {
	dir := client_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	server := fake_chatty_startup_server(dir)!
	started := time.now()
	result := run_attempt(ClientConfig{
		command:          server
		cwd:              dir
		read_timeout_ms:  75
		turn_timeout_ms:  fixture_response_timeout_ms
		stall_timeout_ms: 1_000
	}, 'Do the work', chan bool{cap: 1})!
	assert result.outcome == .failed
	assert result.error_message.contains('response timeout')
	assert time.since(started) < time.second
}

fn test_session_continues_on_same_thread_with_guidance_up_to_max_turns() {
	dir := client_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	server := fake_app_server(dir)
	turn_log := os.join_path(dir, 'turns.jsonl')
	result := run_session(ClientConfig{
		command:          '${server} multi ${turn_log}'
		cwd:              dir
		read_timeout_ms:  fixture_response_timeout_ms
		turn_timeout_ms:  fixture_response_timeout_ms
		stall_timeout_ms: 1_000
	}, 'Original task prompt', SessionPolicy{
		max_turns:           2
		continuation_prompt: 'Continue the same task'
	}, chan bool{cap: 1}, fn (_ int) bool {
		return true
	})!
	assert result.outcome == .succeeded
	assert result.thread_id == 'thread-1'
	assert result.turns_started == 2
	turns := os.read_lines(turn_log)!
	assert turns.len == 2
	assert turns[0].contains('Original task prompt')
	assert turns[1].contains('Continue the same task')
	assert !turns[1].contains('Original task prompt')
}

fn test_client_rejects_unsupported_dynamic_tool_and_keeps_session_alive() {
	dir := client_test_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	server := fake_dynamic_tool_server(dir)!
	updates := chan domain.SessionUpdate{cap: 16}
	result := run_session_observed(ClientConfig{
		command:          server
		cwd:              dir
		read_timeout_ms:  fixture_response_timeout_ms
		turn_timeout_ms:  fixture_response_timeout_ms
		stall_timeout_ms: 1_000
	}, 'Do the work', SessionPolicy{}, chan bool{cap: 1}, stop_after_first_turn, fn [updates] (update domain.SessionUpdate) {
		updates <- update
	})!
	assert result.outcome == .succeeded, '${result.error_message}; ${result.stderr}'
	mut events := []string{}
	for {
		select {
			update := <-updates {
				events << update.event
			}
			else {
				break
			}
		}
	}
	assert 'process_started' in events
	assert 'unsupported_tool_call' in events
	assert 'turn_completed' in events
}
