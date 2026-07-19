module tracker

import os
import yaml
import symphony.domain
import symphony.workflow

pub interface Tracker {
	fetch_issues_by_states(states []string) ![]domain.Issue
	fetch_issues_by_ids(ids []string) ![]domain.Issue
	record_outcome(issue domain.Issue, outcome domain.AttemptOutcome) !bool
	secret_environment_names() []string
	secret_values() []string
}

// validate_adapter_config checks provider-owned structure without resolving live credentials.
pub fn validate_adapter_config(config workflow.TrackerConfig) ! {
	match config.kind.trim_space().to_lower() {
		'file' {
			provider_string(config.provider, 'root')!
		}
		'github' {
			github_from_config(with_validation_secret(config, 'token'))!
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
		'github' { Tracker(github_from_config(config)!) }
		'linear' { Tracker(linear_from_config(config)!) }
		else { return error('unsupported_tracker_kind: `${config.kind}` is not supported') }
	}
}

fn github_from_config(config workflow.TrackerConfig) !GitHubClient {
	provider := config.provider.clone()
	mut endpoint := provider_string(provider, 'endpoint')!
	if endpoint == '' {
		endpoint = 'https://api.github.com'
	}
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
	mut closed_state := provider_string(provider, 'closed_state')!
	if closed_state == '' {
		closed_state = 'Closed'
	}
	client := GitHubClient{
		endpoint:        endpoint.trim_space().trim_right('/')
		token:           token.trim_space()
		token_env:       token_env
		repository:      provider_string(provider, 'repository')!.trim_space()
		state_labels:    provider_string_map(provider, 'state_labels')!
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
