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

pub fn new_adapter(config workflow.TrackerConfig) !Tracker {
	return match config.kind.trim_space().to_lower() {
		'file' { Tracker(file_from_config(config)!) }
		'linear' { Tracker(linear_from_config(config)!) }
		else { return error('unsupported_tracker_kind: `${config.kind}` is not supported') }
	}
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
	assignee := provider_string(provider, 'assignee')!
	client := LinearClient{
		endpoint:        endpoint.trim_space()
		api_key:         api_key.trim_space()
		api_key_env:     api_key_env
		project_slug:    project_slug.trim_space()
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
