module workspace

import os
import time
import symphony.workflow

fn temp_workspace_root() string {
	path := os.join_path(os.vtmp_dir(), 'symphony_workspace_${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}

fn test_workspace_key_is_readable_stable_and_collision_resistant() {
	assert workspace_key('OPS-42') == 'OPS-42'
	first := workspace_key('../OPS 42')
	assert first == workspace_key('../OPS 42')
	assert first != workspace_key('.._OPS_42')
	assert first.starts_with('.._OPS_42-')
}

fn test_containment_rejects_prefix_confusion_and_symlink_escape() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	outside := '${os.real_path(root)}-outside'
	os.mkdir_all(outside) or { panic(err) }
	defer {
		os.rmdir_all(outside) or {}
	}
	validate_under_root(root, outside) or {
		assert err.msg().contains('workspace_escape')
		return
	}
	assert false, 'prefix-confusion path should be rejected'
}

fn test_prepare_reuses_workspace_and_after_create_runs_once() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	hooks := workflow.HooksConfig{
		after_create: 'printf created >> marker.txt'
		timeout_ms:   2_000
	}
	first := prepare(root, 'OPS-1', hooks) or { panic(err) }
	second := prepare(root, 'OPS-1', hooks) or { panic(err) }
	assert first.created_now
	assert !second.created_now
	assert os.read_file(os.join_path(first.path, 'marker.txt')) or { panic(err) } == 'created'
}

fn test_before_run_executes_for_every_attempt() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	space := prepare(root, 'OPS-2', workflow.HooksConfig{}) or { panic(err) }
	hooks := workflow.HooksConfig{
		before_run: 'printf x >> attempts.txt'
		timeout_ms: 2_000
	}
	run_before(space, hooks) or { panic(err) }
	run_before(space, hooks) or { panic(err) }
	assert os.read_file(os.join_path(space.path, 'attempts.txt')) or { panic(err) } == 'xx'
}

fn test_tracker_secrets_are_removed_from_every_workspace_hook() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
		os.unsetenv('SYMPHONY_HOOK_TEST_SECRET')
	}
	os.setenv('SYMPHONY_HOOK_TEST_SECRET', 'must-not-leak', true)
	hooks := workflow.HooksConfig{
		after_create:  'test -z "\$SYMPHONY_HOOK_TEST_SECRET"'
		before_run:    'test -z "\$SYMPHONY_HOOK_TEST_SECRET"'
		after_run:     'test -z "\$SYMPHONY_HOOK_TEST_SECRET"'
		before_remove: 'test -z "\$SYMPHONY_HOOK_TEST_SECRET"'
		timeout_ms:    2_000
	}
	cancel := chan bool{}
	space := prepare_cancelable_sanitized(root, 'OPS-SECRET', hooks, [
		'SYMPHONY_HOOK_TEST_SECRET',
	], cancel) or { panic(err) }
	run_before_cancelable_sanitized(space, hooks, ['SYMPHONY_HOOK_TEST_SECRET'], cancel) or {
		panic(err)
	}
	assert run_after_sanitized(space, hooks, ['SYMPHONY_HOOK_TEST_SECRET']) == []string{}
	assert remove_sanitized(space, hooks, ['SYMPHONY_HOOK_TEST_SECRET']) or { panic(err) } == []string{}
	assert os.getenv('SYMPHONY_HOOK_TEST_SECRET') == 'must-not-leak'
}

fn test_hook_timeout_terminates_process_group() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	started := time.now()
	run_hook('sleep 2', root, 50, 1024) or {
		assert err.msg().contains('hook_timeout')
		assert time.since(started) < time.second
		return
	}
	assert false, 'slow hook should time out'
}

fn test_hook_cancellation_terminates_process_group() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	cancel := chan bool{cap: 1}
	done := chan string{cap: 1}
	spawn run_cancelable_hook_for_test(root, cancel, done)
	time.sleep(50 * time.millisecond)
	started := time.now()
	cancel <- true
	select {
		message := <-done {
			assert message.contains('hook_canceled')
			assert time.since(started) < time.second
		}
		2 * time.second {
			assert false, 'canceled hook did not stop'
		}
	}
}

fn test_successful_hook_does_not_leave_background_descendants() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	marker := os.join_path(root, 'orphan-marker')
	run_hook('(trap "" HUP; sleep 1; printf survived > "${marker}") &', root, 2_000, 1024)!
	time.sleep(1_200 * time.millisecond)
	assert !os.exists(marker)
}

fn run_cancelable_hook_for_test(root string, cancel chan bool, done chan string) {
	run_hook_cancelable('sleep 5', root, 10_000, 1024, cancel) or {
		done <- err.msg()
		return
	}
	done <- ''
}

fn test_remove_ignores_before_remove_failure_and_deletes_workspace() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	space := prepare(root, 'OPS-3', workflow.HooksConfig{}) or { panic(err) }
	warnings := remove(space, workflow.HooksConfig{
		before_remove: 'exit 7'
		timeout_ms:    2_000
	}) or { panic(err) }
	assert warnings.len == 1
	assert !os.exists(space.path)
}

fn test_remove_does_not_follow_workspace_symlink_created_by_hook() {
	root := temp_workspace_root()
	outside := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
		os.rmdir_all(outside) or {}
	}
	os.write_file(os.join_path(outside, 'keep.txt'), 'safe')!
	space := prepare(root, 'OPS-4', workflow.HooksConfig{})!
	name := os.base(space.path)
	hook := 'cd ..; rmdir "${name}"; ln -s "${outside}" "${name}"'
	remove(space, workflow.HooksConfig{
		before_remove: hook
		timeout_ms:    2_000
	})!
	assert os.read_file(os.join_path(outside, 'keep.txt'))! == 'safe'
	assert !os.is_link(space.path)
}
