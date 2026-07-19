module statusweb

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
	return ctx.html(dashboard_html(api_snapshot(app.runtime.snapshot(time.now().unix_milli()))))
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
				message: 'no active, retrying, or blocked issue matches `${identifier}`'
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

fn dashboard_html(snapshot domain.RuntimeSnapshot) string {
	mut body := strings.new_builder(24_576)
	body.write_string('<!doctype html><html lang="en" data-theme="paper-ops"><head>')
	body.write_string('<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
	body.write_string('<meta name="color-scheme" content="light"><title>Symphony · Orchestration overview</title>')
	write_dashboard_styles(mut body)
	body.write_string('</head><body><main class="page-shell">')
	write_dashboard_header(mut body, snapshot)
	write_dashboard_metrics(mut body, snapshot)
	write_running_section(mut body, snapshot.running)
	write_retrying_section(mut body, snapshot.retrying)
	write_blocked_section(mut body, snapshot.blocked)
	body.write_string('<footer>Symphony engineering preview · local orchestration status</footer>')
	body.write_string('</main></body></html>')
	return body.str()
}

fn write_dashboard_styles(mut body strings.Builder) {
	body.write_string('<style>:root{--canvas:#f4f0e7;--surface:#fffaf1;--surface-strong:#fffdf8;--navy:#18324b;--muted:#687783;--line:#ddd5c6;--running:#2f765c;--running-soft:#dcebe3;--retrying:#9a6421;--retrying-soft:#f6e8cb;--blocked:#a64343;--blocked-soft:#f4dddd;--shadow:0 12px 34px rgba(62,49,32,.08);--radius:18px}*{box-sizing:border-box}html{background:var(--canvas)}body{margin:0;background:linear-gradient(180deg,#f8f4ec 0,var(--canvas) 24rem);color:var(--navy);font:15px/1.55 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:inherit}a:focus-visible{outline:3px solid #4c7e9f;outline-offset:3px}.page-shell{width:min(1180px,calc(100% - 32px));margin:0 auto;padding:32px 0 48px}')
	body.write_string('.topbar,.hero-row,.section-heading{display:flex;align-items:center;justify-content:space-between;gap:16px}.brand{display:flex;align-items:center;gap:10px;font-size:16px;font-weight:850;letter-spacing:-.02em}.brand-mark{display:grid;place-items:center;width:34px;height:34px;border-radius:10px;background:var(--navy);color:#fffaf1;box-shadow:0 5px 14px rgba(24,50,75,.16)}.live{display:inline-flex;align-items:center;gap:7px;color:var(--running);font-size:12px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.live-dot{width:8px;height:8px;border-radius:50%;background:var(--running);box-shadow:0 0 0 4px rgba(47,118,92,.11)}')
	body.write_string('.hero{padding:14px 0 4px}.hero-row{align-items:flex-end}.eyebrow{margin:34px 0 9px;color:var(--muted);font-size:12px;font-weight:800;letter-spacing:.1em;text-transform:uppercase}h1{max-width:760px;margin:0;font-size:clamp(34px,5vw,54px);font-weight:850;line-height:1.03;letter-spacing:-.055em}.lede{max-width:640px;margin:12px 0 0;color:var(--muted);font-size:16px}.metadata{display:grid;gap:7px;min-width:245px;padding:15px 17px;border:1px solid var(--line);border-radius:14px;background:rgba(255,250,241,.72);color:var(--muted);font-size:12px}.metadata strong{color:var(--navy);font-weight:750}.metadata-row{display:flex;justify-content:space-between;gap:20px}.metadata time{font-variant-numeric:tabular-nums}')
	body.write_string('.metrics{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:28px 0}.metric,.queue-card{border:1px solid var(--line);background:var(--surface);box-shadow:var(--shadow)}.metric{position:relative;overflow:hidden;padding:20px;border-radius:var(--radius)}.metric:before{position:absolute;inset:0 auto 0 0;width:4px;content:""}.metric-running:before{background:var(--running)}.metric-retrying:before{background:var(--retrying)}.metric-blocked:before{background:var(--blocked)}.metric-label{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.metric-dot,.queue-dot{width:8px;height:8px;border-radius:50%;background:currentColor}.metric-running .metric-label{color:var(--running)}.metric-retrying .metric-label{color:var(--retrying)}.metric-blocked .metric-label{color:var(--blocked)}.metric-value{display:block;margin-top:5px;font-size:34px;font-weight:850;line-height:1.1;letter-spacing:-.045em}.metric-caption{display:block;margin-top:6px;color:var(--muted);font-size:12px}')
	body.write_string('.queues{display:grid;gap:16px}.queue-card{overflow:hidden;border-radius:var(--radius)}.section-heading{padding:18px 20px;border-bottom:1px solid var(--line);background:var(--surface-strong)}.section-title{display:flex;align-items:center;gap:9px}.section-heading h2{margin:0;font-size:18px;letter-spacing:-.02em}.queue-running .queue-dot{color:var(--running)}.queue-retrying .queue-dot{color:var(--retrying)}.queue-blocked .queue-dot{color:var(--blocked)}.count{min-width:30px;padding:3px 9px;border-radius:999px;text-align:center;font-size:12px;font-weight:800}.queue-running .count{color:var(--running);background:var(--running-soft)}.queue-retrying .count{color:var(--retrying);background:var(--retrying-soft)}.queue-blocked .count{color:var(--blocked);background:var(--blocked-soft)}')
	body.write_string('.table-scroll{overflow-x:auto}table{width:100%;border-collapse:collapse}th,td{padding:14px 20px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}th{color:var(--muted);font-size:11px;font-weight:800;letter-spacing:.08em;text-transform:uppercase;white-space:nowrap}tbody tr{transition:background-color .15s ease}tbody tr:hover{background:#fbf6ed}tbody tr:last-child td{border-bottom:0}.issue-reference{font-weight:800;white-space:nowrap}.issue-link{text-decoration-color:#91a0ab;text-decoration-thickness:1px;text-underline-offset:3px}.issue-link:hover{text-decoration-color:currentColor}.status{display:inline-flex;padding:4px 9px;border-radius:999px;font-size:11px;font-weight:800;white-space:nowrap}.status-running{color:var(--running);background:var(--running-soft)}.status-retrying{color:var(--retrying);background:var(--retrying-soft)}.status-blocked{color:var(--blocked);background:var(--blocked-soft)}.numeric{font-variant-numeric:tabular-nums}.message{max-width:38rem;overflow-wrap:anywhere;color:var(--muted)}.empty{padding:32px 20px;text-align:center;color:var(--muted)}footer{padding-top:26px;color:var(--muted);font-size:12px;text-align:center}')
	body.write_string('@media(max-width:860px){.hero-row{align-items:flex-start;flex-direction:column}.metadata{width:100%;min-width:0}.metrics{grid-template-columns:repeat(3,1fr)}}@media(max-width:640px){.page-shell{width:min(100% - 20px,1180px);padding-top:18px}.topbar{align-items:flex-start}.live{margin-top:8px}.eyebrow{margin-top:28px}.metrics{grid-template-columns:1fr}.metric{padding:17px}.metadata-row{gap:12px}.section-heading{padding:15px 14px}th,td{padding:12px 14px}h1{font-size:36px}}@media(prefers-reduced-motion:reduce){tbody tr{transition:none}}</style>')
}

fn write_dashboard_header(mut body strings.Builder, snapshot domain.RuntimeSnapshot) {
	generated_at := format_millis(snapshot.generated_at)
	reset_at := format_millis(snapshot.rate_limit.resets_at)
	body.write_string('<header class="topbar"><div class="brand"><span class="brand-mark" aria-hidden="true">S</span><span>Symphony</span></div>')
	body.write_string('<div class="live"><span class="live-dot" aria-hidden="true"></span>Service live</div></header>')
	body.write_string('<section class="hero" aria-labelledby="overview-title"><p class="eyebrow">Local agent operations</p><div class="hero-row"><div>')
	body.write_string('<h1 id="overview-title">Orchestration overview</h1><p class="lede">Agent activity across the issue queue, from active work through retries and operator blocks.</p></div>')
	body.write_string('<div class="metadata" aria-label="Runtime metadata">')
	write_metadata_row(mut body, 'Generated', timestamp_markup(generated_at,
		'Awaiting first snapshot'))
	write_metadata_row(mut body, 'Runtime', '<strong>${snapshot.runtime_secs:.1f}s</strong>')
	write_metadata_row(mut body, 'Tokens',
		'<strong>${compact_number(snapshot.tokens.total)}</strong>')
	write_metadata_row(mut body, 'Rate used',
		'<strong>${snapshot.rate_limit.used_percent}%</strong>')
	write_metadata_row(mut body, 'Rate reset', timestamp_markup(reset_at, 'Not reported'))
	body.write_string('</div></div></section>')
}

fn write_metadata_row(mut body strings.Builder, label string, value_markup string) {
	body.write_string('<div class="metadata-row"><span>${escape_html(label)}</span>${value_markup}</div>')
}

fn timestamp_markup(value string, fallback string) string {
	if value == '' {
		return '<strong>${escape_html(fallback)}</strong>'
	}
	escaped := escape_html(value)
	return '<time datetime="${escaped}"><strong>${escaped}</strong></time>'
}

fn write_dashboard_metrics(mut body strings.Builder, snapshot domain.RuntimeSnapshot) {
	body.write_string('<section class="metrics" aria-label="Queue totals">')
	write_metric(mut body, 'running', 'Running', snapshot.running.len, 'Agents working now')
	write_metric(mut body, 'retrying', 'Retrying', snapshot.retrying.len,
		'Attempts waiting to resume')
	write_metric(mut body, 'blocked', 'Blocked', snapshot.blocked.len, 'Issues needing attention')
	body.write_string('</section><div class="queues">')
}

fn write_metric(mut body strings.Builder, kind string, label string, value int, caption string) {
	body.write_string('<article class="metric metric-${kind}"><span class="metric-label"><span class="metric-dot" aria-hidden="true"></span>${escape_html(label)}</span>')
	body.write_string('<strong class="metric-value">${value}</strong><span class="metric-caption">${escape_html(caption)}</span></article>')
}

fn write_running_section(mut body strings.Builder, entries []domain.RunningSnapshot) {
	write_section_start(mut body, 'running', 'Running', entries.len)
	body.write_string('<div class="table-scroll"><table aria-label="Running issues"><thead><tr><th>Issue</th><th>Status</th><th>State</th><th>Attempt</th><th>Turns</th><th>Last event</th><th>Tokens</th></tr></thead><tbody>')
	if entries.len == 0 {
		write_empty_row(mut body, 7, 'No agents are running right now.')
	} else {
		for entry in entries {
			body.write_string('<tr><td>${issue_reference(entry.issue_identifier, entry.issue_url)}</td><td><span class="status status-running">Running</span></td>')
			body.write_string('<td>${display_value(entry.state)}</td><td class="numeric">${entry.attempt}</td><td class="numeric">${entry.turn_count}</td>')
			body.write_string('<td class="message">${display_value(entry.last_event)}</td><td class="numeric">${compact_number(entry.tokens.total)}</td></tr>')
		}
	}
	body.write_string('</tbody></table></div></section>')
}

fn write_retrying_section(mut body strings.Builder, entries []domain.RetrySnapshot) {
	write_section_start(mut body, 'retrying', 'Retrying', entries.len)
	body.write_string('<div class="table-scroll"><table aria-label="Retrying issues"><thead><tr><th>Issue</th><th>Status</th><th>Attempt</th><th>Due</th><th>Last error</th></tr></thead><tbody>')
	if entries.len == 0 {
		write_empty_row(mut body, 5, 'No retries are queued.')
	} else {
		for entry in entries {
			body.write_string('<tr><td>${issue_reference(entry.issue_identifier, entry.issue_url)}</td><td><span class="status status-retrying">Retrying</span></td>')
			body.write_string('<td class="numeric">${entry.attempt}</td><td>${timestamp_markup(format_millis(entry.due_at_ms),
				'Not scheduled')}</td><td class="message">${display_value(bounded(entry.error_message,
				2_048))}</td></tr>')
		}
	}
	body.write_string('</tbody></table></div></section>')
}

fn write_blocked_section(mut body strings.Builder, entries []domain.BlockedSnapshot) {
	write_section_start(mut body, 'blocked', 'Blocked', entries.len)
	body.write_string('<div class="table-scroll"><table aria-label="Blocked issues"><thead><tr><th>Issue</th><th>Status</th><th>State</th><th>Attempt</th><th>Reason</th></tr></thead><tbody>')
	if entries.len == 0 {
		write_empty_row(mut body, 5, 'No issues are blocked.')
	} else {
		for entry in entries {
			body.write_string('<tr><td>${issue_reference(entry.issue_identifier, entry.issue_url)}</td><td><span class="status status-blocked">Blocked</span></td>')
			body.write_string('<td>${display_value(entry.state)}</td><td class="numeric">${entry.attempt}</td><td class="message">${display_value(bounded(entry.reason,
				2_048))}</td></tr>')
		}
	}
	body.write_string('</tbody></table></div></section></div>')
}

fn write_section_start(mut body strings.Builder, kind string, label string, count int) {
	body.write_string('<section class="queue-card queue-${kind}" aria-labelledby="${kind}-heading"><div class="section-heading"><div class="section-title">')
	body.write_string('<span class="queue-dot" aria-hidden="true"></span><h2 id="${kind}-heading">${escape_html(label)}</h2></div><span class="count">${count}</span></div>')
}

fn write_empty_row(mut body strings.Builder, column_count int, message string) {
	body.write_string('<tr><td class="empty" colspan="${column_count}">${escape_html(message)}</td></tr>')
}

fn issue_reference(identifier string, issue_url string) string {
	label := escape_html(if identifier.trim_space() == '' { 'Unknown issue' } else { identifier })
	if safe_issue_url(issue_url) {
		return '<a class="issue-reference issue-link" href="${escape_html(issue_url)}" target="_blank" rel="noreferrer">${label}</a>'
	}
	return '<span class="issue-reference">${label}</span>'
}

fn safe_issue_url(value string) bool {
	if value == '' || value != value.trim_space() {
		return false
	}
	parsed := urllib.parse(value) or { return false }
	return parsed.scheme in ['https', 'http'] && parsed.host.trim_space() != ''
}

fn display_value(value string) string {
	if value.trim_space() == '' {
		return '<span aria-label="Not available">—</span>'
	}
	return escape_html(value)
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

fn escape_html(value string) string {
	return value.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"',
		'&quot;').replace("'", '&#39;')
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
