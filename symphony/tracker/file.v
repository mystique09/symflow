module tracker

import json2
import os
import time
import yaml
import symphony.domain

const max_ticket_bytes = 1_048_576
const max_ticket_files = 10_000

// FileClient reads provider-neutral issues from a bounded Markdown directory.
pub struct FileClient {
	root            string
	terminal_states []string
}

struct FileBlocker {
	id         string
	identifier string
	state      string
	created_at string
	updated_at string
}

struct FileTicketMetadata {
	schema_version    int
	id                string
	identifier        string
	title             string
	state             string
	priority          int = -1
	labels            []string
	branch_name       string
	source_url        string
	assignee_id       string
	assignee_name     string
	parent_identifier string
	created_at        string
	updated_at        string
	dispatch_status   string
	last_error        string
	completed_at      string
	blocked_by        []FileBlocker
}

struct ParsedFileTicket {
	path         string
	front_matter string
	body         string
	metadata     FileTicketMetadata
}

// new_file_client validates and resolves a local ticket directory.
pub fn new_file_client(root string) !FileClient {
	return new_file_client_with_terminal_states(root, ['Closed', 'Cancelled', 'Canceled', 'Duplicate',
		'Done'])
}

fn new_file_client_with_terminal_states(root string, terminal_states []string) !FileClient {
	trimmed := root.trim_space()
	if trimmed == '' {
		return error('file_tracker_config_error: tracker.provider.root is required')
	}
	resolved := os.real_path(trimmed)
	if !os.is_dir(resolved) {
		return error('file_tracker_directory_error: `${resolved}` is not a readable directory')
	}
	return FileClient{
		root:            resolved
		terminal_states: terminal_states.clone()
	}
}

// fetch_issues_by_states returns pending tickets in configured provider states.
pub fn (client FileClient) fetch_issues_by_states(states []string) ![]domain.Issue {
	if states.len == 0 {
		return []domain.Issue{}
	}
	wanted := states.map(domain.normalize_name(it))
	snapshot := client.load_snapshot()!
	mut issues := []domain.Issue{}
	for ticket in snapshot {
		if ticket.metadata.dispatch_status == 'pending'
			&& domain.normalize_name(ticket.metadata.state) in wanted {
			issues << issue_from_file_ticket(ticket, client.terminal_states)
		}
	}
	return issues
}

// fetch_completed_issues returns durable file-backed completion history.
pub fn (client FileClient) fetch_completed_issues(_ []string) ![]domain.Issue {
	snapshot := client.load_snapshot()!
	mut issues := []domain.Issue{}
	for ticket in snapshot {
		if ticket.metadata.dispatch_status == 'completed' {
			issues << issue_from_file_ticket(ticket, client.terminal_states)
		}
	}
	return issues
}

// fetch_issues_by_ids returns tickets in requested identity order.
pub fn (client FileClient) fetch_issues_by_ids(ids []string) ![]domain.Issue {
	if ids.len == 0 {
		return []domain.Issue{}
	}
	snapshot := client.load_snapshot()!
	mut by_id := map[string]domain.Issue{}
	for ticket in snapshot {
		by_id[ticket.metadata.id] = issue_from_file_ticket(ticket, client.terminal_states)
	}
	mut issues := []domain.Issue{}
	mut seen := map[string]bool{}
	for id in ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		if issue := by_id[id] {
			issues << issue
		}
	}
	return issues
}

// secret_environment_names reports that file mode has no tracker credentials.
pub fn (client FileClient) secret_environment_names() []string {
	return []string{}
}

// secret_values reports that file mode has no values requiring redaction.
pub fn (client FileClient) secret_values() []string {
	return []string{}
}

// validate_scope confirms that the directory validated during construction remains available.
pub fn (client FileClient) validate_scope() ! {
	if !os.is_dir(client.root) {
		return error('file_tracker_directory_error: configured ticket directory is unavailable')
	}
}

// record_outcome persists dispatch-owned ticket metadata.
// A true result means successful completion was stored and continuation can stop.
pub fn (client FileClient) record_outcome(issue domain.Issue, outcome domain.AttemptOutcome) !bool {
	if issue.id == '' || outcome.issue_id != issue.id {
		return error('file_tracker_outcome_error: outcome identity does not match the ticket')
	}
	snapshot := client.load_snapshot()!
	mut found := false
	mut ticket := ParsedFileTicket{}
	for candidate in snapshot {
		if candidate.metadata.id == issue.id {
			ticket = candidate
			found = true
			break
		}
	}
	if !found {
		return error('file_tracker_outcome_error: ticket `${issue.identifier}` is no longer present')
	}
	mut status := ticket.metadata.dispatch_status
	mut last_error := ''
	mut completed_at := ''
	mut completed := false
	match outcome.kind {
		.succeeded {
			status = 'completed'
			completed_at = time.utc().format_rfc3339()
			completed = true
		}
		.blocked {
			status = 'blocked'
			last_error = bounded_file_message(outcome.error_message)
		}
		.failed, .timed_out, .stalled, .process_exited {
			status = 'pending'
			last_error = bounded_file_message(outcome.error_message)
		}
		.canceled {
			status = 'pending'
		}
	}
	mut front_matter := replace_frontmatter_scalar(ticket.front_matter, 'dispatch_status', status)
	front_matter = replace_frontmatter_scalar(front_matter, 'last_error', json2.encode(last_error))
	front_matter = replace_frontmatter_scalar(front_matter, 'completed_at',
		json2.encode(completed_at))
	content := '---\n${front_matter}\n---\n\n${ticket.body}\n'
	client.atomic_replace(ticket.path, content)!
	return completed
}

fn (client FileClient) atomic_replace(path string, content string) ! {
	resolved := os.real_path(path)
	if os.dir(resolved) != client.root || !os.is_file(resolved) {
		return error('file_tracker_path_error: ticket update target is unsafe')
	}
	temp_path := '${path}.tmp-${os.getpid()}-${time.now().unix_micro()}'
	mut renamed := false
	defer {
		if !renamed {
			os.rm(temp_path) or {}
		}
	}
	os.write_file(temp_path, content) or {
		return error('file_tracker_file_error: unable to write temporary ticket update')
	}
	os.chmod(temp_path, 0o600) or {
		return error('file_tracker_file_error: unable to protect temporary ticket update')
	}
	os.rename(temp_path, path) or {
		return error('file_tracker_file_error: unable to replace ticket atomically')
	}
	renamed = true
}

fn replace_frontmatter_scalar(front_matter string, key string, scalar string) string {
	mut lines := front_matter.split('\n')
	prefix := '${key}:'
	for index, line in lines {
		if line == line.trim_left(' \t') && line.starts_with(prefix) {
			lines[index] = '${key}: ${scalar}'
			return lines.join('\n')
		}
	}
	lines << '${key}: ${scalar}'
	return lines.join('\n')
}

fn bounded_file_message(value string) string {
	return if value.len <= 8 * 1024 { value } else { value[..8 * 1024] }
}

fn (client FileClient) load_snapshot() ![]ParsedFileTicket {
	mut filenames := os.ls(client.root) or {
		return error('file_tracker_directory_error: unable to read `${client.root}`')
	}
	filenames = filenames.filter(it.to_lower().ends_with('.md'))
	filenames.sort()
	if filenames.len > max_ticket_files {
		return error('file_tracker_limit_error: `${client.root}` contains more than 10000 Markdown tickets')
	}
	mut tickets := []ParsedFileTicket{cap: filenames.len}
	mut ids := map[string]string{}
	mut identifiers := map[string]string{}
	for filename in filenames {
		path := os.join_path(client.root, filename)
		resolved := os.real_path(path)
		if os.dir(resolved) != client.root || !os.is_file(resolved) {
			return error('file_tracker_path_error: `${filename}` is not a safe direct ticket file')
		}
		if os.file_size(resolved) > max_ticket_bytes {
			return error('file_tracker_limit_error: `${filename}` exceeds 1 MiB')
		}
		content := os.read_file(resolved) or {
			return error('file_tracker_file_error: unable to read `${filename}`')
		}
		ticket := parse_file_ticket(resolved, content)!
		if previous := ids[ticket.metadata.id] {
			return error('file_tracker_duplicate_error: `${filename}` duplicates id from `${os.file_name(previous)}`')
		}
		if previous := identifiers[ticket.metadata.identifier] {
			return error('file_tracker_duplicate_error: `${filename}` duplicates identifier from `${os.file_name(previous)}`')
		}
		ids[ticket.metadata.id] = resolved
		identifiers[ticket.metadata.identifier] = resolved
		tickets << ticket
	}
	return tickets
}

fn parse_file_ticket(path string, content string) !ParsedFileTicket {
	filename := os.file_name(path)
	normalized := content.replace('\r\n', '\n').replace('\r', '\n')
	lines := normalized.split('\n')
	if lines.len == 0 || lines[0].trim_space() != '---' {
		return error('file_tracker_parse_error: `${filename}` must start with YAML frontmatter')
	}
	mut closing := -1
	for index := 1; index < lines.len; index++ {
		if lines[index].trim_space() == '---' {
			closing = index
			break
		}
	}
	if closing < 0 {
		return error('file_tracker_parse_error: `${filename}` is missing its closing frontmatter delimiter')
	}
	front_matter := lines[1..closing].join('\n')
	metadata := yaml.decode[FileTicketMetadata](front_matter) or {
		return error('file_tracker_parse_error: `${filename}` has invalid YAML frontmatter')
	}
	validate_file_metadata(filename, metadata)!
	return ParsedFileTicket{
		path:         path
		front_matter: front_matter
		body:         lines[closing + 1..].join('\n').trim_space()
		metadata:     FileTicketMetadata{
			...metadata
			id:              metadata.id.trim_space()
			identifier:      metadata.identifier.trim_space()
			title:           metadata.title.trim_space()
			state:           metadata.state.trim_space()
			dispatch_status: metadata.dispatch_status.trim_space().to_lower()
		}
	}
}

fn validate_file_metadata(filename string, metadata FileTicketMetadata) ! {
	if metadata.schema_version != 1 {
		return error('file_tracker_schema_error: `${filename}` requires schema_version 1')
	}
	if metadata.id.trim_space() == '' || metadata.identifier.trim_space() == ''
		|| metadata.title.trim_space() == '' || metadata.state.trim_space() == '' {
		return error('file_tracker_parse_error: `${filename}` is missing a required ticket field')
	}
	status := metadata.dispatch_status.trim_space().to_lower()
	if status !in ['pending', 'completed', 'blocked'] {
		return error('file_tracker_status_error: `${filename}` has an invalid dispatch_status')
	}
}

fn issue_from_file_ticket(ticket ParsedFileTicket, terminal_states []string) domain.Issue {
	metadata := ticket.metadata
	mut blockers := []domain.BlockerRef{}
	for blocker in metadata.blocked_by {
		blockers << domain.BlockerRef{
			id:         blocker.id
			identifier: blocker.identifier
			state:      blocker.state
			created_at: blocker.created_at
			updated_at: blocker.updated_at
		}
	}
	mut issue := domain.Issue{
		id:           metadata.id
		identifier:   metadata.identifier
		title:        metadata.title
		description:  ticket.body
		priority:     metadata.priority
		state:        metadata.state
		branch_name:  metadata.branch_name
		url:          metadata.source_url
		labels:       domain.normalize_labels(metadata.labels)
		blocked_by:   blockers
		created_at:   metadata.created_at
		updated_at:   metadata.updated_at
		completed_at: metadata.completed_at
		assignee_id:  metadata.assignee_id
		native_ref:   {
			'file_path': json2.Any(ticket.path)
		}
		dispatchable: metadata.dispatch_status == 'pending'
	}
	issue = domain.Issue{
		...issue
		dispatchable: issue.dispatchable
			&& (issue.normalized_state() != 'todo' || !issue.has_open_blockers(terminal_states))
	}
	return issue
}
