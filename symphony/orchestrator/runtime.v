module orchestrator

import symphony.domain

enum CommandKind {
	claim
	finish
	release
	release_blocked
	defer_retry
	activate_retry
	update_issue
	update_session
	reconfigure
	snapshot
	shutdown
}

struct Command {
	kind           CommandKind
	issue          domain.Issue
	update         domain.SessionUpdate
	issue_id       string
	outcome        domain.AttemptOutcome
	attempt        int
	now_ms         i64
	bool_reply     chan bool
	int_reply      chan int
	attempt_reply  chan Attempt
	snapshot_reply chan domain.RuntimeSnapshot
	max_concurrent int
	max_backoff_ms int
	due_at_ms      i64
	error_message  string
}

pub struct Runtime {
	commands chan Command
}

pub fn start_runtime(max_concurrent int, max_backoff_ms int) Runtime {
	commands := chan Command{cap: 32}
	spawn runtime_loop(new_state(max_concurrent, max_backoff_ms), commands)
	return Runtime{
		commands: commands
	}
}

pub fn (runtime Runtime) claim(issue domain.Issue, attempt int, now_ms i64) bool {
	reply := chan bool{cap: 1}
	runtime.commands <- Command{
		kind:       .claim
		issue:      issue
		attempt:    attempt
		now_ms:     now_ms
		bool_reply: reply
	}
	return <-reply
}

pub fn (runtime Runtime) snapshot(now_ms i64) domain.RuntimeSnapshot {
	reply := chan domain.RuntimeSnapshot{cap: 1}
	runtime.commands <- Command{
		kind:           .snapshot
		now_ms:         now_ms
		snapshot_reply: reply
	}
	return <-reply
}

pub fn (runtime Runtime) finish(outcome domain.AttemptOutcome, now_ms i64) {
	reply := chan bool{cap: 1}
	runtime.commands <- Command{
		kind:       .finish
		outcome:    outcome
		now_ms:     now_ms
		bool_reply: reply
	}
	_ := <-reply
}

pub fn (runtime Runtime) release(issue_id string) {
	reply := chan bool{cap: 1}
	runtime.commands <- Command{
		kind:       .release
		issue_id:   issue_id
		bool_reply: reply
	}
	_ := <-reply
}

pub fn (runtime Runtime) release_blocked() int {
	reply := chan int{cap: 1}
	runtime.commands <- Command{
		kind:      .release_blocked
		int_reply: reply
	}
	return <-reply
}

pub fn (runtime Runtime) defer_retry(issue_id string, due_at_ms i64, reason string) bool {
	reply := chan bool{cap: 1}
	runtime.commands <- Command{
		kind:          .defer_retry
		issue_id:      issue_id
		due_at_ms:     due_at_ms
		error_message: reason
		bool_reply:    reply
	}
	return <-reply
}

pub fn (runtime Runtime) activate_retry(issue_id string, now_ms i64) !Attempt {
	reply := chan Attempt{cap: 1}
	runtime.commands <- Command{
		kind:          .activate_retry
		issue_id:      issue_id
		now_ms:        now_ms
		attempt_reply: reply
	}
	attempt := <-reply
	if attempt.issue.id == '' {
		return error('orchestrator_retry_error: retry could not be activated')
	}
	return attempt
}

pub fn (runtime Runtime) update_issue(issue domain.Issue) bool {
	reply := chan bool{cap: 1}
	runtime.commands <- Command{
		kind:       .update_issue
		issue:      issue
		bool_reply: reply
	}
	return <-reply
}

pub fn (runtime Runtime) update_session(update domain.SessionUpdate) bool {
	reply := chan bool{cap: 1}
	runtime.commands <- Command{
		kind:       .update_session
		issue_id:   update.issue_id
		update:     update
		bool_reply: reply
	}
	return <-reply
}

pub fn (runtime Runtime) reconfigure(max_concurrent int, max_backoff_ms int) bool {
	reply := chan bool{cap: 1}
	runtime.commands <- Command{
		kind:           .reconfigure
		max_concurrent: max_concurrent
		max_backoff_ms: max_backoff_ms
		bool_reply:     reply
	}
	return <-reply
}

pub fn (runtime Runtime) shutdown() {
	reply := chan bool{cap: 1}
	runtime.commands <- Command{
		kind:       .shutdown
		bool_reply: reply
	}
	_ := <-reply
}

fn runtime_loop(initial State, commands chan Command) {
	mut state := initial
	for {
		command := <-commands
		match command.kind {
			.claim {
				state.claim(command.issue, command.attempt, command.now_ms) or {
					command.bool_reply <- false
					continue
				}
				command.bool_reply <- true
			}
			.finish {
				state.finish(command.outcome, command.now_ms)
				command.bool_reply <- true
			}
			.release {
				state.release(command.issue_id)
				command.bool_reply <- true
			}
			.release_blocked {
				command.int_reply <- state.release_blocked()
			}
			.defer_retry {
				state.defer_retry(command.issue_id, command.due_at_ms, command.error_message) or {
					command.bool_reply <- false
					continue
				}
				command.bool_reply <- true
			}
			.activate_retry {
				attempt := state.activate_retry(command.issue_id, command.now_ms) or {
					command.attempt_reply <- Attempt{}
					continue
				}
				command.attempt_reply <- attempt
			}
			.update_issue {
				state.update_issue(command.issue) or {
					command.bool_reply <- false
					continue
				}
				command.bool_reply <- true
			}
			.update_session {
				state.update_session(command.update) or {
					command.bool_reply <- false
					continue
				}
				command.bool_reply <- true
			}
			.reconfigure {
				state.reconfigure(command.max_concurrent, command.max_backoff_ms) or {
					command.bool_reply <- false
					continue
				}
				command.bool_reply <- true
			}
			.snapshot {
				command.snapshot_reply <- state.snapshot(command.now_ms)
			}
			.shutdown {
				command.bool_reply <- true
				return
			}
		}
	}
}
