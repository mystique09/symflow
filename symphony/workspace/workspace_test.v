module workspace

import os
import time
import symphony.domain
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

fn test_issue_branch_preparation_checks_out_an_existing_remote_branch() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	remote := create_git_remote_with_branches(root, ['staging'])!
	space := prepare(root, 'OPS-BRANCH', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	seed := os.join_path(root, 'seed')
	run_hook('git switch -c feature/ops-branch main', seed, 5_000, 8_192)!
	os.write_file(os.join_path(seed, 'branch-marker.txt'), 'feature/ops-branch')!
	run_hook('git add branch-marker.txt && git commit -m feature/ops-branch && git push -u origin feature/ops-branch',
		seed, 5_000, 8_192)!
	cancel := chan bool{}
	branch := prepare_issue_branch_cancelable(space, domain.Issue{
		id:          'issue-branch'
		identifier:  'OPS-BRANCH'
		branch_name: 'feature/ops-branch'
	}, workflow.WorkspaceConfig{
		base_branch: 'staging'
	}, cancel)!

	assert branch == 'feature/ops-branch'
	assert git_output(space.path, ['branch', '--show-current'])! == 'feature/ops-branch'
	assert os.read_file(os.join_path(space.path, 'branch-marker.txt'))! == 'feature/ops-branch'
}

fn test_issue_branch_preparation_refreshes_a_cached_remote_branch_before_checkout() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	remote := create_git_remote_with_branches(root, ['feature/ops-refreshed'])!
	space := prepare(root, 'OPS-REFRESHED', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	seed := os.join_path(root, 'seed')
	run_hook('git switch feature/ops-refreshed', seed, 5_000, 8_192)!
	os.write_file(os.join_path(seed, 'branch-marker.txt'), 'remote-advanced')!
	run_hook('git add branch-marker.txt && git commit -m remote-advanced && git push', seed, 5_000,
		8_192)!
	cancel := chan bool{}
	prepare_issue_branch_cancelable(space, domain.Issue{
		id:          'issue-refreshed'
		identifier:  'OPS-REFRESHED'
		branch_name: 'feature/ops-refreshed'
	}, workflow.WorkspaceConfig{}, cancel)!

	assert os.read_file(os.join_path(space.path, 'branch-marker.txt'))! == 'remote-advanced'
}

fn test_issue_branch_preparation_creates_a_local_branch_from_the_configured_base_without_pushing() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	remote := create_git_remote_with_branches(root, ['staging'])!
	space := prepare(root, 'OPS-NEW', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	cancel := chan bool{}
	branch := prepare_issue_branch_cancelable(space, domain.Issue{
		id:          'issue-new'
		identifier:  'OPS-NEW'
		branch_name: 'feature/ops-new'
	}, workflow.WorkspaceConfig{
		base_branch: 'staging'
	}, cancel)!

	assert branch == 'feature/ops-new'
	assert git_output(space.path, ['branch', '--show-current'])! == 'feature/ops-new'
	assert os.read_file(os.join_path(space.path, 'branch-marker.txt'))! == 'staging'
	assert git_output(space.path, ['ls-remote', '--heads', 'origin', 'feature/ops-new'])! == ''
}

fn test_issue_branch_preparation_blocks_protected_pushes_and_allows_the_issue_branch() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	remote := create_git_remote_with_branches(root, ['staging'])!
	space := prepare(root, 'OPS-PUSH-GUARD', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	existing_hook := os.join_path(space.path, '.git', 'hooks', 'pre-push')
	os.write_file(existing_hook, '#!/bin/sh\nprintf preserved > existing-pre-push-ran.txt\n')!
	os.chmod(existing_hook, 0o755)!
	existing_pre_commit_hook := os.join_path(space.path, '.git', 'hooks', 'pre-commit')
	os.write_file(existing_pre_commit_hook,
		'#!/bin/sh\nprintf preserved > existing-pre-commit-ran.txt\n')!
	os.chmod(existing_pre_commit_hook, 0o755)!
	main_before := git_output(remote, ['rev-parse', 'refs/heads/main'])!
	cancel := chan bool{}
	branch := prepare_issue_branch_cancelable(space, domain.Issue{
		id:          'issue-push-guard'
		identifier:  'OPS-PUSH-GUARD'
		branch_name: 'feature/ops-push-guard'
	}, workflow.WorkspaceConfig{
		base_branch: 'staging'
	}, cancel)!
	os.write_file(os.join_path(space.path, 'guarded-change.txt'), 'issue work')!
	run_hook('git config user.name "Symphony Test" && git config user.email "symphony@example.test" && git add guarded-change.txt && git commit -m guarded-change',
		space.path, 5_000, 8_192)!
	assert os.read_file(os.join_path(space.path, 'existing-pre-commit-ran.txt'))! == 'preserved'

	protected_push := os.execute('git -C ${os.quoted_path(space.path)} push origin HEAD:main')
	assert protected_push.exit_code != 0
	assert protected_push.output.contains("refusing to push protected branch 'main'")
	assert git_output(remote, ['rev-parse', 'refs/heads/main'])! == main_before

	issue_push :=
		os.execute('git -C ${os.quoted_path(space.path)} push -u origin ${os.quoted_path(branch)}')
	assert issue_push.exit_code == 0
	assert os.read_file(os.join_path(space.path, 'existing-pre-push-ran.txt'))! == 'preserved'
	assert git_output(remote, ['rev-parse', 'refs/heads/${branch}'])! == git_output(space.path, [
		'rev-parse',
		'HEAD',
	])!
}

fn test_issue_branch_preparation_refreshes_hooks_path_changed_between_attempts() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	remote := create_git_remote_with_branches(root, []string{})!
	space := prepare(root, 'OPS-HOOKS-PATH', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	cancel := chan bool{}
	issue := domain.Issue{
		id:          'issue-hooks-path'
		identifier:  'OPS-HOOKS-PATH'
		branch_name: 'feature/ops-hooks-path'
	}
	prepare_issue_branch_cancelable(space, issue, workflow.WorkspaceConfig{}, cancel)!
	custom_hooks_dir := os.join_path(space.path, '.custom-hooks')
	os.mkdir_all(custom_hooks_dir)!
	os.write_file(os.join_path(custom_hooks_dir, 'pre-commit'),
		'#!/bin/sh\nprintf refreshed > refreshed-hooks-path-ran.txt\n')!
	os.chmod(os.join_path(custom_hooks_dir, 'pre-commit'), 0o755)!
	os.write_file(os.join_path(custom_hooks_dir, 'pre-push'),
		'#!/bin/sh\nprintf refreshed > refreshed-pre-push-ran.txt\n')!
	os.chmod(os.join_path(custom_hooks_dir, 'pre-push'), 0o755)!
	run_hook('git config core.hooksPath .custom-hooks', space.path, 5_000, 8_192)!
	prepare_issue_branch_cancelable(space, issue, workflow.WorkspaceConfig{}, cancel)!
	os.write_file(os.join_path(space.path, 'hooks-path-change.txt'), 'change')!
	run_hook('git config user.name "Symphony Test" && git config user.email "symphony@example.test" && git add hooks-path-change.txt && git commit -m hooks-path-change',
		space.path, 5_000, 8_192)!
	run_hook('git push -u origin feature/ops-hooks-path', space.path, 5_000, 8_192)!

	assert os.read_file(os.join_path(space.path, 'refreshed-hooks-path-ran.txt'))! == 'refreshed'
	assert os.read_file(os.join_path(space.path, 'refreshed-pre-push-ran.txt'))! == 'refreshed'
}

fn test_issue_branch_preparation_disables_stale_delegates_after_hooks_path_changes() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	remote := create_git_remote_with_branches(root, []string{})!
	space := prepare(root, 'OPS-STALE-HOOK', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	reference_hook := os.join_path(space.path, '.git', 'hooks', 'reference-transaction')
	os.write_file(reference_hook, '#!/bin/sh\nprintf x >> stale-reference-hook-ran.txt\n')!
	os.chmod(reference_hook, 0o755)!
	cancel := chan bool{}
	issue := domain.Issue{
		id:          'issue-stale-hook'
		identifier:  'OPS-STALE-HOOK'
		branch_name: 'feature/ops-stale-hook'
	}
	prepare_issue_branch_cancelable(space, issue, workflow.WorkspaceConfig{}, cancel)!
	run_hook('git config user.name "Symphony Test" && git config user.email "symphony@example.test" && git commit --allow-empty -m first-hook-run',
		space.path, 5_000, 8_192)!
	marker_path := os.join_path(space.path, 'stale-reference-hook-ran.txt')
	before_hooks_path_change := os.read_file(marker_path)!
	empty_hooks_dir := os.join_path(space.path, '.empty-hooks')
	os.mkdir_all(empty_hooks_dir)!
	run_hook('git config core.hooksPath .empty-hooks', space.path, 5_000, 8_192)!
	prepare_issue_branch_cancelable(space, issue, workflow.WorkspaceConfig{}, cancel)!
	run_hook('git commit --allow-empty -m after-hooks-path-change', space.path, 5_000, 8_192)!

	assert before_hooks_path_change != ''
	assert os.read_file(marker_path)! == before_hooks_path_change
}

fn test_issue_branch_preparation_generates_a_branch_when_the_tracker_has_none() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	remote := create_git_remote_with_branches(root, []string{})!
	space := prepare(root, 'OPS-GENERATED', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	cancel := chan bool{}
	branch := prepare_issue_branch_cancelable(space, domain.Issue{
		id:         'issue-generated'
		identifier: 'OPS-GENERATED'
	}, workflow.WorkspaceConfig{}, cancel)!

	assert branch == 'symphony/ops-generated'
	assert git_output(space.path, ['branch', '--show-current'])! == 'symphony/ops-generated'
}

fn test_issue_branch_preparation_removes_tracker_secrets_from_git_hooks() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
		os.unsetenv('SYMPHONY_GIT_HOOK_SECRET')
	}
	remote := create_git_remote_with_branches(root, ['feature/ops-secret'])!
	space := prepare(root, 'OPS-SECRET-BRANCH', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	hook := os.join_path(space.path, '.git', 'hooks', 'post-checkout')
	os.write_file(hook,
		'#!/bin/sh\ntest -z "$SYMPHONY_GIT_HOOK_SECRET" || exit 9\nprintf clean > git-hook-secret.txt\n')!
	os.chmod(hook, 0o755)!
	os.setenv('SYMPHONY_GIT_HOOK_SECRET', 'must-not-leak', true)
	cancel := chan bool{}
	prepare_issue_branch_cancelable_sanitized(space, domain.Issue{
		id:          'issue-secret'
		identifier:  'OPS-SECRET-BRANCH'
		branch_name: 'feature/ops-secret'
	}, workflow.WorkspaceConfig{}, ['SYMPHONY_GIT_HOOK_SECRET'], cancel)!

	assert os.read_file(os.join_path(space.path, 'git-hook-secret.txt'))! == 'clean'
	assert os.getenv('SYMPHONY_GIT_HOOK_SECRET') == 'must-not-leak'
}

fn test_issue_branch_preparation_rejects_protected_and_dirty_branch_switches() {
	root := temp_workspace_root()
	defer {
		os.rmdir_all(root) or {}
	}
	remote := create_git_remote_with_branches(root, []string{})!
	space := prepare(root, 'OPS-GUARD', workflow.HooksConfig{
		after_create: 'git clone "${remote}" .'
		timeout_ms:   5_000
	})!
	cancel := chan bool{}
	prepare_issue_branch_cancelable(space, domain.Issue{
		id:          'issue-protected'
		identifier:  'OPS-GUARD'
		branch_name: 'main'
	}, workflow.WorkspaceConfig{}, cancel) or {
		assert err.msg().contains('protected')
		assert git_output(space.path, ['branch', '--show-current'])! == 'main'
		os.write_file(os.join_path(space.path, 'uncommitted.txt'), 'keep')!
		prepare_issue_branch_cancelable(space, domain.Issue{
			id:          'issue-dirty'
			identifier:  'OPS-GUARD'
			branch_name: 'feature/ops-guard'
		}, workflow.WorkspaceConfig{}, cancel) or {
			assert err.msg().contains('workspace_branch_dirty')
			assert os.read_file(os.join_path(space.path, 'uncommitted.txt'))! == 'keep'
			return
		}
		assert false, 'dirty workspace must not switch branches'
		return
	}
	assert false, 'protected issue branch must be rejected'
}

fn create_git_remote_with_branches(root string, branches []string) !string {
	remote := os.join_path(root, 'remote.git')
	seed := os.join_path(root, 'seed')
	os.mkdir_all(seed)!
	run_hook('git init --bare "${remote}"', root, 5_000, 8_192)!
	run_hook('git init -b main && git config user.name "Symphony Test" && git config user.email "symphony@example.test"',
		seed, 5_000, 8_192)!
	os.write_file(os.join_path(seed, 'branch-marker.txt'), 'main')!
	run_hook('git add branch-marker.txt && git commit -m main && git remote add origin "${remote}" && git push -u origin main',
		seed, 5_000, 8_192)!
	for branch in branches {
		run_hook('git switch -c "${branch}" main', seed, 5_000, 8_192)!
		os.write_file(os.join_path(seed, 'branch-marker.txt'), branch)!
		run_hook('git add branch-marker.txt && git commit -m "${branch}" && git push -u origin "${branch}"',
			seed, 5_000, 8_192)!
		run_hook('git switch main', seed, 5_000, 8_192)!
	}
	run_hook('git symbolic-ref HEAD refs/heads/main', remote, 5_000, 8_192)!
	return remote
}

fn git_output(cwd string, args []string) !string {
	mut command_args := ['git']
	command_args << args
	command := command_args.map(os.quoted_path(it)).join(' ')
	result := run_hook(command, cwd, 5_000, 8_192)!
	return result.stdout.trim_space()
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
