# Symphony Dashboard Paper Ops Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Symphony's plain status page with the approved responsive Paper Ops dashboard while preserving every existing HTTP and orchestration contract.

**Architecture:** Keep `veb` routing and JSON DTOs unchanged. Refactor the private dashboard renderer into small HTML-writing helpers in the existing `statusweb` module, keep all CSS inline, and escape every runtime-supplied value before interpolation.

**Tech Stack:** V 0.5.2, `veb`, `strings.Builder`, native V tests, inline HTML and CSS.

## Global Constraints

- The page remains server-rendered and useful without JavaScript.
- Load no external fonts, stylesheets, images, scripts, packages, or frameworks.
- Do not change JSON routes, refresh behavior, orchestration state, or runtime semantics.
- Use a warm cream canvas, navy typography, quiet borders, and green, amber, and red semantic accents.
- Preserve HTML escaping for all issue identifiers, URLs, states, events, errors, and reasons.
- Do not initialize Git or create a GitHub repository; commit steps are intentionally omitted.

---

### Task 1: Lock the Paper Ops rendering contract with tests

**Files:**
- Modify: `symphony/statusweb/app_test.v`
- Test: `symphony/statusweb/app_test.v`

**Interfaces:**
- Consumes: `fn dashboard_html(snapshot domain.RuntimeSnapshot) string`
- Produces: executable assertions for the Paper Ops shell, all three queue states, safe issue links, escaped runtime content, and empty-state copy

- [x] **Step 1: Add a representative dashboard-rendering test**

```v
fn test_dashboard_html_renders_paper_ops_status_sections() {
	snapshot := domain.RuntimeSnapshot{
		generated_at: 1_750_000_000_000
		running: [domain.RunningSnapshot{
			issue_id: 'issue-1'
			issue_identifier: 'SYM-42'
			issue_url: 'https://linear.app/acme/issue/SYM-42'
			state: 'In Progress'
			attempt: 2
			turn_count: 4
			last_event: 'turn/completed'
			tokens: domain.TokenTotals{total: 1_240}
		}]
		retrying: [domain.RetrySnapshot{
			issue_id: 'issue-2'
			issue_identifier: 'SYM-38'
			attempt: 1
			due_at_ms: 1_750_000_030_000
			error_message: 'temporary failure'
		}]
		blocked: [domain.BlockedSnapshot{
			issue_id: 'issue-3'
			issue_identifier: 'SYM-19'
			state: 'Todo'
			reason: 'approval required'
		}]
		tokens: domain.TokenTotals{total: 1_240}
	}
	html := dashboard_html(snapshot)
	assert html.contains('data-theme="paper-ops"')
	assert html.contains('Orchestration overview')
	assert html.contains('class="metric metric-running"')
	assert html.contains('class="status status-running"')
	assert html.contains('href="https://linear.app/acme/issue/SYM-42"')
	assert html.contains('SYM-38')
	assert html.contains('SYM-19')
}
```

- [x] **Step 2: Add escaping and empty-state tests**

```v
fn test_dashboard_html_escapes_runtime_content_and_rejects_unsafe_issue_links() {
	html := dashboard_html(domain.RuntimeSnapshot{
		running: [domain.RunningSnapshot{
			issue_identifier: '<script>alert(1)</script>'
			issue_url: 'javascript:alert(1)'
			state: '<b>Todo</b>'
			last_event: 'event & message'
		}]
	})
	assert !html.contains('<script>alert(1)</script>')
	assert !html.contains('href="javascript:alert(1)"')
	assert html.contains('&lt;script&gt;alert(1)&lt;/script&gt;')
	assert html.contains('&lt;b&gt;Todo&lt;/b&gt;')
	assert html.contains('event &amp; message')
}

fn test_dashboard_html_renders_queue_empty_states() {
	html := dashboard_html(domain.RuntimeSnapshot{})
	assert html.contains('No agents are running right now.')
	assert html.contains('No retries are queued.')
	assert html.contains('No issues are blocked.')
}
```

- [x] **Step 3: Run the focused tests and confirm the new contract fails**

Run: `/Users/benj/.local/bin/v/v test symphony/statusweb`

Expected: FAIL because the current renderer has no `paper-ops` marker, metric cards, safe issue-link policy, or empty-state copy.

---

### Task 2: Implement the Paper Ops dashboard renderer

**Files:**
- Modify: `symphony/statusweb/app.v`
- Test: `symphony/statusweb/app_test.v`

**Interfaces:**
- Consumes: `domain.RuntimeSnapshot`, `domain.RunningSnapshot`, `domain.RetrySnapshot`, and `domain.BlockedSnapshot`
- Produces: `fn dashboard_html(snapshot domain.RuntimeSnapshot) string`, plus private rendering and formatting helpers

- [x] **Step 1: Replace the monolithic renderer with a Paper Ops page shell**

Keep the public route unchanged and have `dashboard_html` assemble this semantic structure:

```v
fn dashboard_html(snapshot domain.RuntimeSnapshot) string {
	mut body := strings.new_builder(24_576)
	body.write_string('<!doctype html><html lang="en" data-theme="paper-ops"><head>')
	body.write_string('<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
	body.write_string('<meta name="color-scheme" content="light"><title>Symphony · Orchestration overview</title>')
	write_dashboard_styles(mut body)
	body.write_string('</head><body><div class="page-shell">')
	write_dashboard_header(mut body, snapshot)
	write_dashboard_metrics(mut body, snapshot)
	write_running_section(mut body, snapshot.running)
	write_retrying_section(mut body, snapshot.retrying)
	write_blocked_section(mut body, snapshot.blocked)
	body.write_string('<footer>Symphony engineering preview · local orchestration status</footer>')
	body.write_string('</div></body></html>')
	return body.str()
}
```

- [x] **Step 2: Add inline Paper Ops design tokens and responsive rules**

`write_dashboard_styles` writes a single `<style>` block defining exact tokens and breakpoints:

```v
fn write_dashboard_styles(mut body strings.Builder) {
	body.write_string('<style>:root{--canvas:#f4f0e7;--surface:#fffaf1;--surface-strong:#fffdf8;--navy:#18324b;--muted:#687783;--line:#ddd5c6;--running:#2f765c;--running-soft:#dcebe3;--retrying:#9a6421;--retrying-soft:#f6e8cb;--blocked:#a64343;--blocked-soft:#f4dddd;--shadow:0 12px 34px rgba(62,49,32,.08);--radius:18px}*{box-sizing:border-box}body{margin:0;background:var(--canvas);color:var(--navy);font:15px/1.55 ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:inherit}a:focus-visible{outline:3px solid #4c7e9f;outline-offset:3px}.page-shell{width:min(1180px,calc(100% - 32px));margin:0 auto;padding:32px 0 48px}.topbar,.hero-row,.section-heading{display:flex;align-items:center;justify-content:space-between;gap:16px}.brand{display:flex;align-items:center;gap:10px;font-weight:800}.brand-mark{display:grid;place-items:center;width:34px;height:34px;border-radius:10px;background:var(--navy);color:#fffaf1}.live{display:inline-flex;align-items:center;gap:7px;color:var(--running);font-size:12px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.live-dot{width:8px;height:8px;border-radius:50%;background:var(--running)}h1{margin:36px 0 4px;font-size:clamp(30px,5vw,52px);line-height:1.05;letter-spacing:-.05em}.metadata{color:var(--muted)}.metrics{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:28px 0}.metric,.queue-card{border:1px solid var(--line);background:var(--surface);box-shadow:var(--shadow)}.metric{padding:20px;border-radius:var(--radius)}.metric-label{font-size:12px;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.metric-value{display:block;margin-top:5px;font-size:32px;font-weight:850;letter-spacing:-.04em}.queue-card{overflow:hidden;margin:16px 0;border-radius:var(--radius)}.section-heading{padding:18px 20px;border-bottom:1px solid var(--line)}.section-heading h2{margin:0;font-size:18px}.count{min-width:30px;padding:3px 9px;border-radius:999px;text-align:center;font-size:12px;font-weight:800}.table-scroll{overflow-x:auto}table{width:100%;border-collapse:collapse}th,td{padding:14px 20px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}th{color:var(--muted);font-size:11px;letter-spacing:.08em;text-transform:uppercase}tbody tr:last-child td{border-bottom:0}.issue-link{font-weight:800;text-decoration-thickness:1px;text-underline-offset:3px}.status{display:inline-flex;padding:4px 9px;border-radius:999px;font-size:11px;font-weight:800}.status-running{color:var(--running);background:var(--running-soft)}.status-retrying{color:var(--retrying);background:var(--retrying-soft)}.status-blocked{color:var(--blocked);background:var(--blocked-soft)}.message{max-width:36rem;overflow-wrap:anywhere;color:var(--muted)}.empty{padding:30px 20px;text-align:center;color:var(--muted)}footer{padding-top:24px;color:var(--muted);font-size:12px;text-align:center}@media(max-width:720px){.page-shell{width:min(100% - 20px,1180px);padding-top:18px}.hero-row{align-items:flex-start;flex-direction:column}.metrics{grid-template-columns:1fr}.metadata{font-size:13px}th,td{padding:12px 14px}}</style>')
}
```

- [x] **Step 3: Render metadata, summary metrics, queue tables, and empty states**

Implement these focused helpers and ensure every runtime string passes through `escape_html`:

```v
fn write_dashboard_header(mut body strings.Builder, snapshot domain.RuntimeSnapshot)
fn write_dashboard_metrics(mut body strings.Builder, snapshot domain.RuntimeSnapshot)
fn write_running_section(mut body strings.Builder, entries []domain.RunningSnapshot)
fn write_retrying_section(mut body strings.Builder, entries []domain.RetrySnapshot)
fn write_blocked_section(mut body strings.Builder, entries []domain.BlockedSnapshot)
fn write_empty_row(mut body strings.Builder, column_count int, message string)
fn issue_reference(identifier string, issue_url string) string
fn safe_issue_url(value string) bool
fn compact_number(value i64) string
```

`safe_issue_url` accepts only absolute `https://` and `http://` URLs. `issue_reference` applies `escape_html` to both the label and accepted URL, adds `target="_blank" rel="noreferrer"`, and otherwise returns escaped plain text. `compact_number` uses comma-grouped integers for token totals.

- [x] **Step 4: Run formatting and the focused status-web suite**

Run:

```sh
/Users/benj/.local/bin/v/v fmt -w symphony/statusweb
/Users/benj/.local/bin/v/v fmt -verify symphony/statusweb
/Users/benj/.local/bin/v/v test symphony/statusweb
```

Expected: formatting verification passes and both direct rendering tests and the live loopback route test pass.

---

### Task 3: Run complete regression and production checks

**Files:**
- Verify: `symphony/statusweb/app.v`
- Verify: `symphony/statusweb/app_test.v`
- Build: `build/symphony`

**Interfaces:**
- Consumes: the completed Paper Ops renderer
- Produces: a verified production binary with unchanged CLI and API behavior

- [x] **Step 1: Run the full V suite**

Run: `/Users/benj/.local/bin/v/v test symphony`

Expected: all 14 V test files pass.

- [x] **Step 2: Run static verification**

Run:

```sh
/Users/benj/.local/bin/v/v fmt -verify bin symphony
/Users/benj/.local/bin/v/v vet bin symphony
```

Expected: formatting passes; vet exits zero, with only the project's existing missing-public-documentation warnings allowed.

- [x] **Step 3: Build and smoke-test the production binary**

Run:

```sh
/Users/benj/.local/bin/v/v -prod -o build/symphony bin/symphony
build/symphony version
build/symphony validate WORKFLOW.example.md
```

Expected: build succeeds, version prints `symphony 0.1.0-dev`, and the example workflow is valid.
