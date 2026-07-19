module workflow

import os
import time
import json2

fn temp_workflow_dir() string {
	path := os.join_path(os.vtmp_dir(), 'symphony_workflow_${time.now().unix_micro()}')
	os.mkdir_all(path) or { panic(err) }
	return path
}

fn test_markdown_only_workflow_uses_defaults() {
	dir := temp_workflow_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path, '  Work on {{ issue.identifier }}.  \n') or { panic(err) }
	definition := load(path, .syntax) or { panic(err) }
	assert definition.prompt_template == 'Work on {{ issue.identifier }}.'
	assert definition.config.polling.interval_ms == 30_000
	assert definition.config.agent.max_concurrent_agents == 10
	assert definition.config.tracker.active_states == ['Todo', 'In Progress']
	assert definition.config.workspace.root == os.real_path(os.join_path(os.temp_dir(),
		'symphony_workspaces'))
	assert definition.config.workspace.base_branch == 'main'
}

fn test_front_matter_decodes_and_resolves_relative_workspace() {
	dir := temp_workflow_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path,
		'---\ntracker:\n  kind: linear\n  provider:\n    project_slug: demo\n    endpoint: https://linear.test/graphql\n    extension:\n      enabled: true\npolling:\n  interval_ms: 2500\nworkspace:\n  root: ./runs\n  base_branch: staging\nserver:\n  port: 9191\n---\nHello') or {
		panic(err)
	}
	definition := load(path, .syntax) or { panic(err) }
	assert definition.config.tracker.kind == 'linear'
	provider := definition.config.tracker.provider.clone()
	assert (provider['project_slug'] or { panic('project_slug') }).str() == 'demo'
	assert (provider['endpoint'] or { panic('endpoint') }).str() == 'https://linear.test/graphql'
	extension := (provider['extension'] or { panic('extension') }).as_map()
	assert (extension['enabled'] or { panic('enabled') }).bool()
	assert definition.config.polling.interval_ms == 2500
	assert definition.config.server.port == 9191
	assert definition.config.codex.approval_policy == 'never'
	assert definition.config.codex.turn_sandbox_policy == 'workspaceWrite'
	assert definition.config.workspace.root == os.real_path(os.join_path(os.real_path(dir), 'runs'))
	assert definition.config.workspace.base_branch == 'staging'
}

fn test_file_tracker_root_resolves_relative_to_workflow() {
	dir := temp_workflow_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	os.mkdir_all(os.join_path(dir, 'tickets'))!
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path,
		'---\ntracker:\n  kind: file\n  provider:\n    root: ./tickets\n---\nLocal prompt')!

	definition := load(path, .dispatch)!
	root := definition.config.tracker.provider['root'] or { panic('root') }

	assert root.str() == os.real_path(os.join_path(dir, 'tickets'))
}

fn test_front_matter_must_be_a_map() {
	dir := temp_workflow_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path, '---\n- not\n- a map\n---\nPrompt') or { panic(err) }
	load(path, .syntax) or {
		assert err.msg().contains('workflow_front_matter_not_a_map')
		return
	}
	assert false, 'non-map front matter should fail'
}

fn test_dispatch_validation_resolves_secret_without_leaking_it() {
	dir := temp_workflow_dir()
	defer {
		os.rmdir_all(dir) or {}
		os.unsetenv('SYMPHONY_TEST_LINEAR_KEY')
	}
	os.setenv('SYMPHONY_TEST_LINEAR_KEY', 'very-secret-token', true)
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path,
		'---\ntracker:\n  kind: linear\n  provider:\n    api_key: $SYMPHONY_TEST_LINEAR_KEY\n    project_slug: demo\n---\nPrompt') or {
		panic(err)
	}
	definition := load(path, .dispatch) or { panic(err) }
	assert (definition.config.tracker.provider['api_key'] or { panic('api_key') }).str() == '$SYMPHONY_TEST_LINEAR_KEY'

	os.unsetenv('SYMPHONY_TEST_LINEAR_KEY')
	load(path, .dispatch) or {
		panic('generic workflow validation must not resolve provider credentials: ${err.msg()}')
	}
}

fn test_dispatch_validation_requires_a_tracker_kind_but_not_a_specific_provider() {
	dir := temp_workflow_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path, '---\ntracker:\n  kind: custom-provider\n---\nPrompt') or { panic(err) }
	definition := load(path, .dispatch) or { panic(err) }
	assert definition.config.tracker.kind == 'custom-provider'
}

fn test_codex_schema_owned_policy_objects_are_preserved_as_json() {
	dir := temp_workflow_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path,
		'---\ncodex:\n  approval_policy:\n    granular:\n      mcp_elicitation: never\n  turn_sandbox_policy:\n    type: workspaceWrite\n    networkAccess: false\n    excludeSlashTmp: true\n---\nPrompt') or {
		panic(err)
	}
	definition := load(path, .syntax) or { panic(err) }
	approval :=
		json2.decode[json2.Any](definition.config.codex.approval_policy) or { panic(err) }.as_map()
	granular := (approval['granular'] or { panic('granular') }).as_map()
	assert (granular['mcp_elicitation'] or { panic('mcp_elicitation') }).str() == 'never'
	sandbox := json2.decode[json2.Any](definition.config.codex.turn_sandbox_policy) or {
		panic(err)
	}.as_map()
	assert (sandbox['type'] or { panic('type') }).str() == 'workspaceWrite'
	assert !(sandbox['networkAccess'] or { panic('networkAccess') }).bool()
	assert (sandbox['excludeSlashTmp'] or { panic('excludeSlashTmp') }).bool()
}

fn test_invalid_reload_preserves_last_known_good_workflow() {
	dir := temp_workflow_dir()
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'WORKFLOW.md')
	os.write_file(path, '---\npolling:\n  interval_ms: 1000\n---\nFirst') or { panic(err) }
	mut store := new_store(path, .syntax)
	first := store.reload() or { panic(err) }
	assert first.config.polling.interval_ms == 1000

	os.write_file(path, '---\npolling: [broken\n---\nSecond') or { panic(err) }
	store.reload() or {
		current := store.current() or { panic(err) }
		assert current.prompt_template == 'First'
		assert current.config.polling.interval_ms == 1000
		return
	}
	assert false, 'invalid reload should fail'
}
