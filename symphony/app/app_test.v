module app

import os

fn test_parse_defaults_to_run_with_default_workflow() {
	options := parse_args([]string{})!
	assert options.command == .run
	assert options.workflow_path == 'WORKFLOW.md'
	assert options.env_path == '.env'
	assert !options.env_explicit
	assert options.web_host == '127.0.0.1'
	assert options.web_port == -1
	assert !options.web_enabled
}

fn test_parse_accepts_explicit_env_file() {
	options := parse_args(['doctor', 'ops/WORKFLOW.md', '--env', 'ops/development.env'])!
	assert options.command == .doctor
	assert options.workflow_path == 'ops/WORKFLOW.md'
	assert options.env_path == 'ops/development.env'
	assert options.env_explicit
}

fn test_parse_rejects_env_without_a_path() {
	parse_args(['run', '--env']) or {
		assert err.msg().contains('--env requires a path')
		return
	}
	assert false
}

fn test_parse_accepts_positional_workflow_and_port_zero() {
	run_options := parse_args(['ops/WORKFLOW.md', '--port', '0'])!
	assert run_options.command == .run
	assert run_options.workflow_path == 'ops/WORKFLOW.md'
	assert run_options.web_enabled
	assert run_options.web_port == 0
	validate_options := parse_args(['validate', 'ops/WORKFLOW.md'])!
	assert validate_options.command == .validate
	assert validate_options.workflow_path == 'ops/WORKFLOW.md'
}

fn test_parse_cli_overrides_are_deterministic() {
	options := parse_args(['run', '--workflow', 'ops/WORKFLOW.md', '--once', '--web', '--web-host',
		'0.0.0.0', '--web-port', '9001'])!
	assert options.command == .run
	assert options.workflow_path == 'ops/WORKFLOW.md'
	assert options.once
	assert options.web_enabled
	assert options.web_host == '0.0.0.0'
	assert options.web_port == 9001
}

fn test_parse_rejects_unknown_arguments_and_invalid_ports() {
	parse_args(['run', '--wat']) or {
		assert err.msg().contains('unknown argument')
		parse_args(['run', '--web-port', '70000']) or {
			assert err.msg().contains('web port')
			return
		}
		assert false
		return
	}
	assert false
}

fn test_validate_workflow_does_not_require_live_credentials() {
	dir := os.join_path(os.temp_dir(), 'symphony-app-test-${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path, '# Work on {{ issue.identifier }}')!
	definition := validate_workflow(path)!
	assert definition.prompt_template.contains('issue.identifier')
}

fn test_validate_workflow_rejects_invalid_github_state_mapping_without_live_credentials() {
	dir := os.join_path(os.temp_dir(), 'symphony-app-github-validation-${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path,
		'---\ntracker:\n  kind: github\n  provider:\n    repository: octo/example\n    state_labels:\n      Todo: status:ready\n      In Progress: status:ready\n  active_states:\n    - Todo\n    - In Progress\n  terminal_states:\n    - Closed\n---\nWork on {{ issue.identifier }}')!

	validate_workflow(path) or {
		assert err.msg().contains('invalid_tracker_config')
		assert err.msg().contains('unique')
		return
	}
	assert false, 'validate must reject GitHub provider shape without resolving credentials'
}

fn test_validate_workflow_accepts_github_mapping_without_live_credentials() {
	dir := os.join_path(os.temp_dir(), 'symphony-app-github-valid-${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path,
		'---\ntracker:\n  kind: github\n  provider:\n    repository: octo/example\n    token: $SYMPHONY_TEST_UNUSED_GITHUB_TOKEN\n    state_labels:\n      Todo: status:todo\n      In Progress: status:in-progress\n    closed_state: Closed\n  active_states:\n    - Todo\n    - In Progress\n  terminal_states:\n    - Closed\n---\nWork on {{ issue.identifier }}')!

	definition := validate_workflow(path) or { panic(err) }

	assert definition.config.tracker.kind == 'github'
}

fn test_execute_loads_explicit_env_before_doctor_tracker_validation() {
	dir := os.join_path(os.temp_dir(), 'symphony-app-env-test-${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	key_name := 'SYMPHONY_APP_DOTENV_KEY_${os.getpid()}'
	os.unsetenv(key_name)
	defer {
		os.unsetenv(key_name)
	}
	env_path := os.join_path(dir, 'development.env')
	os.write_file(env_path, '${key_name}=loaded-secret')!
	workflow_path := os.join_path(dir, 'WORKFLOW.md')
	workflow_source := '---\ntracker:\n  kind: linear\n  provider:\n    api_key: $' + key_name +
		'\n    project_slug: dotenv-test\nworkspace:\n  root: ./workspaces\ncodex:\n  command: /bin/sh\n---\nWork on {{ issue.identifier }}'
	os.write_file(workflow_path, workflow_source)!
	code := execute(['doctor', workflow_path, '--env', env_path])!
	assert code == 0
	assert os.getenv(key_name) == 'loaded-secret'
}

fn test_doctor_accepts_file_tracker_without_linear_credentials() {
	dir := os.join_path(os.temp_dir(), 'symphony-app-file-test-${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'tickets'))!
	defer {
		os.rmdir_all(dir) or {}
	}
	os.unsetenv('LINEAR_API_KEY')
	workflow_path := os.join_path(dir, 'WORKFLOW.md')
	workflow_source := '---\ntracker:\n  kind: file\n  provider:\n    root: ./tickets\nworkspace:\n  root: ./workspaces\ncodex:\n  command: /bin/sh\n---\nWork on {{ issue.identifier }}'
	os.write_file(workflow_path, workflow_source)!

	checks := doctor(workflow_path)!
	tracker_check := checks.filter(it.name == 'tracker')[0]

	assert tracker_check.ok
	assert tracker_check.detail == 'file adapter is configured'
}

fn test_run_once_accepts_file_tracker_with_empty_queue() {
	dir := os.join_path(os.temp_dir(), 'symphony-app-file-run-test-${os.getpid()}')
	os.mkdir_all(os.join_path(dir, 'tickets'))!
	defer {
		os.rmdir_all(dir) or {}
	}
	workflow_path := os.join_path(dir, 'WORKFLOW.md')
	workflow_source := '---\ntracker:\n  kind: file\n  provider:\n    root: ./tickets\n  active_states:\n    - Todo\nworkspace:\n  root: ./workspaces\ncodex:\n  command: /bin/sh\n---\nWork on {{ issue.identifier }}'
	os.write_file(workflow_path, workflow_source)!

	run(Options{
		workflow_path: workflow_path
		once:          true
	})!
}

fn test_help_and_version_do_not_load_explicit_env_files() {
	missing := os.join_path(os.temp_dir(), 'missing-symphony-env-${os.getpid()}')
	load_command_environment(Options{
		command:      .help
		env_path:     missing
		env_explicit: true
	})!
	load_command_environment(Options{
		command:      .version
		env_path:     missing
		env_explicit: true
	})!
}
