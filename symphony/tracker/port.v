module tracker

import os
import yaml
import symphony.domain
import symphony.workflow

pub interface Tracker {
	fetch_issues_by_states(states []string) ![]domain.Issue
	fetch_issues_by_ids(ids []string) ![]domain.Issue
	fetch_completed_issues(terminal_states []string) ![]domain.Issue
	record_outcome(issue domain.Issue, outcome domain.AttemptOutcome) !bool
	secret_environment_names() []string
	secret_values() []string
	validate_scope() !
}

// validate_adapter_config checks provider-owned structure without resolving live credentials.
pub fn validate_adapter_config(config workflow.TrackerConfig) ! {
	match config.kind.trim_space().to_lower() {
		'file' {
			provider_string(config.provider, 'root')!
		}
		'github' {
			new_github_adapter(with_validation_secret(config, 'token'))!
		}
		'linear' {
			linear_from_config(with_validation_secret(config, 'api_key'))!
		}
		else {}
	}
}

pub fn new_adapter(config workflow.TrackerConfig) !Tracker {
	return match config.kind.trim_space().to_lower() {
		'file' { Tracker(file_from_config(config)!) }
		'github' { new_github_adapter(config)! }
		'linear' { Tracker(linear_from_config(config)!) }
		else { return error('unsupported_tracker_kind: `${config.kind}` is not supported') }
	}
}

// activate_adapter verifies the provider-owned scope before it becomes effective.
pub fn activate_adapter(config workflow.TrackerConfig) !Tracker {
	client := new_adapter(config)!
	client.validate_scope()!
	return client
}

fn new_github_adapter(config workflow.TrackerConfig) !Tracker {
	return Tracker(github_project_from_config(config)!)
}

fn github_project_from_config(config workflow.TrackerConfig) !GitHubProjectClient {
	provider := config.provider.clone()
	mut endpoint := provider_string(provider, 'endpoint')!
	if endpoint == '' {
		endpoint = 'https://api.github.com/graphql'
	}
	token, token_env := github_token(provider)!
	mut owner_type := provider_string(provider, 'owner_type')!
	if owner_type == '' {
		owner_type = 'organization'
	}
	mut status_field := provider_string(provider, 'status_field')!
	if status_field == '' {
		status_field = 'Status'
	}
	mut closed_state := provider_string(provider, 'closed_state')!
	if closed_state == '' {
		closed_state = 'Closed'
	}
	client := GitHubProjectClient{
		endpoint:        endpoint.trim_space().trim_right('/')
		token:           token
		token_env:       token_env
		owner_type:      owner_type.trim_space().to_lower()
		owner:           provider_string(provider, 'owner')!.trim_space()
		project_number:  provider_int(provider, 'project_number')!
		status_field:    status_field.trim_space()
		state_options:   provider_string_map(provider, 'state_options')!
		closed_state:    closed_state.trim_space()
		write_outcomes:  provider_bool(provider, 'write_outcomes')!
		success_state:   provider_string(provider, 'success_state')!.trim_space()
		blocked_state:   provider_string(provider, 'blocked_state')!.trim_space()
		active_states:   config.active_states.clone()
		terminal_states: config.terminal_states.clone()
	}
	client.validate()!
	return client
}

fn github_token(provider map[string]yaml.Any) !(string, string) {
	token_source := provider_string(provider, 'token')!
	mut token_env := ''
	mut token := token_source
	if token_source == '' {
		token_env = 'GITHUB_TOKEN'
		token = os.getenv(token_env)
	} else if token_source.starts_with('$') && token_source.len > 1
		&& !token_source[1..].contains('$') {
		token_env = token_source[1..]
		token = os.getenv(token_env)
	}
	return token.trim_space(), token_env
}

fn file_from_config(config workflow.TrackerConfig) !FileClient {
	root := provider_string(config.provider, 'root')!
	return new_file_client_with_terminal_states(root, config.terminal_states)
}

fn linear_from_config(config workflow.TrackerConfig) !LinearClient {
	provider := config.provider.clone()
	mut endpoint := provider_string(provider, 'endpoint')!
	if endpoint == '' {
		endpoint = 'https://api.linear.app/graphql'
	}
	key_source := provider_string(provider, 'api_key')!
	mut api_key_env := ''
	mut api_key := key_source
	if key_source == '' {
		api_key_env = 'LINEAR_API_KEY'
		api_key = os.getenv(api_key_env)
	} else if key_source.starts_with('$') && key_source.len > 1 && !key_source[1..].contains('$') {
		api_key_env = key_source[1..]
		api_key = os.getenv(api_key_env)
	}
	project_slug := provider_string(provider, 'project_slug')!
	team_key := provider_string(provider, 'team_key')!
	assignee := provider_string(provider, 'assignee')!
	client := LinearClient{
		endpoint:        endpoint.trim_space()
		api_key:         api_key.trim_space()
		api_key_env:     api_key_env
		project_slug:    project_slug.trim_space()
		team_key:        team_key.trim_space()
		assignee:        assignee.trim_space()
		active_states:   config.active_states.clone()
		terminal_states: config.terminal_states.clone()
	}
	client.validate()!
	return client
}

fn provider_string(provider map[string]yaml.Any, key string) !string {
	value := provider[key] or { return '' }
	if value is string {
		return value
	}
	return error('invalid_tracker_config: tracker.provider.${key} must be a string')
}

fn provider_string_map(provider map[string]yaml.Any, key string) !map[string]string {
	value := provider[key] or { return map[string]string{} }
	if value !is map[string]yaml.Any {
		return error('invalid_tracker_config: tracker.provider.${key} must be a map')
	}
	mut result := map[string]string{}
	for entry_key, entry_value in value.as_map() {
		if entry_value !is string {
			return error('invalid_tracker_config: tracker.provider.${key}.${entry_key} must be a string')
		}
		result[entry_key] = entry_value.str()
	}
	return result
}

fn provider_bool(provider map[string]yaml.Any, key string) !bool {
	value := provider[key] or { return false }
	if value is bool {
		return value
	}
	return error('invalid_tracker_config: tracker.provider.${key} must be a boolean')
}

fn provider_int(provider map[string]yaml.Any, key string) !int {
	value := provider[key] or { return 0 }
	if value is int {
		return value
	}
	if value is i64 {
		return int(value)
	}
	if value is u64 && value <= u64(2_147_483_647) {
		return int(value)
	}
	if value is f64 {
		integer := int(value)
		if value >= 0 && value <= 2_147_483_647 && value == f64(integer) {
			return integer
		}
	}
	return error('invalid_tracker_config: tracker.provider.${key} must be an integer')
}

fn with_validation_secret(config workflow.TrackerConfig, key string) workflow.TrackerConfig {
	mut provider := config.provider.clone()
	if value := provider[key] {
		if value is string {
			provider[key] = yaml.Any('validation-placeholder')
		}
	} else {
		provider[key] = yaml.Any('validation-placeholder')
	}
	return workflow.TrackerConfig{
		...config
		provider: provider
	}
}
