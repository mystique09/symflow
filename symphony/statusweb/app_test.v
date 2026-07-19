module statusweb

import net
import net.http
import time
import symphony.domain
import symphony.orchestrator

fn test_server_defaults_to_loopback() {
	config := default_server_config()
	assert config.host == '127.0.0.1'
	assert config.port == 8080
}

fn test_find_issue_returns_bounded_state_projection() {
	snapshot := domain.RuntimeSnapshot{
		running: [
			domain.RunningSnapshot{
				issue_id:         'issue-1'
				issue_identifier: 'SYM-1'
				state:            'Todo'
				attempt:          3
			},
		]
	}
	issue := find_issue(snapshot, 'SYM-1')!
	assert issue.issue_identifier == 'SYM-1'
	assert issue.phase == 'running'
	assert issue.attempt == 3
}

fn test_zero_port_resolves_to_an_available_tcp_port() {
	port := resolve_port('127.0.0.1', 0)!
	assert port > 0
	assert port <= 65_535
}

fn test_find_issue_reports_missing_id() {
	find_issue(domain.RuntimeSnapshot{}, 'missing') or {
		assert err.msg().contains('not found')
		return
	}
	assert false
}

fn test_api_snapshot_bounds_each_collection() {
	snapshot := api_snapshot(domain.RuntimeSnapshot{
		running:  []domain.RunningSnapshot{len: 1_005}
		retrying: []domain.RetrySnapshot{len: 1_006}
		blocked:  []domain.BlockedSnapshot{len: 1_007}
	})
	assert snapshot.running.len == 1_000
	assert snapshot.retrying.len == 1_000
	assert snapshot.blocked.len == 1_000
}

fn test_try_refresh_is_non_blocking_when_service_is_unavailable() {
	refresh := chan bool{}
	assert !try_refresh(refresh)
}

fn test_safe_issue_url_requires_an_absolute_http_url_with_a_host() {
	assert safe_issue_url('https://linear.app/acme/issue/SYM-42')
	assert safe_issue_url('http://localhost:8080/issues/SYM-42')
	assert !safe_issue_url('https://')
	assert !safe_issue_url('javascript:alert(1)')
	assert !safe_issue_url(' https://linear.app/acme/issue/SYM-42')
}

fn test_http_routes_expose_snapshot_and_accept_refresh() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := int(listener.addr()!.port()!)
	listener.close()!
	runtime := orchestrator.start_runtime(2, 60_000)
	assert runtime.claim(domain.Issue{
		id:         'route-issue'
		identifier: 'SYM-WEB'
		url:        'https://example.test/issues/SYM-WEB?source=web&view=full'
		title:      'Exercise web routes'
		state:      'Todo'
	}, 0, time.now().unix_milli())
	assert runtime.claim(domain.Issue{
		id:         'unsafe-route-issue'
		identifier: '<script>alert(1)</script>'
		url:        'javascript:alert(1)'
		title:      'Exercise template escaping'
		state:      '<b>Todo</b>'
	}, 0, time.now().unix_milli())
	refresh := chan bool{cap: 1}
	stop := chan bool{cap: 1}
	done := chan string{cap: 1}
	spawn serve_for_test(runtime, refresh, stop, done, port)
	wait_for_health(port)!
	dashboard := http.get('http://127.0.0.1:${port}/')!
	assert dashboard.status_code == 200
	assert dashboard.body.contains('Symphony')
	assert dashboard.body.contains('SYM-WEB')
	assert dashboard.body.contains('href="https://example.test/issues/SYM-WEB?source=web&amp;view=full"')
	assert dashboard.body.contains('href="/assets/bulma.min.css"')
	assert dashboard.body.contains('href="/assets/symphony.css"')
	assert dashboard.body.contains('<time datetime="')
	assert dashboard.body.contains('class="section dashboard-shell"')
	assert dashboard.body.contains('class="table is-fullwidth')
	assert dashboard.body.contains('No retries are queued.')
	assert dashboard.body.contains('No issues are blocked.')
	assert !dashboard.body.contains('<script>alert(1)</script>')
	assert !dashboard.body.contains('href="javascript:alert(1)"')
	assert dashboard.body.contains('&lt;script&gt;alert(1)&lt;/script&gt;')
	assert dashboard.body.contains('&lt;b&gt;Todo&lt;/b&gt;')
	bulma := http.get('http://127.0.0.1:${port}/assets/bulma.min.css')!
	assert bulma.status_code == 200
	assert (bulma.header.get(.content_type) or { '' }) == 'text/css'
	assert bulma.body.contains('bulma.io')
	theme := http.get('http://127.0.0.1:${port}/assets/symphony.css')!
	assert theme.status_code == 200
	assert (theme.header.get(.content_type) or { '' }) == 'text/css'
	state_response := http.get('http://127.0.0.1:${port}/api/v1/state')!
	assert state_response.status_code == 200
	assert state_response.body.contains('SYM-WEB')
	assert state_response.body.contains('"counts"')
	assert state_response.body.contains('"codex_totals"')
	issue_response := http.get('http://127.0.0.1:${port}/api/v1/SYM-WEB')!
	assert issue_response.status_code == 200
	assert issue_response.body.contains('"phase":"running"')
	assert issue_response.body.contains('"status":"running"')
	missing_response := http.get('http://127.0.0.1:${port}/api/v1/missing')!
	assert missing_response.status_code == 404
	assert missing_response.body.contains('"code":"issue_not_found"')
	wrong_method := http.get('http://127.0.0.1:${port}/api/v1/refresh')!
	assert wrong_method.status_code == 405
	assert wrong_method.body.contains('"code":"method_not_allowed"')
	refresh_response := http.post('http://127.0.0.1:${port}/api/v1/refresh', '')!
	assert refresh_response.status_code == 202
	assert refresh_response.body.contains('"queued":true')
	_ := <-refresh
	stop <- true
	select {
		message := <-done {
			assert message == ''
		}
		6 * time.second {
			assert false, 'status server did not stop'
		}
	}
	runtime.shutdown()
}

fn test_server_stops_when_requested_during_startup() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := int(listener.addr()!.port()!)
	listener.close()!
	runtime := orchestrator.start_runtime(1, 60_000)
	refresh := chan bool{cap: 1}
	stop := chan bool{cap: 1}
	done := chan string{cap: 1}
	spawn serve_for_test(runtime, refresh, stop, done, port)
	stop <- true
	select {
		message := <-done {
			assert message == ''
		}
		6 * time.second {
			assert false, 'status server did not stop after an immediate request'
		}
	}
	runtime.shutdown()
}

fn serve_for_test(runtime orchestrator.Runtime, refresh chan bool, stop chan bool, done chan string, port int) {
	serve(runtime, refresh, stop, ServerConfig{
		port: port
	}) or {
		done <- err.msg()
		return
	}
	done <- ''
}

fn wait_for_health(port int) ! {
	for _ in 0 .. 100 {
		response := http.get('http://127.0.0.1:${port}/healthz') or {
			time.sleep(20 * time.millisecond)
			continue
		}
		if response.status_code == 200 {
			return
		}
		time.sleep(20 * time.millisecond)
	}
	return error('status server did not start')
}
