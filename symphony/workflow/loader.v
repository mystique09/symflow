module workflow

import os
import yaml

pub struct WorkflowDefinition {
pub:
	path             string
	config           Config
	prompt_template  string
	raw_front_matter string
}

struct ParsedSource {
	front_matter     string
	prompt           string
	has_front_matter bool
}

struct RawCodexConfig {
	command             string = 'codex app-server'
	approval_policy     yaml.Any
	thread_sandbox      string = 'workspace-write'
	turn_sandbox_policy yaml.Any
	turn_timeout_ms     int = 3_600_000
	read_timeout_ms     int = 5_000
	stall_timeout_ms    int = 300_000
}

struct RawConfig {
	tracker   TrackerConfig
	polling   PollingConfig
	workspace WorkspaceConfig
	hooks     HooksConfig
	agent     AgentConfig
	codex     RawCodexConfig
	server    ServerConfig
}

fn split_source(content string) !ParsedSource {
	normalized := content.replace('\r\n', '\n').replace('\r', '\n')
	lines := normalized.split('\n')
	if lines.len == 0 || lines[0].trim_space() != '---' {
		return ParsedSource{
			prompt: normalized.trim_space()
		}
	}
	mut end := -1
	for index := 1; index < lines.len; index++ {
		if lines[index].trim_space() == '---' {
			end = index
			break
		}
	}
	if end < 0 {
		return error('workflow_parse_error: YAML front matter is missing its closing delimiter')
	}
	return ParsedSource{
		front_matter:     lines[1..end].join('\n')
		prompt:           lines[end + 1..].join('\n').trim_space()
		has_front_matter: true
	}
}

pub fn load(path string, mode ValidationMode) !WorkflowDefinition {
	absolute_path := os.real_path(path)
	content := os.read_file(absolute_path) or {
		return error('missing_workflow_file: unable to read `${absolute_path}`')
	}
	parsed := split_source(content)!
	mut raw := Config{}
	if parsed.has_front_matter && parsed.front_matter.trim_space() != '' {
		document := yaml.parse_text(parsed.front_matter) or {
			return error('workflow_parse_error: invalid YAML front matter: ${err.msg()}')
		}
		if document.root !is map[string]yaml.Any {
			return error('workflow_front_matter_not_a_map: YAML front matter must be an object')
		}
		decoded := yaml.decode[RawConfig](parsed.front_matter) or {
			return error('workflow_parse_error: unable to decode workflow config: ${err.msg()}')
		}
		raw = raw_config(decoded)
	}
	config := normalize_config(raw, os.dir(absolute_path), mode)!
	return WorkflowDefinition{
		path:             absolute_path
		config:           config
		prompt_template:  parsed.prompt
		raw_front_matter: parsed.front_matter
	}
}

fn raw_config(value RawConfig) Config {
	return Config{
		tracker:   value.tracker
		polling:   value.polling
		workspace: value.workspace
		hooks:     value.hooks
		agent:     value.agent
		codex:     CodexConfig{
			command:             value.codex.command
			approval_policy:     yaml_json_or(value.codex.approval_policy, 'never')
			thread_sandbox:      value.codex.thread_sandbox
			turn_sandbox_policy: yaml_json_or(value.codex.turn_sandbox_policy, 'workspaceWrite')
			turn_timeout_ms:     value.codex.turn_timeout_ms
			read_timeout_ms:     value.codex.read_timeout_ms
			stall_timeout_ms:    value.codex.stall_timeout_ms
		}
		server:    value.server
	}
}

fn yaml_json_or(value yaml.Any, fallback string) string {
	return match value {
		yaml.Null {
			fallback
		}
		string {
			value
		}
		[]yaml.Any {
			if value.len == 0 {
				fallback
			} else {
				yaml.Any(value).to_json()
			}
		}
		else {
			value.to_json()
		}
	}
}

pub struct WorkflowStore {
	path string
	mode ValidationMode
mut:
	current_definition WorkflowDefinition
	has_current        bool
}

pub fn new_store(path string, mode ValidationMode) WorkflowStore {
	return WorkflowStore{
		path: path
		mode: mode
	}
}

pub fn (mut store WorkflowStore) reload() !WorkflowDefinition {
	next := load(store.path, store.mode)!
	store.current_definition = next
	store.has_current = true
	return next
}

pub fn (store &WorkflowStore) current() !WorkflowDefinition {
	if !store.has_current {
		return error('workflow_not_loaded: no valid workflow has been loaded')
	}
	return store.current_definition
}
