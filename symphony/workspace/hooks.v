module workspace

import os
import time
import symphony.processgroup
import symphony.workflow

pub const default_hook_output_limit = 64 * 1024

pub struct HookResult {
pub:
	exit_code int
	stdout    string
	stderr    string
	duration  time.Duration
}

pub fn run_before(space Workspace, hooks workflow.HooksConfig) ! {
	cancel := chan bool{}
	run_before_cancelable(space, hooks, cancel)!
}

pub fn run_before_cancelable(space Workspace, hooks workflow.HooksConfig, cancel chan bool) ! {
	if hooks.before_run.trim_space() == '' {
		return
	}
	run_hook_cancelable(hooks.before_run, space.path, hooks.timeout_ms, default_hook_output_limit,
		cancel)!
}

pub fn run_after(space Workspace, hooks workflow.HooksConfig) []string {
	cancel := chan bool{}
	return run_after_cancelable(space, hooks, cancel)
}

pub fn run_after_cancelable(space Workspace, hooks workflow.HooksConfig, cancel chan bool) []string {
	if hooks.after_run.trim_space() == '' {
		return []string{}
	}
	run_hook_cancelable(hooks.after_run, space.path, hooks.timeout_ms, default_hook_output_limit,
		cancel) or { return ['after_run_hook_error: ${err.msg()}'] }
	return []string{}
}

pub fn run_hook(script string, cwd string, timeout_ms int, max_output int) !HookResult {
	cancel := chan bool{}
	return run_hook_cancelable(script, cwd, timeout_ms, max_output, cancel)
}

pub fn run_hook_cancelable(script string, cwd string, timeout_ms int, max_output int, cancel chan bool) !HookResult {
	if script.trim_space() == '' {
		return HookResult{}
	}
	if timeout_ms <= 0 {
		return error('hook_config_error: timeout must be positive')
	}
	if max_output <= 0 {
		return error('hook_config_error: output limit must be positive')
	}
	mut process := os.new_process('/bin/bash')
	process.set_args(['-lc', script])
	process.set_work_folder(cwd)
	process.set_redirect_stdio()
	process.use_pgroup = true
	started := time.now()
	process.run()
	if process.status != .running {
		message := if process.err == '' { 'process did not start' } else { process.err }
		process.close()
		return error('hook_start_error: ${message}')
	}
	mut stdout := ''
	mut stderr := ''
	for process.is_alive() {
		stdout = append_bounded(stdout, process.stdout_read(), max_output)
		stderr = append_bounded(stderr, process.stderr_read(), max_output)
		mut canceled := false
		select {
			_ := <-cancel {
				canceled = true
			}
			1 * time.nanosecond {}
		}
		if canceled {
			processgroup.kill(process.pid)
			process.wait()
			process.close()
			return error('hook_canceled: hook was canceled')
		}
		if time.since(started) > time.Duration(timeout_ms) * time.millisecond {
			processgroup.kill(process.pid)
			process.wait()
			stdout = append_bounded(stdout, process.stdout_read(), max_output)
			stderr = append_bounded(stderr, process.stderr_read(), max_output)
			process.close()
			return error('hook_timeout: hook exceeded ${timeout_ms} ms')
		}
		time.sleep(5 * time.millisecond)
	}
	process.wait()
	processgroup.kill(process.pid)
	stdout = append_bounded(stdout, process.stdout_read(), max_output)
	stderr = append_bounded(stderr, process.stderr_read(), max_output)
	exit_code := process.code
	process.close()
	result := HookResult{
		exit_code: exit_code
		stdout:    stdout
		stderr:    stderr
		duration:  time.since(started)
	}
	if exit_code != 0 {
		return error('hook_exit_error: hook exited with code ${exit_code}; stderr=${bounded_summary(stderr)}')
	}
	return result
}

fn append_bounded(target string, value string, limit int) string {
	if value == '' || target.len >= limit {
		return target
	}
	remaining := limit - target.len
	if value.len <= remaining {
		return target + value
	}
	return target + value[..remaining]
}

fn bounded_summary(value string) string {
	trimmed := value.trim_space().replace('\n', ' ')
	if trimmed.len <= 512 {
		return trimmed
	}
	return trimmed[..512]
}
