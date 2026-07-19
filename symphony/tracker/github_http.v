module tracker

import json2
import net.http
import time

pub struct GitHubRequest {
pub:
	method string
	url    string
	token  string
	body   string
}

pub struct GitHubResponse {
pub:
	status       int
	body         string
	rate_limited bool
}

pub type GitHubTransport = fn (request GitHubRequest) !GitHubResponse

fn default_github_transport(request GitHubRequest) !GitHubResponse {
	if request.method != 'POST' {
		return error('unsupported GitHub HTTP method')
	}
	mut header := http.new_header()
	header.add_custom('Accept', 'application/vnd.github+json')!
	header.add_custom('Authorization', 'Bearer ${request.token}')!
	header.add_custom('X-GitHub-Api-Version', '2022-11-28')!
	header.add_custom('User-Agent', 'symphony-tracker')!
	header.add_custom('Content-Type', 'application/json')!
	response := http.fetch(
		url:                  request.url
		method:               .post
		header:               header
		data:                 request.body
		read_timeout:         i64(30 * time.second)
		write_timeout:        i64(30 * time.second)
		stop_receiving_limit: 8 * 1024 * 1024
		allow_redirect:       false
	) or { return error('GitHub HTTP request failed') }
	remaining := response.header.get_custom('X-RateLimit-Remaining', http.HeaderQueryConfig{}) or {
		''
	}
	retry_after := response.header.get_custom('Retry-After', http.HeaderQueryConfig{}) or { '' }
	return GitHubResponse{
		status:       response.status_code
		body:         response.body
		rate_limited: github_is_rate_limited(response.status_code, remaining, retry_after,
			response.body)
	}
}

fn github_is_rate_limited(status int, remaining string, retry_after string, body string) bool {
	if status != 403 {
		return false
	}
	if remaining.trim_space() == '0' || retry_after.trim_space() != '' {
		return true
	}
	decoded := json2.decode[json2.Any](body) or { return false }
	if decoded !is map[string]json2.Any {
		return false
	}
	root := decoded.as_map()
	message := string_value(root, 'message').to_lower()
	documentation_url := string_value(root, 'documentation_url').to_lower()
	return message.contains('rate limit') && (documentation_url.contains('rate-limit')
		|| documentation_url.contains('secondary-rate-limits'))
}

fn github_issue_id(repository string, number int) string {
	return 'github:${repository}#${number}'
}

fn github_int_value(values map[string]json2.Any, key string) int {
	value := values[key] or { return -1 }
	return value.int()
}

fn validate_github_repository(repository string) ! {
	parts := repository.trim_space().split('/')
	if parts.len != 2 || !valid_github_owner(parts[0]) || !valid_github_repo_name(parts[1]) {
		return error('invalid_tracker_config: GitHub repository must use `owner/name` syntax')
	}
}

fn valid_github_owner(value string) bool {
	if value == '' || value.starts_with('-') || value.ends_with('-') {
		return false
	}
	for character in value.bytes() {
		if !ascii_alphanumeric(character) && character != `-` {
			return false
		}
	}
	return true
}

fn valid_github_repo_name(value string) bool {
	if value == '' || value == '.' || value == '..' {
		return false
	}
	for character in value.bytes() {
		if !ascii_alphanumeric(character) && character !in [u8(`-`), `_`, `.`] {
			return false
		}
	}
	return true
}

fn ascii_alphanumeric(value u8) bool {
	return (value >= `a` && value <= `z`) || (value >= `A` && value <= `Z`)
		|| (value >= `0` && value <= `9`)
}
