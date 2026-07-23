# Symphony Horizontal Operations Board Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Symphony's vertically stacked runtime tables and duplicate summary cards with a read-only, responsive three-column operations board.

**Architecture:** Keep the existing `DashboardView`, Veb route, embedded assets, and server-side escaping boundary unchanged. Replace only the dashboard template's presentation markup and the local theme stylesheet, then verify the rendered HTML, embedded CSS, responsive overflow, and existing HTTP/API behavior.

**Tech Stack:** V 0.5.2 (`f915d3e`), `veb` compile-time templates, vendored Bulma 1.0.4, local CSS, V HTTP integration tests.

## Global Constraints

- The board contains exactly three runtime columns in this order: Running, Retrying, Blocked.
- The three duplicate summary cards are removed.
- The board is read-only: no drag-and-drop, ticket editing, status mutation, filters, or add-item controls.
- Existing JSON routes, refresh behavior, `DashboardView`, tracker behavior, and orchestration semantics remain unchanged.
- The page remains useful without JavaScript and makes no runtime CDN requests.
- Existing issue URL validation, HTML escaping, local assets, and semantic `<time>` output remain intact.
- Wide screens show all columns; narrower screens use one board-level horizontal scroller; mobile uses scroll snapping rather than a vertical stack.
- Do not push commits or create a pull request.

---

## File Structure

- Modify `symphony/statusweb/templates/index.html`: own the compact overview, three semantic board columns, ticket-card lists, and empty states.
- Modify `symphony/statusweb/assets/symphony.css`: own spacing tokens, full-width board layout, column/card styling, responsive overflow, and mobile scroll snapping.
- Modify `symphony/statusweb/app_test.v`: verify rendered board semantics, removal of old tables/summary cards, embedded responsive CSS, escaping, links, empty states, APIs, and shutdown behavior.
- Leave `symphony/statusweb/app.v` unchanged: the existing view model already provides every field required by the cards.

---

### Task 1: Render runtime queues as semantic board cards

**Files:**
- Modify: `symphony/statusweb/app_test.v:94-117`
- Modify: `symphony/statusweb/templates/index.html:25-185`

**Interfaces:**
- Consumes: `DashboardView.running []DashboardRunningRow`, `DashboardView.retrying []DashboardRetryingRow`, and `DashboardView.blocked []DashboardBlockedRow` from `symphony/statusweb/app.v`.
- Produces: `.operations-board`, `.board-column`, `.board-column-header`, `.board-column-body`, `.ticket-list`, `.ticket-card`, `.ticket-facts`, `.ticket-message`, and `.board-empty` markup for the stylesheet and HTTP tests.

- [ ] **Step 1: Replace the old table assertion with failing board assertions**

In `test_http_routes_expose_snapshot_and_accept_refresh`, replace:

```v
assert dashboard.body.contains('class="table is-fullwidth')
assert dashboard.body.contains('No retries are queued.')
assert dashboard.body.contains('No issues are blocked.')
```

with:

```v
assert dashboard.body.contains('class="operations-board"')
assert dashboard.body.contains('aria-label="Runtime queues"')
assert dashboard.body.contains('class="board-column queue-running"')
assert dashboard.body.contains('class="board-column queue-retrying"')
assert dashboard.body.contains('class="board-column queue-blocked"')
assert dashboard.body.contains('class="ticket-list"')
assert dashboard.body.contains('class="ticket-card"')
assert dashboard.body.contains('<dt>State</dt>')
assert dashboard.body.contains('<dt>Attempt</dt>')
assert dashboard.body.contains('<dt>Turns</dt>')
assert dashboard.body.contains('<dt>Tokens</dt>')
assert dashboard.body.contains('Last event')
assert dashboard.body.contains('No retries are queued.')
assert dashboard.body.contains('No issues are blocked.')
assert !dashboard.body.contains('aria-label="Queue totals"')
assert !dashboard.body.contains('status-card')
assert !dashboard.body.contains('<table')
```

Keep the existing assertions for `Symphony`, `SYM-WEB`, safe links, local assets,
`<time>`, escaped text, APIs, refresh, and shutdown.

- [ ] **Step 2: Run the focused test and verify the old dashboard fails it**

Run:

```sh
v symphony/statusweb/app_test.v
```

Expected: FAIL because the current response has no `.operations-board` and
still contains summary cards and `<table>` markup.

- [ ] **Step 3: Replace the hero, summaries, and table stack with the compact board**

In `symphony/statusweb/templates/index.html`, replace lines 25-185 with:

```html
      <section class="overview-header" aria-labelledby="overview-title">
        <div class="overview-copy">
          <h1 class="title is-3 mb-2 overview-title" id="overview-title">Orchestration overview</h1>
          <p class="subtitle is-6 mb-0">Live agent work, retries, and operator blocks.</p>
        </div>
        <div class="metadata-box" aria-label="Runtime metadata">
          <div class="metadata-row">
            <span>Generated</span>
            @if view.generated_at_iso != ''
            <time datetime="@view.generated_at_iso"><strong>@view.generated_at</strong></time>
            @else
            <strong>@view.generated_at</strong>
            @endif
          </div>
          <div class="metadata-row"><span>Runtime</span><strong>@view.runtime_seconds</strong></div>
          <div class="metadata-row"><span>Tokens</span><strong>@view.total_tokens</strong></div>
          <div class="metadata-row"><span>Rate used</span><strong>@view.rate_used</strong></div>
          <div class="metadata-row">
            <span>Rate reset</span>
            @if view.rate_reset_iso != ''
            <time datetime="@view.rate_reset_iso"><strong>@view.rate_reset</strong></time>
            @else
            <strong>@view.rate_reset</strong>
            @endif
          </div>
        </div>
      </section>

      <div class="operations-board" role="region" aria-label="Runtime queues" tabindex="0">
        <section class="board-column queue-running" aria-labelledby="running-heading">
          <header class="board-column-header">
            <h2 class="title is-5 mb-0 queue-title" id="running-heading">
              <span class="queue-dot" aria-hidden="true"></span>Running
            </h2>
            <span class="tag is-success is-light is-rounded" aria-label="@{view.running.len} running issues">@{view.running.len}</span>
          </header>
          <div class="board-column-body">
            @if view.running.len == 0
            <p class="board-empty">No agents are running right now.</p>
            @else
            <ul class="ticket-list" aria-label="Running issues">
              @for entry in view.running
              <li>
                <article class="ticket-card">
                  <header class="ticket-card-header">
                    @if entry.issue_url != ''
                    <a class="issue-reference" href="@{entry.issue_url}" target="_blank" rel="noreferrer">@entry.issue_identifier</a>
                    @else
                    <span class="issue-reference">@entry.issue_identifier</span>
                    @endif
                    <span class="status-label status-running">Running</span>
                  </header>
                  <dl class="ticket-facts">
                    <div><dt>State</dt><dd>@entry.state</dd></div>
                    <div><dt>Attempt</dt><dd class="numeric">@entry.attempt</dd></div>
                    <div><dt>Turns</dt><dd class="numeric">@entry.turn_count</dd></div>
                    <div><dt>Tokens</dt><dd class="numeric">@entry.tokens</dd></div>
                  </dl>
                  <div class="ticket-message">
                    <span class="ticket-message-label">Last event</span>
                    <p class="runtime-message">@entry.last_event</p>
                  </div>
                </article>
              </li>
              @endfor
            </ul>
            @endif
          </div>
        </section>

        <section class="board-column queue-retrying" aria-labelledby="retrying-heading">
          <header class="board-column-header">
            <h2 class="title is-5 mb-0 queue-title" id="retrying-heading">
              <span class="queue-dot" aria-hidden="true"></span>Retrying
            </h2>
            <span class="tag is-warning is-light is-rounded" aria-label="@{view.retrying.len} retrying issues">@{view.retrying.len}</span>
          </header>
          <div class="board-column-body">
            @if view.retrying.len == 0
            <p class="board-empty">No retries are queued.</p>
            @else
            <ul class="ticket-list" aria-label="Retrying issues">
              @for entry in view.retrying
              <li>
                <article class="ticket-card">
                  <header class="ticket-card-header">
                    @if entry.issue_url != ''
                    <a class="issue-reference" href="@{entry.issue_url}" target="_blank" rel="noreferrer">@entry.issue_identifier</a>
                    @else
                    <span class="issue-reference">@entry.issue_identifier</span>
                    @endif
                    <span class="status-label status-retrying">Retrying</span>
                  </header>
                  <dl class="ticket-facts">
                    <div><dt>Attempt</dt><dd class="numeric">@entry.attempt</dd></div>
                    <div><dt>Due</dt><dd>@entry.due_at</dd></div>
                  </dl>
                  <div class="ticket-message">
                    <span class="ticket-message-label">Last error</span>
                    <p class="runtime-message">@entry.last_error</p>
                  </div>
                </article>
              </li>
              @endfor
            </ul>
            @endif
          </div>
        </section>

        <section class="board-column queue-blocked" aria-labelledby="blocked-heading">
          <header class="board-column-header">
            <h2 class="title is-5 mb-0 queue-title" id="blocked-heading">
              <span class="queue-dot" aria-hidden="true"></span>Blocked
            </h2>
            <span class="tag is-danger is-light is-rounded" aria-label="@{view.blocked.len} blocked issues">@{view.blocked.len}</span>
          </header>
          <div class="board-column-body">
            @if view.blocked.len == 0
            <p class="board-empty">No issues are blocked.</p>
            @else
            <ul class="ticket-list" aria-label="Blocked issues">
              @for entry in view.blocked
              <li>
                <article class="ticket-card">
                  <header class="ticket-card-header">
                    @if entry.issue_url != ''
                    <a class="issue-reference" href="@{entry.issue_url}" target="_blank" rel="noreferrer">@entry.issue_identifier</a>
                    @else
                    <span class="issue-reference">@entry.issue_identifier</span>
                    @endif
                    <span class="status-label status-blocked">Blocked</span>
                  </header>
                  <dl class="ticket-facts">
                    <div><dt>State</dt><dd>@entry.state</dd></div>
                    <div><dt>Attempt</dt><dd class="numeric">@entry.attempt</dd></div>
                  </dl>
                  <div class="ticket-message">
                    <span class="ticket-message-label">Reason</span>
                    <p class="runtime-message">@entry.reason</p>
                  </div>
                </article>
              </li>
              @endfor
            </ul>
            @endif
          </div>
        </section>
      </div>
```

Do not change the topbar, footer, stylesheet links, or Veb interpolation syntax.

- [ ] **Step 4: Format and run the focused test**

Run:

```sh
v fmt -verify symphony/statusweb
v symphony/statusweb/app_test.v
```

Expected: both commands exit `0`; the HTTP response contains board cards and no
summary-card or table markup.

- [ ] **Step 5: Commit the semantic board markup**

```sh
git add symphony/statusweb/templates/index.html symphony/statusweb/app_test.v
git diff --cached --check
git commit -m "refactor: render runtime queues as board cards"
```

Expected: one local commit containing only the template and focused HTML-test
changes.

---

### Task 2: Add the responsive horizontal board layout

**Files:**
- Modify: `symphony/statusweb/app_test.v:114-117`
- Modify: `symphony/statusweb/assets/symphony.css:1-287`

**Interfaces:**
- Consumes: the Task 1 class names and markup hierarchy.
- Produces: a three-column grid with `.operations-board` as the only horizontal scroller, fixed board-card spacing tokens, full-width desktop presentation, and `85vw` mobile snap columns.

- [ ] **Step 1: Add failing embedded-CSS assertions**

Immediately after the existing theme `content-type` assertion, add:

```v
assert theme.body.contains('--space-1: 0.25rem')
assert theme.body.contains('.operations-board')
assert theme.body.contains('grid-template-columns: repeat(3')
assert theme.body.contains('overflow-x: auto')
assert theme.body.contains('scroll-snap-type: x proximity')
assert theme.body.contains('minmax(85vw, 85vw)')
assert theme.body.contains('.ticket-card')
assert theme.body.contains('.board-empty')
assert !theme.body.contains('.status-card')
assert !theme.body.contains('.queue-panel .table')
```

- [ ] **Step 2: Run the focused test and verify the old stylesheet fails it**

Run:

```sh
v symphony/statusweb/app_test.v
```

Expected: FAIL because the embedded stylesheet lacks the board selectors and
still contains `.status-card` and table rules.

- [ ] **Step 3: Replace the layout stylesheet with the board system**

Preserve the existing color and Bulma tokens, then replace the layout rules in
`symphony/statusweb/assets/symphony.css` with these exact rules:

```css
:root {
  --symphony-canvas: #f4f0e7;
  --symphony-surface: #fffaf1;
  --symphony-surface-strong: #fffdf8;
  --symphony-navy: #18324b;
  --symphony-muted: #687783;
  --symphony-line: #ddd5c6;
  --symphony-running: #2f765c;
  --symphony-retrying: #9a6421;
  --symphony-blocked: #a64343;
  --space-1: 0.25rem;
  --space-2: 0.5rem;
  --space-3: 0.75rem;
  --space-4: 1rem;
  --space-5: 1.5rem;
  --space-6: 2rem;
  --space-7: 3rem;
  --bulma-family-primary: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  --bulma-body-background-color: var(--symphony-canvas);
  --bulma-body-color: var(--symphony-navy);
  --bulma-box-background-color: var(--symphony-surface);
  --bulma-box-color: var(--symphony-navy);
  --bulma-title-color: var(--symphony-navy);
  --bulma-subtitle-color: var(--symphony-muted);
}

html {
  background: var(--symphony-canvas);
}

body {
  min-height: 100vh;
  background: linear-gradient(180deg, #f8f4ec 0, var(--symphony-canvas) 24rem);
}

a:focus-visible,
.operations-board:focus-visible {
  outline: 3px solid #4c7e9f;
  outline-offset: 3px;
}

.dashboard-shell {
  padding: var(--space-6) var(--space-5) var(--space-7);
}

.dashboard-container {
  max-width: none;
}

.topbar {
  margin-bottom: var(--space-5);
}

.brand {
  align-items: center;
  color: var(--symphony-navy);
  display: inline-flex;
  font-weight: 800;
  gap: var(--space-3);
}

.brand-mark {
  align-items: center;
  background: var(--symphony-navy);
  border-radius: 0.7rem;
  box-shadow: 0 5px 8px rgb(24 50 75 / 16%);
  color: #fffaf1;
  display: inline-flex;
  height: 2.4rem;
  justify-content: center;
  width: 2.4rem;
}

.service-live {
  align-items: center;
  color: var(--symphony-running);
  display: inline-flex;
  font-size: 0.75rem;
  font-weight: 800;
  gap: var(--space-2);
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.service-dot,
.queue-dot {
  background: currentColor;
  border-radius: 999px;
  display: inline-block;
  height: 0.55rem;
  width: 0.55rem;
}

.service-dot {
  box-shadow: 0 0 0 4px rgb(47 118 92 / 11%);
}

.overview-header {
  align-items: end;
  display: grid;
  gap: var(--space-6);
  grid-template-columns: minmax(0, 1fr) minmax(17rem, auto);
  padding-bottom: var(--space-6);
}

.overview-copy {
  max-width: 46rem;
}

.overview-title {
  font-size: 2rem;
  letter-spacing: -0.03em;
  line-height: 1.1;
  text-wrap: balance;
}

.metadata-box {
  background: var(--symphony-surface);
  border: 1px solid var(--symphony-line);
  border-radius: 0.75rem;
  min-width: 17rem;
  padding: var(--space-4);
}

.metadata-row {
  color: var(--symphony-muted);
  display: flex;
  font-size: 0.8rem;
  gap: var(--space-5);
  justify-content: space-between;
}

.metadata-row + .metadata-row {
  margin-top: var(--space-2);
}

.metadata-row strong {
  color: var(--symphony-navy);
}

.operations-board {
  display: grid;
  gap: var(--space-4);
  grid-template-columns: repeat(3, minmax(20rem, 1fr));
  overflow-x: auto;
  overscroll-behavior-inline: contain;
  padding: var(--space-1) var(--space-1) var(--space-3);
  scroll-snap-type: x proximity;
}

.board-column {
  background: rgb(255 250 241 / 55%);
  border: 1px solid var(--symphony-line);
  border-radius: 0.875rem;
  display: flex;
  flex-direction: column;
  min-height: 28rem;
  min-width: 20rem;
  overflow: hidden;
  scroll-snap-align: start;
}

.board-column-header {
  align-items: center;
  background: var(--symphony-surface-strong);
  border-bottom: 1px solid var(--symphony-line);
  display: flex;
  justify-content: space-between;
  padding: var(--space-4);
}

.queue-title {
  align-items: center;
  display: flex;
  gap: var(--space-2);
}

.queue-running .queue-title {
  color: var(--symphony-running);
}

.queue-retrying .queue-title {
  color: var(--symphony-retrying);
}

.queue-blocked .queue-title {
  color: var(--symphony-blocked);
}

.board-column-body {
  flex: 1;
  padding: var(--space-3);
}

.ticket-list {
  display: grid;
  gap: var(--space-3);
  list-style: none;
  margin: 0;
  padding: 0;
}

.ticket-card {
  background: var(--symphony-surface-strong);
  border: 1px solid var(--symphony-line);
  border-radius: 0.625rem;
  padding: var(--space-4);
}

.ticket-card-header {
  align-items: center;
  display: flex;
  gap: var(--space-3);
  justify-content: space-between;
}

.issue-reference {
  color: var(--symphony-navy);
  font-weight: 800;
  overflow-wrap: anywhere;
}

.issue-reference:hover {
  color: var(--bulma-link-text);
}

.status-label {
  border-radius: 999px;
  flex: none;
  font-size: 0.7rem;
  font-weight: 800;
  padding: var(--space-1) var(--space-2);
}

.status-running {
  background: rgb(47 118 92 / 12%);
  color: var(--symphony-running);
}

.status-retrying {
  background: rgb(154 100 33 / 12%);
  color: var(--symphony-retrying);
}

.status-blocked {
  background: rgb(166 67 67 / 12%);
  color: var(--symphony-blocked);
}

.ticket-facts {
  display: grid;
  gap: var(--space-2) var(--space-4);
  grid-template-columns: repeat(2, minmax(0, 1fr));
  margin-top: var(--space-4);
}

.ticket-facts > div {
  min-width: 0;
}

.ticket-facts dt,
.ticket-message-label {
  color: var(--symphony-muted);
  font-size: 0.7rem;
  font-weight: 800;
  letter-spacing: 0.05em;
  text-transform: uppercase;
}

.ticket-facts dd {
  color: var(--symphony-navy);
  margin: var(--space-1) 0 0;
  overflow-wrap: anywhere;
}

.ticket-message {
  border-top: 1px solid var(--symphony-line);
  margin-top: var(--space-4);
  padding-top: var(--space-3);
}

.runtime-message {
  color: var(--symphony-muted);
  margin-top: var(--space-1);
  overflow-wrap: anywhere;
}

.numeric {
  font-variant-numeric: tabular-nums;
}

.board-empty {
  color: var(--symphony-muted);
  margin: 0;
  padding: var(--space-5) var(--space-3);
  text-align: center;
}

.dashboard-footer {
  color: var(--symphony-muted);
  font-size: 0.8rem;
  padding-top: var(--space-6);
  text-align: center;
}

@media (max-width: 70rem) {
  .operations-board {
    grid-template-columns: repeat(3, minmax(20rem, 22rem));
  }
}

@media (max-width: 768px) {
  .dashboard-shell {
    padding: var(--space-5) var(--space-3) var(--space-6);
  }

  .overview-header {
    align-items: stretch;
    gap: var(--space-4);
    grid-template-columns: 1fr;
    padding-bottom: var(--space-5);
  }

  .metadata-box {
    min-width: 0;
    width: 100%;
  }

  .operations-board {
    grid-template-columns: repeat(3, minmax(85vw, 85vw));
    scroll-snap-type: x mandatory;
  }

  .board-column {
    min-height: 24rem;
    min-width: 0;
  }
}

@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    scroll-behavior: auto !important;
    transition-duration: 0.01ms !important;
  }

  .operations-board {
    scroll-snap-type: none;
  }
}
```

Do not add a custom scrollbar, JavaScript, an external font, or a runtime asset
dependency.

- [ ] **Step 4: Run the focused test and the layout detector**

Run:

```sh
v fmt -verify symphony/statusweb
v symphony/statusweb/app_test.v
node /Users/benj/.agents/skills/impeccable/scripts/detect.mjs --json --scope layout symphony/statusweb/templates/index.html symphony/statusweb/assets/symphony.css
```

Expected: both V commands exit `0`; the detector returns `[]`. If the detector
reports a selector/value, fix that exact finding and repeat all three commands.

- [ ] **Step 5: Commit the responsive board styling**

```sh
git add symphony/statusweb/assets/symphony.css symphony/statusweb/app_test.v
git diff --cached --check
git commit -m "style: lay out runtime queues as horizontal board"
```

Expected: one local commit containing only CSS and embedded-CSS-test changes.

---

### Task 3: Verify responsive behavior and full conformance

**Files:**
- Verify: `symphony/statusweb/templates/index.html`
- Verify: `symphony/statusweb/assets/symphony.css`
- Verify: `symphony/statusweb/app_test.v`
- Verify unchanged: `symphony/statusweb/app.v`

**Interfaces:**
- Consumes: the completed server-rendered board and existing Symphony CLI.
- Produces: fresh test/build evidence and a visually verified local dashboard; no new production interface.

- [ ] **Step 1: Run focused and full static verification**

Run:

```sh
v fmt -verify bin symphony
v vet bin symphony
v test symphony
git diff --check
```

Expected: formatting exits `0`; vet exits `0` with only the repository's
pre-existing missing-public-documentation warnings; all V test files pass; the
diff check prints nothing.

- [ ] **Step 2: Build and smoke-test the production binary**

Run:

```sh
v -prod -o build/symphony bin/symphony
./build/symphony version
```

Expected: the build exits `0` and version prints `symphony 0.1.0-dev`.

- [ ] **Step 3: Run a safe empty-queue visual fixture**

Create `/tmp/symphony-board-visual/WORKFLOW.md` with:

```markdown
---
tracker:
  kind: file
  provider:
    root: ./tickets
  active_states:
    - Todo
  terminal_states:
    - Done
polling:
  interval_ms: 30000
workspace:
  root: ./workspaces
server:
  port: 18089
---
Inspect the ticket and report status.
```

Create the adjacent empty `tickets` directory, then run:

```sh
./build/symphony run /tmp/symphony-board-visual/WORKFLOW.md --web-host 127.0.0.1 --web-port 18089
```

Expected: Symphony starts at `http://127.0.0.1:18089/` without dispatching an
agent because the ticket directory is empty.

- [ ] **Step 4: Inspect desktop, tablet, and mobile layouts in a browser**

At widths `1440x900`, `900x800`, and `390x844`, verify:

```text
1440px: Running, Retrying, and Blocked are simultaneously visible and equal width.
900px: The board scrolls horizontally as one region; no nested table/card scroller appears.
390px: One 85vw column is primary, the next column peeks into view, and snapping preserves column alignment.
All widths: Metadata stays readable, count tags remain inside headers, empty states stay compact, focus outlines are visible, and no text escapes a card or column.
```

For card-density inspection without mutating Symphony state, use browser
developer tools to replace one `.board-column-body` temporarily with:

```html
<ul class="ticket-list">
  <li>
    <article class="ticket-card">
      <header class="ticket-card-header">
        <a class="issue-reference" href="#">SYM-VISUAL-123</a>
        <span class="status-label status-running">Running</span>
      </header>
      <dl class="ticket-facts">
        <div><dt>State</dt><dd>In Progress</dd></div>
        <div><dt>Attempt</dt><dd class="numeric">2</dd></div>
        <div><dt>Turns</dt><dd class="numeric">12</dd></div>
        <div><dt>Tokens</dt><dd class="numeric">128K</dd></div>
      </dl>
      <div class="ticket-message">
        <span class="ticket-message-label">Last event</span>
        <p class="runtime-message">A deliberately long event message verifies wrapping without widening the board column or creating a nested horizontal scroller.</p>
      </div>
    </article>
  </li>
</ul>
```

Expected: the injected card remains legible at every width and introduces no
overflow beyond the board-level horizontal scroll.

- [ ] **Step 5: Stop the fixture and confirm repository state**

Stop Symphony with `Ctrl-C`, then run:

```sh
git status --short
git log -4 --oneline
```

Expected: graceful shutdown; no uncommitted source changes; the local history
contains the design, semantic-board, and responsive-style commits. Do not push
those commits.
