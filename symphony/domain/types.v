module domain

import json2

pub struct BlockerRef {
pub:
	id         string
	identifier string
	state      string
	created_at string
	updated_at string
}

pub struct Issue {
pub:
	id          string
	identifier  string
	title       string
	description string
	priority    int = -1
	// queue_rank preserves an adapter-owned queue order when the provider exposes one.
	queue_rank   int = -1
	state        string
	branch_name  string
	url          string
	labels       []string
	blocked_by   []BlockerRef
	created_at   string
	updated_at   string
	completed_at string
	assignee_id  string
	native_ref   map[string]json2.Any
	dispatchable bool = true
}

pub fn normalize_name(value string) string {
	return value.trim_space().to_lower()
}

pub fn normalize_labels(labels []string) []string {
	mut normalized := []string{}
	for label in labels {
		value := normalize_name(label)
		if value != '' && value !in normalized {
			normalized << value
		}
	}
	normalized.sort()
	return normalized
}

pub fn (issue Issue) normalized_state() string {
	return normalize_name(issue.state)
}

pub fn (issue Issue) normalized_labels() []string {
	return normalize_labels(issue.labels)
}

pub fn (issue Issue) has_required_labels(required []string) bool {
	available := issue.normalized_labels()
	for label in required {
		normalized := normalize_name(label)
		if normalized == '' || normalized !in available {
			return false
		}
	}
	return true
}

pub fn (issue Issue) has_open_blockers(terminal_states []string) bool {
	terminal := terminal_states.map(normalize_name(it))
	for blocker in issue.blocked_by {
		if blocker.state == '' || normalize_name(blocker.state) !in terminal {
			return true
		}
	}
	return false
}

pub enum AttemptOutcomeKind {
	succeeded
	failed
	blocked
	canceled
	timed_out
	stalled
	process_exited
}

pub struct AttemptOutcome {
pub:
	kind              AttemptOutcomeKind
	issue_id          string
	attempt           int
	error_message     string
	runtime_seconds   f64
	tokens            TokenTotals
	rate_used_percent int
	rate_resets_at    i64
}

pub struct TokenTotals {
pub:
	input  i64
	output i64
	total  i64
}

pub struct RateLimitSnapshot {
pub:
	used_percent int
	resets_at    i64
}

pub struct RunningSnapshot {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	state            string
	attempt          int
	started_at_ms    i64
	last_activity_ms i64
	thread_id        string
	turn_id          string
	pid              int
	last_event       string
	last_message     string
	turn_count       int
	tokens           TokenTotals
	rate_limit       RateLimitSnapshot
}

pub struct SessionUpdate {
pub:
	issue_id     string
	event        string
	timestamp_ms i64
	pid          int
	thread_id    string
	turn_id      string
	message      string
	turn_count   int
	tokens       TokenTotals
	rate_limit   RateLimitSnapshot
}

pub struct RetrySnapshot {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	attempt          int
	due_at_ms        i64
	error_message    string
}

pub struct BlockedSnapshot {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	state            string
	updated_at       string
	attempt          int
	reason           string
}

pub struct CompletedSnapshot {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	state            string
	completed_at     string
}

pub struct RuntimeSnapshot {
pub:
	running      []RunningSnapshot
	retrying     []RetrySnapshot
	blocked      []BlockedSnapshot
	completed    []CompletedSnapshot
	tokens       TokenTotals
	rate_limit   RateLimitSnapshot
	runtime_secs f64
	generated_at i64
}
