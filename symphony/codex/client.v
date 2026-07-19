module codex

import os
import time
import symphony.domain
import symphony.processgroup

const diagnostic_limit = 64 * 1024

pub struct ClientConfig {
pub:
	command                  string
	cwd                      string
	approval_policy          string = 'never'
	thread_sandbox           string = 'workspace-write'
	turn_sandbox_policy      string = 'workspaceWrite'
	read_timeout_ms          int    = 5_000
	turn_timeout_ms          int    = 3_600_000
	stall_timeout_ms         int    = 300_000
	max_line_bytes           int    = 10 * 1024 * 1024
	secret_environment_names []string
}

pub struct ClientResult {
pub:
	outcome           domain.AttemptOutcomeKind
	thread_id         string
	turn_id           string
	tokens            domain.TokenTotals
	rate_used_percent int
	rate_resets_at    i64
	stderr            string
	error_message     string
	pid               int
	turns_started     int
}

pub struct SessionPolicy {
pub:
	max_turns           int = 1
	continuation_prompt string
}

pub type ContinuationDecider = fn (turns_completed int) bool

pub type SessionObserver = fn (update domain.SessionUpdate)

enum ClientStage {
	awaiting_initialize
	awaiting_thread
	awaiting_turn
	streaming
}

pub fn run_attempt(config ClientConfig, prompt string, cancel chan bool) !ClientResult {
	return run_session(config, prompt, SessionPolicy{}, cancel, stop_after_first_turn)
}

pub fn run_session(config ClientConfig, prompt string, policy SessionPolicy, cancel chan bool, should_continue ContinuationDecider) !ClientResult {
	return run_session_observed(config, prompt, policy, cancel, should_continue,
		ignore_session_update)
}

pub fn run_session_observed(config ClientConfig, prompt string, policy SessionPolicy, cancel chan bool, should_continue ContinuationDecider, observer SessionObserver) !ClientResult {
	validate_client_config(config)!
	if policy.max_turns <= 0 {
		return error('codex_config_error: max turns must be positive')
	}
	if policy.max_turns > 1 && policy.continuation_prompt.trim_space() == '' {
		return error('codex_config_error: continuation prompt is required for multi-turn sessions')
	}
	if !os.is_dir(config.cwd) {
		return error('codex_workspace_error: cwd is not an existing directory')
	}
	mut process := os.new_process('/bin/bash')
	process.set_args(['-lc', config.command])
	process.set_work_folder(config.cwd)
	process.set_redirect_stdio()
	process.use_pgroup = true
	mut environment := os.environ()
	for name in config.secret_environment_names {
		environment.delete(name)
	}
	process.set_environment(environment)
	process.run()
	if process.status != .running {
		message := if process.err == '' { 'process did not start' } else { process.err }
		process.close()
		return error('codex_start_error: ${message}')
	}
	pid := process.pid
	observer(domain.SessionUpdate{
		event:        'process_started'
		timestamp_ms: time.now().unix_milli()
		pid:          pid
	})
	mut decoder := new_jsonl_decoder(config.max_line_bytes)!
	mut stage := ClientStage.awaiting_initialize
	mut thread_id := ''
	mut turn_id := ''
	mut turns_started := 0
	mut next_turn_request_id := 3
	mut pending_turn_request_id := '3'
	mut tokens := domain.TokenTotals{}
	mut rate_used_percent := 0
	mut rate_resets_at := i64(0)
	mut diagnostics := ''
	started := time.now()
	mut stage_started := started
	mut turn_started := started
	mut last_activity := started
	write_message(mut process, initialize_request(1))
	for {
		mut was_canceled := false
		select {
			_ := <-cancel {
				was_canceled = true
			}
			1 * time.nanosecond {}
		}
		if was_canceled {
			return finish_client(mut process, ClientResult{
				outcome:       .canceled
				thread_id:     thread_id
				turn_id:       turn_id
				tokens:        tokens
				stderr:        diagnostics
				error_message: 'canceled by orchestrator'
				pid:           pid
				turns_started: turns_started
			})
		}
		diagnostics = append_diagnostic(diagnostics, process.stderr_read())
		chunk := process.stdout_read()
		if chunk != '' {
			last_activity = time.now()
			frames := decoder.feed(chunk) or {
				return finish_client(mut process, ClientResult{
					outcome:       .failed
					thread_id:     thread_id
					turn_id:       turn_id
					tokens:        tokens
					stderr:        diagnostics
					error_message: err.msg()
					pid:           pid
				})
			}
			for frame in frames {
				event := interpret(frame) or {
					return finish_client(mut process, ClientResult{
						outcome:       .failed
						thread_id:     thread_id
						turn_id:       turn_id
						tokens:        tokens
						stderr:        diagnostics
						error_message: err.msg()
						pid:           pid
					})
				}
				last_activity = time.now()
				if event.kind == .tool_call {
					write_message(mut process, dynamic_tool_failure_response(event.request_id,
						'unsupported dynamic tool `${event.method}`'))
					observer(domain.SessionUpdate{
						event:        'unsupported_tool_call'
						timestamp_ms: last_activity.unix_milli()
						pid:          pid
						thread_id:    if event.thread_id == '' { thread_id } else { event.thread_id }
						turn_id:      if event.turn_id == '' { turn_id } else { event.turn_id }
						message:      'rejected unsupported ${event.method}'
						turn_count:   turns_started
						tokens:       tokens
						rate_limit:   domain.RateLimitSnapshot{
							used_percent: rate_used_percent
							resets_at:    rate_resets_at
						}
					})
					continue
				}
				if event.kind == .blocked {
					return finish_client(mut process, ClientResult{
						outcome:       .blocked
						thread_id:     if event.thread_id == '' {
							thread_id
						} else {
							event.thread_id
						}
						turn_id:       if event.turn_id == '' { turn_id } else { event.turn_id }
						tokens:        tokens
						stderr:        diagnostics
						error_message: 'Codex requested operator input through ${event.method}'
						pid:           pid
						turns_started: turns_started
					})
				}
				if event.kind == .protocol_error {
					return finish_client(mut process, ClientResult{
						outcome:       .failed
						thread_id:     thread_id
						turn_id:       turn_id
						tokens:        tokens
						stderr:        diagnostics
						error_message: event.error_message
						pid:           pid
					})
				}
				if event.kind == .token_usage {
					tokens = event.tokens
					observer(domain.SessionUpdate{
						event:        'token_usage'
						timestamp_ms: last_activity.unix_milli()
						pid:          pid
						thread_id:    thread_id
						turn_id:      turn_id
						turn_count:   turns_started
						tokens:       tokens
					})
				}
				if event.kind == .rate_limits {
					rate_used_percent = event.rate_used_percent
					rate_resets_at = event.rate_resets_at
					observer(domain.SessionUpdate{
						event:        'rate_limits'
						timestamp_ms: last_activity.unix_milli()
						pid:          pid
						thread_id:    thread_id
						turn_id:      turn_id
						turn_count:   turns_started
						tokens:       tokens
						rate_limit:   domain.RateLimitSnapshot{
							used_percent: rate_used_percent
							resets_at:    rate_resets_at
						}
					})
				}
				if event.kind == .turn_completed {
					observer(domain.SessionUpdate{
						event:        'turn_completed'
						timestamp_ms: last_activity.unix_milli()
						pid:          pid
						thread_id:    if event.thread_id == '' { thread_id } else { event.thread_id }
						turn_id:      if event.turn_id == '' { turn_id } else { event.turn_id }
						message:      event.error_message
						turn_count:   turns_started
						tokens:       tokens
						rate_limit:   domain.RateLimitSnapshot{
							used_percent: rate_used_percent
							resets_at:    rate_resets_at
						}
					})
					outcome := match event.status {
						'completed' { domain.AttemptOutcomeKind.succeeded }
						'interrupted' { domain.AttemptOutcomeKind.canceled }
						else { domain.AttemptOutcomeKind.failed }
					}
					if outcome == .succeeded && turns_started < policy.max_turns
						&& should_continue(turns_started) {
						pending_turn_request_id = next_turn_request_id.str()
						write_message(mut process, turn_start_request(next_turn_request_id,
							thread_id, policy.continuation_prompt, config.cwd,
							config.approval_policy, config.turn_sandbox_policy))
						next_turn_request_id++
						turns_started++
						turn_id = ''
						turn_started = time.now()
						stage_started = turn_started
						stage = .awaiting_turn
						continue
					}
					return finish_client(mut process, ClientResult{
						outcome:           outcome
						thread_id:         if event.thread_id == '' {
							thread_id
						} else {
							event.thread_id
						}
						turn_id:           if event.turn_id == '' { turn_id } else { event.turn_id }
						tokens:            tokens
						rate_used_percent: rate_used_percent
						rate_resets_at:    rate_resets_at
						stderr:            diagnostics
						error_message:     event.error_message
						pid:               pid
						turns_started:     turns_started
					})
				}
				if event.kind == .response {
					match stage {
						.awaiting_initialize {
							if event.request_id == '1' {
								write_message(mut process, initialized_notification())
								write_message(mut process, thread_start_request(2, config.cwd,
									config.approval_policy, config.thread_sandbox))
								stage_started = time.now()
								stage = .awaiting_thread
							}
						}
						.awaiting_thread {
							if event.request_id == '2' {
								if event.thread_id == '' {
									return finish_client(mut process, failed_result(pid,
										diagnostics, 'thread/start response omitted thread.id'))
								}
								thread_id = event.thread_id
								observer(domain.SessionUpdate{
									event:        'thread_started'
									timestamp_ms: last_activity.unix_milli()
									pid:          pid
									thread_id:    thread_id
								})
								pending_turn_request_id = next_turn_request_id.str()
								write_message(mut process, turn_start_request(next_turn_request_id,
									thread_id, prompt, config.cwd, config.approval_policy,
									config.turn_sandbox_policy))
								next_turn_request_id++
								turns_started++
								turn_started = time.now()
								stage_started = turn_started
								stage = .awaiting_turn
							}
						}
						.awaiting_turn {
							if event.request_id == pending_turn_request_id {
								turn_id = event.turn_id
								stage = .streaming
							}
						}
						.streaming {}
					}
				}
				if event.kind == .turn_started {
					thread_id = event.thread_id
					turn_id = event.turn_id
					turn_started = time.now()
					stage = .streaming
					observer(domain.SessionUpdate{
						event:        'turn_started'
						timestamp_ms: last_activity.unix_milli()
						pid:          pid
						thread_id:    thread_id
						turn_id:      turn_id
						turn_count:   turns_started
						tokens:       tokens
					})
				}
			}
		}
		if !process.is_alive() {
			diagnostics = append_diagnostic(diagnostics, process.stderr_read())
			processgroup.kill(pid)
			process.wait()
			code := process.code
			process.close()
			return ClientResult{
				outcome:       .process_exited
				thread_id:     thread_id
				turn_id:       turn_id
				tokens:        tokens
				stderr:        diagnostics
				error_message: 'Codex app-server exited with code ${code}'
				pid:           pid
				turns_started: turns_started
			}
		}
		if stage in [.awaiting_initialize, .awaiting_thread, .awaiting_turn]
			&& time.since(stage_started) > duration_ms(config.read_timeout_ms) {
			return finish_client(mut process, failed_result(pid, diagnostics,
				'Codex response timeout'))
		}
		if stage == .streaming && time.since(turn_started) > duration_ms(config.turn_timeout_ms) {
			return finish_client(mut process, ClientResult{
				...failed_result(pid, diagnostics, 'Codex turn timeout')
				outcome:       .timed_out
				thread_id:     thread_id
				turn_id:       turn_id
				tokens:        tokens
				turns_started: turns_started
			})
		}
		if stage == .streaming && config.stall_timeout_ms > 0
			&& time.since(last_activity) > duration_ms(config.stall_timeout_ms) {
			return finish_client(mut process, ClientResult{
				...failed_result(pid, diagnostics, 'Codex session stalled')
				outcome:       .stalled
				thread_id:     thread_id
				turn_id:       turn_id
				tokens:        tokens
				turns_started: turns_started
			})
		}
		time.sleep(5 * time.millisecond)
	}
	return error('codex_internal_error: client loop stopped unexpectedly')
}

fn stop_after_first_turn(_ int) bool {
	return false
}

fn ignore_session_update(_ domain.SessionUpdate) {}

fn validate_client_config(config ClientConfig) ! {
	if config.command.trim_space() == '' {
		return error('codex_config_error: command is required')
	}
	if config.read_timeout_ms <= 0 || config.turn_timeout_ms <= 0 || config.max_line_bytes <= 0 {
		return error('codex_config_error: read timeout, turn timeout, and line limit must be positive')
	}
}

fn write_message(mut process os.Process, message string) {
	process.stdin_write(message + '\n')
}

fn finish_client(mut process os.Process, result ClientResult) ClientResult {
	processgroup.kill(process.pid)
	process.wait()
	diagnostics := append_diagnostic(result.stderr, process.stderr_read())
	process.close()
	return ClientResult{
		...result
		stderr: diagnostics
	}
}

fn failed_result(pid int, diagnostics string, message string) ClientResult {
	return ClientResult{
		outcome:       .failed
		stderr:        diagnostics
		error_message: message
		pid:           pid
	}
}

fn append_diagnostic(existing string, chunk string) string {
	if chunk == '' || existing.len >= diagnostic_limit {
		return existing
	}
	remaining := diagnostic_limit - existing.len
	return existing + if chunk.len <= remaining {
		chunk
	} else {
		chunk[..remaining]
	}
}

fn duration_ms(value int) time.Duration {
	return time.Duration(value) * time.millisecond
}
