module workflow

import os
import yaml

pub enum ValidationMode {
	syntax
	dispatch
}

pub struct TrackerConfig {
pub:
	kind            string
	provider        map[string]yaml.Any
	required_labels []string
	active_states   []string = ['Todo', 'In Progress']
	terminal_states []string = ['Closed', 'Cancelled', 'Canceled', 'Duplicate', 'Done']
}

pub struct ServerConfig {
pub:
	// -1 means disabled. Zero asks the operating system for an available port.
	port int = -1
}

pub struct PollingConfig {
pub:
	interval_ms int = 30_000
}

pub struct WorkspaceConfig {
pub:
	root string
}

pub struct HooksConfig {
pub:
	after_create  string
	before_run    string
	after_run     string
	before_remove string
	timeout_ms    int = 60_000
}

pub struct AgentConfig {
pub:
	max_concurrent_agents          int = 10
	max_turns                      int = 20
	max_retry_backoff_ms           int = 300_000
	max_concurrent_agents_by_state map[string]int
}

pub struct CodexConfig {
pub:
	command             string = 'codex app-server'
	approval_policy     string = 'never'
	thread_sandbox      string = 'workspace-write'
	turn_sandbox_policy string = 'workspaceWrite'
	turn_timeout_ms     int    = 3_600_000
	read_timeout_ms     int    = 5_000
	stall_timeout_ms    int    = 300_000
}

pub struct Config {
pub:
	tracker   TrackerConfig
	polling   PollingConfig
	workspace WorkspaceConfig
	hooks     HooksConfig
	agent     AgentConfig
	codex     CodexConfig
	server    ServerConfig
}

fn resolve_env_reference(value string) string {
	trimmed := value.trim_space()
	if trimmed.len > 1 && trimmed[0] == `$` && !trimmed[1..].contains('$') {
		return os.getenv(trimmed[1..])
	}
	return value
}

fn resolve_workspace_root(value string, workflow_dir string) !string {
	mut resolved := resolve_env_reference(value).trim_space()
	if resolved == '' {
		resolved = os.join_path(os.temp_dir(), 'symphony_workspaces')
	}
	if resolved == '~' {
		resolved = os.home_dir()
	} else if resolved.starts_with('~/') {
		resolved = os.join_path(os.home_dir(), resolved[2..])
	}
	if !os.is_abs_path(resolved) {
		resolved = os.join_path(workflow_dir, resolved)
	}
	return os.real_path(resolved)
}

fn normalize_config(raw Config, workflow_dir string, mode ValidationMode) !Config {
	workspace_root := resolve_workspace_root(raw.workspace.root, workflow_dir)!
	tracker_kind := raw.tracker.kind.trim_space().to_lower()
	tracker_provider :=
		normalize_tracker_provider(tracker_kind, raw.tracker.provider, workflow_dir)!
	mut state_limits := map[string]int{}
	for state, limit in raw.agent.max_concurrent_agents_by_state {
		if state.trim_space() != '' && limit > 0 {
			state_limits[state.trim_space().to_lower()] = limit
		}
	}
	config := Config{
		tracker:   TrackerConfig{
			kind:            tracker_kind
			provider:        tracker_provider
			required_labels: raw.tracker.required_labels.clone()
			active_states:   raw.tracker.active_states.clone()
			terminal_states: raw.tracker.terminal_states.clone()
		}
		polling:   PollingConfig{
			interval_ms: raw.polling.interval_ms
		}
		workspace: WorkspaceConfig{
			root: workspace_root
		}
		hooks:     raw.hooks
		agent:     AgentConfig{
			max_concurrent_agents:          raw.agent.max_concurrent_agents
			max_turns:                      raw.agent.max_turns
			max_retry_backoff_ms:           raw.agent.max_retry_backoff_ms
			max_concurrent_agents_by_state: state_limits
		}
		codex:     CodexConfig{
			...raw.codex
			command: raw.codex.command.trim_space()
		}
		server:    raw.server
	}
	validate_config(config, mode)!
	return config
}

fn normalize_tracker_provider(kind string, raw map[string]yaml.Any, workflow_dir string) !map[string]yaml.Any {
	mut provider := raw.clone()
	if kind != 'file' {
		return provider
	}
	value := provider['root'] or { return provider }
	mut root := ''
	if value is string {
		root = value.trim_space()
	} else {
		return error('workflow_config_error: tracker.provider.root must be a string')
	}
	if root == '~' {
		root = os.home_dir()
	} else if root.starts_with('~/') {
		root = os.join_path(os.home_dir(), root[2..])
	}
	if root != '' && !os.is_abs_path(root) {
		root = os.join_path(workflow_dir, root)
	}
	if root != '' {
		provider['root'] = yaml.Any(os.real_path(root))
	}
	return provider
}

pub fn validate_config(config Config, mode ValidationMode) ! {
	if config.polling.interval_ms <= 0 {
		return error('workflow_config_error: polling.interval_ms must be positive')
	}
	if config.hooks.timeout_ms <= 0 {
		return error('workflow_config_error: hooks.timeout_ms must be positive')
	}
	if config.agent.max_concurrent_agents <= 0 {
		return error('workflow_config_error: agent.max_concurrent_agents must be positive')
	}
	if config.agent.max_turns <= 0 {
		return error('workflow_config_error: agent.max_turns must be positive')
	}
	if config.agent.max_retry_backoff_ms <= 0 {
		return error('workflow_config_error: agent.max_retry_backoff_ms must be positive')
	}
	if config.codex.command == '' {
		return error('workflow_config_error: codex.command is required')
	}
	if config.codex.turn_timeout_ms <= 0 || config.codex.read_timeout_ms <= 0 {
		return error('workflow_config_error: Codex turn and read timeouts must be positive')
	}
	if mode == .dispatch {
		if config.tracker.kind == '' {
			return error('workflow_config_error: tracker.kind is required for dispatch')
		}
	}
	if config.server.port < -1 || config.server.port > 65_535 {
		return error('workflow_config_error: server.port must be -1, 0, or a valid TCP port')
	}
}
