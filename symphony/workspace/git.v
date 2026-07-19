module workspace

import os
import time
import symphony.domain
import symphony.processgroup
import symphony.workflow

const git_command_timeout = 30 * time.second

struct GitResult {
	exit_code int
	stdout    string
	stderr    string
}

struct GitRunner {
	cwd         string
	cancel      chan bool
	environment map[string]string
}

// prepare_issue_branch_cancelable leaves a Git workspace on an issue-specific branch.
// Existing local or origin branches are reused; otherwise a branch is created from
// workspace.base_branch. Non-Git workspaces are left unchanged.
pub fn prepare_issue_branch_cancelable(space Workspace, issue domain.Issue, config workflow.WorkspaceConfig, cancel chan bool) !string {
	return prepare_issue_branch_cancelable_sanitized(space, issue, config, []string{}, cancel)
}

// prepare_issue_branch_cancelable_sanitized applies branch preparation without
// exposing tracker credentials to Git or repository-owned checkout hooks.
pub fn prepare_issue_branch_cancelable_sanitized(space Workspace, issue domain.Issue, config workflow.WorkspaceConfig, secret_environment_names []string, cancel chan bool) !string {
	runner := new_git_runner(space.path, secret_environment_names, cancel)
	if !runner.is_worktree()! {
		return ''
	}
	base_branch := if config.base_branch.trim_space() == '' {
		'main'
	} else {
		config.base_branch.trim_space()
	}
	branch := if issue.branch_name.trim_space() == '' {
		'symphony/${workspace_key(issue.identifier).to_lower()}'
	} else {
		issue.branch_name.trim_space()
	}
	runner.validate_branch(base_branch)!
	runner.validate_branch(branch)!
	if branch in [base_branch, 'main', 'master'] {
		return error('workspace_branch_error: issue branch `${branch}` is protected')
	}
	current := runner.current_branch()!
	if current == branch {
		return runner.finish_branch_preparation(branch, base_branch)
	}
	status := runner.require(['status', '--porcelain', '--untracked-files=all'])!
	if status.trim_space() != '' {
		return error('workspace_branch_dirty: cannot switch `${current}` to `${branch}` with uncommitted changes')
	}
	if runner.ref_exists('refs/heads/${branch}')! {
		runner.require(['switch', branch])!
		return runner.finish_branch_preparation(branch, base_branch)
	}
	if runner.fetch_remote_branch_if_exists(branch)! {
		runner.require(['switch', '--track', '-c', branch, 'origin/${branch}'])!
		return runner.finish_branch_preparation(branch, base_branch)
	}
	base_ref := if runner.fetch_remote_branch_if_exists(base_branch)! {
		'origin/${base_branch}'
	} else if runner.ref_exists('refs/heads/${base_branch}')! {
		base_branch
	} else {
		return error('workspace_branch_error: base branch `${base_branch}` was not found locally or on origin')
	}
	runner.require(['switch', '-c', branch, base_ref])!
	return runner.finish_branch_preparation(branch, base_branch)
}

fn (runner GitRunner) finish_branch_preparation(branch string, base_branch string) !string {
	runner.install_push_guard(base_branch)!
	return branch
}

fn (runner GitRunner) install_push_guard(base_branch string) ! {
	git_dir := runner.require(['rev-parse', '--absolute-git-dir'])!.trim_space()
	managed_hooks_dir := os.join_path(git_dir, 'symphony-hooks')
	managed_hook := os.join_path(managed_hooks_dir, 'pre-push')
	original_hook_path_file := os.join_path(git_dir, 'symphony-original-pre-push-path')
	original_hooks_dir_file := os.join_path(git_dir, 'symphony-original-hooks-dir')
	protected_branches_file := os.join_path(git_dir, 'symphony-protected-branches')
	current_hook_path := runner.require(['rev-parse', '--git-path', 'hooks/pre-push'])!.trim_space()
	mut resolved_current_hook := current_hook_path
	if !os.is_abs_path(resolved_current_hook) {
		resolved_current_hook = os.join_path(runner.cwd, resolved_current_hook)
	}
	current_hooks_dir := os.real_path(os.dir(resolved_current_hook))
	managed_hooks_real_path := os.real_path(managed_hooks_dir)
	original_hooks_dir := if current_hooks_dir != managed_hooks_real_path {
		os.write_file(original_hook_path_file, os.real_path(resolved_current_hook) + '\n')!
		os.write_file(original_hooks_dir_file, current_hooks_dir + '\n')!
		current_hooks_dir
	} else if os.exists(original_hooks_dir_file) {
		os.read_file(original_hooks_dir_file)!.trim_space()
	} else {
		resolved := os.join_path(git_dir, 'hooks')
		os.write_file(original_hooks_dir_file, resolved + '\n')!
		resolved
	}

	mut protected_branches := []string{}
	for candidate in [base_branch, 'main', 'master'] {
		if candidate !in protected_branches {
			protected_branches << candidate
		}
	}
	os.mkdir_all(managed_hooks_dir)!
	install_existing_hook_delegates(managed_hooks_dir, original_hooks_dir)!
	os.write_file(protected_branches_file, protected_branches.join('\n') + '\n')!
	os.write_file(managed_hook, protected_push_hook_script())!
	os.chmod(managed_hook, 0o755)!
	runner.require(['config', '--local', 'core.hooksPath', managed_hooks_dir])!
}

fn install_existing_hook_delegates(managed_hooks_dir string, original_hooks_dir string) ! {
	mut hook_names := client_git_hook_names()
	if os.is_dir(original_hooks_dir) {
		for name in os.ls(original_hooks_dir)! {
			if name !in hook_names {
				hook_names << name
			}
		}
	}
	if os.is_dir(managed_hooks_dir) {
		for name in os.ls(managed_hooks_dir)! {
			if name !in hook_names {
				hook_names << name
			}
		}
	}
	for name in hook_names {
		if name == 'pre-push' || name.ends_with('.sample') {
			continue
		}
		managed_hook := os.join_path(managed_hooks_dir, name)
		original_hook := os.join_path(original_hooks_dir, name)
		os.write_file(managed_hook, delegated_hook_script(original_hook))!
		os.chmod(managed_hook, 0o755)!
	}
}

fn client_git_hook_names() []string {
	return [
		'applypatch-msg',
		'pre-applypatch',
		'post-applypatch',
		'pre-commit',
		'pre-merge-commit',
		'prepare-commit-msg',
		'commit-msg',
		'post-commit',
		'pre-rebase',
		'post-checkout',
		'post-merge',
		'pre-auto-gc',
		'post-rewrite',
		'sendemail-validate',
		'fsmonitor-watchman',
		'p4-changelist',
		'p4-prepare-changelist',
		'p4-post-changelist',
		'p4-pre-submit',
		'post-index-change',
		'reference-transaction',
	]
}

fn delegated_hook_script(original_hook string) string {
	quoted_hook := os.quoted_path(original_hook)
	return '#!/bin/sh\nif test -x ${quoted_hook}\nthen\n  exec ${quoted_hook} "$@"\nfi\nexit 0\n'
}

fn protected_push_hook_script() string {
	return
		['#!/bin/sh', 'git_dir="$(git rev-parse --absolute-git-dir)" || exit 1', 'protected_file="$git_dir/symphony-protected-branches"', 'input_file="$(mktemp "\${TMPDIR:-/tmp}/symphony-pre-push.XXXXXX")" || exit 1', 'trap \'rm -f "$input_file"\' EXIT HUP INT TERM', 'cat > "$input_file" || exit 1', 'while read -r local_ref local_sha remote_ref remote_sha', 'do', '  case "$remote_ref" in', '    refs/heads/*)', '      remote_branch="\${remote_ref#refs/heads/}"', '      while IFS= read -r protected_branch', '      do', '        test -n "$protected_branch" || continue', '        if test "$remote_branch" = "$protected_branch"', '        then', '          echo "Symphony: refusing to push protected branch \'$protected_branch\'." >&2', '          exit 1', '        fi', '      done < "$protected_file"', '      ;;', '  esac', 'done < "$input_file"', 'original_path_file="$git_dir/symphony-original-pre-push-path"', 'if test -f "$original_path_file"', 'then', '  IFS= read -r original_hook < "$original_path_file"', '  if test -x "$original_hook"', '  then', '    "$original_hook" "$@" < "$input_file" || exit $?', '  fi', 'fi'].join('\n') +
		'\n'
}

fn new_git_runner(cwd string, secret_environment_names []string, cancel chan bool) GitRunner {
	mut environment := os.environ()
	for name in secret_environment_names {
		environment.delete(name)
	}
	environment['GIT_TERMINAL_PROMPT'] = '0'
	return GitRunner{
		cwd:         cwd
		cancel:      cancel
		environment: environment
	}
}

fn (runner GitRunner) is_worktree() !bool {
	if !os.exists(os.join_path(runner.cwd, '.git')) {
		return false
	}
	result := runner.run(['rev-parse', '--is-inside-work-tree'])!
	if result.exit_code != 0 || result.stdout.trim_space() != 'true' {
		return error('workspace_git_error: workspace contains unusable Git metadata: ${bounded_summary(result.stderr)}')
	}
	return true
}

fn (runner GitRunner) validate_branch(branch string) ! {
	result := runner.run(['check-ref-format', '--branch', branch])!
	if result.exit_code != 0 {
		return error('workspace_branch_error: invalid Git branch `${branch}`')
	}
}

fn (runner GitRunner) current_branch() !string {
	result := runner.run(['symbolic-ref', '--quiet', '--short', 'HEAD'])!
	if result.exit_code == 0 {
		return result.stdout.trim_space()
	}
	if result.exit_code == 1 {
		return ''
	}
	return error('workspace_git_error: unable to inspect current branch: ${bounded_summary(result.stderr)}')
}

fn (runner GitRunner) ref_exists(reference string) !bool {
	result := runner.run(['show-ref', '--verify', '--quiet', reference])!
	if result.exit_code == 0 {
		return true
	}
	if result.exit_code == 1 {
		return false
	}
	return error('workspace_git_error: unable to inspect `${reference}`: ${bounded_summary(result.stderr)}')
}

fn (runner GitRunner) fetch_remote_branch_if_exists(branch string) !bool {
	origin := runner.run(['remote', 'get-url', 'origin'])!
	if origin.exit_code == 2 {
		return false
	}
	if origin.exit_code != 0 {
		return error('workspace_git_error: unable to inspect origin: ${bounded_summary(origin.stderr)}')
	}
	remote_ref := 'refs/heads/${branch}'
	remote := runner.run(['ls-remote', '--exit-code', '--heads', 'origin', remote_ref])!
	if remote.exit_code == 2 {
		return false
	}
	if remote.exit_code != 0 {
		return error('workspace_git_error: unable to inspect origin branch `${branch}`: ${bounded_summary(remote.stderr)}')
	}
	runner.require(['fetch', '--no-tags', 'origin', '${remote_ref}:refs/remotes/origin/${branch}'])!
	return true
}

fn (runner GitRunner) require(args []string) !string {
	result := runner.run(args)!
	if result.exit_code != 0 {
		return error('workspace_git_error: git `${args.join(' ')}` exited with code ${result.exit_code}; stderr=${bounded_summary(result.stderr)}')
	}
	return result.stdout
}

fn (runner GitRunner) run(args []string) !GitResult {
	git := os.find_abs_path_of_executable('git') or {
		return error('workspace_git_error: git executable was not found on PATH')
	}
	mut process := os.new_process(git)
	process.set_args(args)
	process.set_work_folder(runner.cwd)
	process.set_redirect_stdio()
	process.set_environment(runner.environment)
	process.use_pgroup = true
	started := time.now()
	process.run()
	if process.status != .running {
		message := if process.err == '' { 'process did not start' } else { process.err }
		process.close()
		return error('workspace_git_error: ${message}')
	}
	mut stdout := ''
	mut stderr := ''
	for process.is_alive() {
		stdout = append_bounded(stdout, process.stdout_read(), default_hook_output_limit)
		stderr = append_bounded(stderr, process.stderr_read(), default_hook_output_limit)
		mut canceled := false
		select {
			_ := <-runner.cancel {
				canceled = true
			}
			1 * time.nanosecond {}
		}
		if canceled {
			processgroup.kill(process.pid)
			process.wait()
			process.close()
			return error('workspace_git_canceled: branch preparation was canceled')
		}
		if time.since(started) > git_command_timeout {
			processgroup.kill(process.pid)
			process.wait()
			process.close()
			return error('workspace_git_timeout: git command exceeded ${git_command_timeout}')
		}
		time.sleep(5 * time.millisecond)
	}
	process.wait()
	processgroup.kill(process.pid)
	stdout = append_bounded(stdout, process.stdout_read(), default_hook_output_limit)
	stderr = append_bounded(stderr, process.stderr_read(), default_hook_output_limit)
	exit_code := process.code
	process.close()
	return GitResult{
		exit_code: exit_code
		stdout:    stdout
		stderr:    stderr
	}
}
