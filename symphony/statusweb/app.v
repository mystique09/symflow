module statusweb

import encoding.html
import net
import net.http
import net.urllib
import strings
import time
import veb
import symphony.domain
import symphony.observability
import symphony.orchestrator

const response_entry_limit = 1_000
const bulma_stylesheet = $embed_file('assets/bulma.min.css', .zlib)
const symphony_stylesheet = $embed_file('assets/symphony.css', .zlib)
const symphony_script = $embed_file('assets/symphony.js', .zlib)

pub struct ServerConfig {
pub:
	host string = '127.0.0.1'
	port int    = 8080
}

pub fn default_server_config() ServerConfig {
	return ServerConfig{}
}

pub struct IssueStatus {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	status           string
	phase            string
	state            string
	attempt          int
	session_id       string
	thread_id        string
	turn_id          string
	turn_count       int
	started_at       string
	last_event       string
	last_message     string
	last_event_at    string
	tokens           ApiTokens
	due_at           string
	last_error       string
	completed_at     string
}

pub struct ApiTokens {
pub:
	input_tokens  i64
	output_tokens i64
	total_tokens  i64
}

pub struct ApiCounts {
pub:
	running  int
	retrying int
	blocked  int
	completed int
}

pub struct ApiRunning {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	state            string
	attempt          int
	session_id       string
	thread_id        string
	turn_id          string
	pid              int
	turn_count       int
	last_event       string
	last_message     string
	started_at       string
	last_event_at    string
	tokens           ApiTokens
}

pub struct ApiRetrying {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	attempt          int
	due_at           string
	error            string
}

pub struct ApiBlocked {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	state            string
	attempt          int
	reason           string
}

pub struct ApiCompleted {
pub:
	issue_id         string
	issue_identifier string
	issue_url        string
	state            string
	completed_at     string
}

pub struct ApiCodexTotals {
pub:
	input_tokens    i64
	output_tokens   i64
	total_tokens    i64
	seconds_running f64
}

pub struct ApiState {
pub:
	generated_at string
	counts       ApiCounts
	running      []ApiRunning
	retrying     []ApiRetrying
	blocked      []ApiBlocked
	completed    []ApiCompleted
	codex_totals ApiCodexTotals
	rate_limits  domain.RateLimitSnapshot
}

pub struct ApiErrorDetail {
pub:
	code    string
	message string
}

pub struct ApiError {
pub:
	error ApiErrorDetail
}

pub struct RefreshResponse {
pub:
	queued       bool
	coalesced    bool
	requested_at string
	operations   []string
}

struct DashboardView {
pub:
	generated_at     string
	generated_at_iso string
	runtime_seconds  string
	total_tokens     string
	rate_used        string
	rate_reset       string
	rate_reset_iso   string
	running          []DashboardRunningRow
	retrying         []DashboardRetryingRow
	blocked          []DashboardBlockedRow
	completed        []DashboardCompletedRow
}

struct DashboardRunningRow {
pub:
	issue_identifier string
	issue_url        string
	state            string
	attempt          int
	turn_count       int
	last_event       string
	tokens           string
}

struct DashboardRetryingRow {
pub:
	issue_identifier string
	issue_url        string
	attempt          int
	due_at           string
	last_error       string
}

struct DashboardBlockedRow {
pub:
	issue_identifier string
	issue_url        string
	state            string
	attempt          int
	reason           string
}

struct DashboardCompletedRow {
pub:
	issue_identifier string
	issue_url        string
	state            string
	completed_at     string
}

pub fn find_issue(snapshot domain.RuntimeSnapshot, issue_id string) !IssueStatus {
	for entry in snapshot.running {
		if entry.issue_id == issue_id || entry.issue_identifier == issue_id {
			return IssueStatus{
				issue_id:         entry.issue_id
				issue_identifier: entry.issue_identifier
				issue_url:        entry.issue_url
				status:           'running'
				phase:            'running'
				state:            entry.state
				attempt:          entry.attempt
				session_id:       entry.thread_id
				thread_id:        entry.thread_id
				turn_id:          entry.turn_id
				turn_count:       entry.turn_count
				started_at:       format_millis(entry.started_at_ms)
				last_event:       entry.last_event
				last_message:     entry.last_message
				last_event_at:    format_millis(entry.last_activity_ms)
				tokens:           api_tokens(entry.tokens)
			}
		}
	}
	for entry in snapshot.retrying {
		if entry.issue_id == issue_id || entry.issue_identifier == issue_id {
			return IssueStatus{
				issue_id:         entry.issue_id
				issue_identifier: entry.issue_identifier
				issue_url:        entry.issue_url
				status:           'retrying'
				phase:            'retrying'
				attempt:          entry.attempt
				due_at:           format_millis(entry.due_at_ms)
				last_error:       bounded(entry.error_message, 2_048)
			}
		}
	}
	for entry in snapshot.blocked {
		if entry.issue_id == issue_id || entry.issue_identifier == issue_id {
			return IssueStatus{
				issue_id:         entry.issue_id
				issue_identifier: entry.issue_identifier
				issue_url:        entry.issue_url
				status:           'blocked'
				phase:            'blocked'
				state:            entry.state
				attempt:          entry.attempt
				last_error:       bounded(entry.reason, 2_048)
			}
		}
	}
	for entry in snapshot.completed {
		if entry.issue_id == issue_id || entry.issue_identifier == issue_id {
			return IssueStatus{
				issue_id:         entry.issue_id
				issue_identifier: entry.issue_identifier
				issue_url:        entry.issue_url
				status:           'completed'
				phase:            'completed'
				state:            entry.state
				completed_at:     entry.completed_at
			}
		}
	}
	return error('issue not found')
}

pub fn api_state(snapshot domain.RuntimeSnapshot) ApiState {
	bounded_snapshot := api_snapshot(snapshot)
	return ApiState{
		generated_at: format_millis(bounded_snapshot.generated_at)
		counts:       ApiCounts{
			running:  bounded_snapshot.running.len
			retrying: bounded_snapshot.retrying.len
			blocked:  bounded_snapshot.blocked.len
			completed: bounded_snapshot.completed.len
		}
		running:      bounded_snapshot.running.map(ApiRunning{
			issue_id:         it.issue_id
			issue_identifier: it.issue_identifier
			issue_url:        it.issue_url
			state:            it.state
			attempt:          it.attempt
			session_id:       it.thread_id
			thread_id:        it.thread_id
			turn_id:          it.turn_id
			pid:              it.pid
			turn_count:       it.turn_count
			last_event:       it.last_event
			last_message:     bounded(it.last_message, 2_048)
			started_at:       format_millis(it.started_at_ms)
			last_event_at:    format_millis(it.last_activity_ms)
			tokens:           api_tokens(it.tokens)
		})
		retrying:     bounded_snapshot.retrying.map(ApiRetrying{
			issue_id:         it.issue_id
			issue_identifier: it.issue_identifier
			issue_url:        it.issue_url
			attempt:          it.attempt
			due_at:           format_millis(it.due_at_ms)
			error:            bounded(it.error_message, 2_048)
		})
		blocked:      bounded_snapshot.blocked.map(ApiBlocked{
			issue_id:         it.issue_id
			issue_identifier: it.issue_identifier
			issue_url:        it.issue_url
			state:            it.state
			attempt:          it.attempt
			reason:           bounded(it.reason, 2_048)
		})
		completed:    bounded_snapshot.completed.map(ApiCompleted{
			issue_id:         it.issue_id
			issue_identifier: it.issue_identifier
			issue_url:        it.issue_url
			state:            it.state
			completed_at:     it.completed_at
		})
		codex_totals: ApiCodexTotals{
			input_tokens:    bounded_snapshot.tokens.input
			output_tokens:   bounded_snapshot.tokens.output
			total_tokens:    bounded_snapshot.tokens.total
			seconds_running: bounded_snapshot.runtime_secs
		}
		rate_limits:  bounded_snapshot.rate_limit
	}
}

pub fn api_snapshot(snapshot domain.RuntimeSnapshot) domain.RuntimeSnapshot {
	return domain.RuntimeSnapshot{
		...snapshot
		running:  snapshot.running[..min_int(snapshot.running.len, response_entry_limit)].clone()
		retrying: snapshot.retrying[..min_int(snapshot.retrying.len, response_entry_limit)].clone()
		blocked:  snapshot.blocked[..min_int(snapshot.blocked.len, response_entry_limit)].clone()
		completed: snapshot.completed[..min_int(snapshot.completed.len, response_entry_limit)].clone()
	}
}

pub fn try_refresh(refresh chan bool) bool {
	select {
		refresh <- true {
			return true
		}
		else {
			return false
		}
	}
	return false
}

pub struct Context {
	veb.Context
}

pub fn (mut ctx Context) not_found() veb.Result {
	ctx.res.status_code = int(http.Status.not_found)
	return ctx.json(ApiError{
		error: ApiErrorDetail{
			code:    'not_found'
			message: 'the requested resource was not found'
		}
	})
}

pub struct App {
	server_ready chan &veb.Server
pub:
	runtime orchestrator.Runtime
	refresh chan bool
}

pub fn (mut app App) init_server(server &veb.Server) {
	app.server_ready <- server
}

pub fn (app &App) index(mut ctx Context) veb.Result {
	view := dashboard_view(api_snapshot(app.runtime.snapshot(time.now().unix_milli())))
	return $veb.html()
}

@['/assets/bulma.min.css']
pub fn (app &App) bulma_css(mut ctx Context) veb.Result {
	_ = app
	return ctx.send_response_to_client('text/css', bulma_stylesheet.to_string())
}

@['/assets/symphony.css']
pub fn (app &App) symphony_css(mut ctx Context) veb.Result {
	_ = app
	return ctx.send_response_to_client('text/css', symphony_stylesheet.to_string())
}

@['/assets/symphony.js']
pub fn (app &App) symphony_js(mut ctx Context) veb.Result {
	_ = app
	return ctx.send_response_to_client('text/javascript', symphony_script.to_string())
}

@['/healthz']
pub fn (app &App) health(mut ctx Context) veb.Result {
	return ctx.json({
		'status': 'ok'
	})
}

@['/api/v1/state']
pub fn (app &App) state(mut ctx Context) veb.Result {
	return ctx.json(api_state(app.runtime.snapshot(time.now().unix_milli())))
}

@['/api/v1/issues/:id']
pub fn (app &App) issue(mut ctx Context, id string) veb.Result {
	status := find_issue(app.runtime.snapshot(time.now().unix_milli()), id) or {
		return ctx.not_found()
	}
	return ctx.json(status)
}

@['/api/v1/refresh'; get]
pub fn (app &App) refresh_get(mut ctx Context) veb.Result {
	_ = app
	ctx.res.status_code = int(http.Status.method_not_allowed)
	return ctx.json(ApiError{
		error: ApiErrorDetail{
			code:    'method_not_allowed'
			message: 'use POST for this endpoint'
		}
	})
}

@['/api/v1/:identifier']
pub fn (app &App) issue_by_identifier(mut ctx Context, identifier string) veb.Result {
	status := find_issue(app.runtime.snapshot(time.now().unix_milli()), identifier) or {
		ctx.res.status_code = int(http.Status.not_found)
		return ctx.json(ApiError{
			error: ApiErrorDetail{
				code:    'issue_not_found'
				message: 'no active, retrying, blocked, or completed issue matches `${identifier}`'
			}
		})
	}
	return ctx.json(status)
}

@['/api/v1/refresh'; post]
pub fn (app &App) refresh(mut ctx Context) veb.Result {
	if !try_refresh(app.refresh) {
		ctx.res.status_code = int(http.Status.service_unavailable)
		return ctx.json(ApiError{
			error: ApiErrorDetail{
				code:    'refresh_unavailable'
				message: 'the orchestrator cannot accept a refresh request right now'
			}
		})
	}
	ctx.res.status_code = int(http.Status.accepted)
	return ctx.json(RefreshResponse{
		queued:       true
		coalesced:    false
		requested_at: time.utc().format_rfc3339()
		operations:   ['poll', 'reconcile']
	})
}

pub fn serve(runtime orchestrator.Runtime, refresh chan bool, stop chan bool, config ServerConfig) ! {
	if config.host.trim_space() == '' || config.port < 0 || config.port > 65_535 {
		return error('statusweb_config_error: host and valid port are required')
	}
	port := resolve_port(config.host, config.port)!
	server_ready := chan &veb.Server{cap: 1}
	mut app := &App{
		runtime:      runtime
		refresh:      refresh
		server_ready: server_ready
	}
	observability.emit(observability.Record{
		event:   'statusweb_started'
		message: 'http://${config.host}:${port}'
	}, []string{})
	spawn stop_when_requested(server_ready, stop)
	veb.run_at[App, Context](mut app,
		host:                 config.host
		port:                 port
		family:               if config.host.contains(':') {
			net.AddrFamily.ip6
		} else {
			net.AddrFamily.ip
		}
		show_startup_message: false
	)!
}

fn dashboard_view(snapshot domain.RuntimeSnapshot) DashboardView {
	generated_at := format_millis(snapshot.generated_at)
	rate_reset := format_millis(snapshot.rate_limit.resets_at)
	return DashboardView{
		generated_at:     if generated_at == '' { 'Awaiting first snapshot' } else { generated_at }
		generated_at_iso: generated_at
		runtime_seconds:  '${snapshot.runtime_secs:.1f}s'
		total_tokens:     compact_number(snapshot.tokens.total)
		rate_used:        '${snapshot.rate_limit.used_percent}%'
		rate_reset:       if rate_reset == '' { 'Not reported' } else { rate_reset }
		rate_reset_iso:   rate_reset
		running:          snapshot.running.map(DashboardRunningRow{
			issue_identifier: issue_label(it.issue_identifier)
			issue_url:        sanitized_issue_url(it.issue_url)
			state:            display_text(it.state)
			attempt:          it.attempt
			turn_count:       it.turn_count
			last_event:       display_text(it.last_event)
			tokens:           compact_number(it.tokens.total)
		})
		retrying:         snapshot.retrying.map(DashboardRetryingRow{
			issue_identifier: issue_label(it.issue_identifier)
			issue_url:        sanitized_issue_url(it.issue_url)
			attempt:          it.attempt
			due_at:           display_text_or(format_millis(it.due_at_ms), 'Not scheduled')
			last_error:       display_text(bounded(it.error_message, 2_048))
		})
		blocked:          snapshot.blocked.map(DashboardBlockedRow{
			issue_identifier: issue_label(it.issue_identifier)
			issue_url:        sanitized_issue_url(it.issue_url)
			state:            display_text(it.state)
			attempt:          it.attempt
			reason:           display_text(bounded(it.reason, 2_048))
		})
		completed:        snapshot.completed.map(DashboardCompletedRow{
			issue_identifier: issue_label(it.issue_identifier)
			issue_url:        sanitized_issue_url(it.issue_url)
			state:            display_text(it.state)
			completed_at:     display_text_or(it.completed_at, 'Not reported')
		})
	}
}

fn issue_label(value string) string {
	return display_text_or(value, 'Unknown issue')
}

fn sanitized_issue_url(value string) string {
	return if safe_issue_url(value) { html.escape(value) } else { '' }
}

fn display_text(value string) string {
	return display_text_or(value, '—')
}

fn display_text_or(value string, fallback string) string {
	visible := if value.trim_space() == '' { fallback } else { value }
	return html.escape(visible)
}

fn safe_issue_url(value string) bool {
	if value == '' || value != value.trim_space() {
		return false
	}
	parsed := urllib.parse(value) or { return false }
	return parsed.scheme in ['https', 'http'] && parsed.host.trim_space() != ''
}

pub fn resolve_port(host string, requested int) !int {
	if requested != 0 {
		return requested
	}
	family := if host.contains(':') { net.AddrFamily.ip6 } else { net.AddrFamily.ip }
	address := if host.contains(':') { '[${host}]:0' } else { '${host}:0' }
	mut listener := net.listen_tcp(family, address) or {
		return error('statusweb_config_error: unable to allocate a TCP port: ${err.msg()}')
	}
	port := int(listener.addr()!.port()!)
	listener.close()!
	return port
}

fn stop_when_requested(server_ready chan &veb.Server, stop chan bool) {
	_ := <-stop
	server := <-server_ready
	server.wait_till_running(max_retries: 500, retry_period_ms: 10) or { return }
	server.shutdown(timeout: 5 * time.second) or {}
}

fn compact_number(value i64) string {
	raw := value.str()
	start := if raw.starts_with('-') { 1 } else { 0 }
	mut result := strings.new_builder(raw.len + raw.len / 3)
	if start == 1 {
		result.write_u8(`-`)
	}
	for index in start .. raw.len {
		if index > start && (raw.len - index) % 3 == 0 {
			result.write_u8(`,`)
		}
		result.write_u8(raw[index])
	}
	return result.str()
}

fn bounded(value string, limit int) string {
	return if value.len <= limit { value } else { value[..limit] }
}

fn api_tokens(tokens domain.TokenTotals) ApiTokens {
	return ApiTokens{
		input_tokens:  tokens.input
		output_tokens: tokens.output
		total_tokens:  tokens.total
	}
}

fn format_millis(value i64) string {
	if value <= 0 {
		return ''
	}
	return time.unix_milli(value).as_utc().format_rfc3339()
}

fn min_int(left int, right int) int {
	return if left < right { left } else { right }
}
