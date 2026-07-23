# Symphony Durable Done Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a durable fourth Done column backed by completed tracker records and stop completed agents from asking branch-disposition questions.

**Architecture:** Extend the tracker port with a completed-issue query, synchronize those issues into a display-only runtime collection on every poll, and expose that collection through the status API and Veb template. Keep completion separate from claims so history cannot consume execution capacity. Add an explicit workspace prompt rule that leaves finished branches untouched.

**Tech Stack:** V 0.5.2, Veb templates, embedded Bulma/CSS/JavaScript, V channels, YAML file tracker, GraphQL tracker adapters.

## Global Constraints

- The board always renders Running, Retrying, Blocked, and Done in that order.
- File completion is authoritative only when `dispatch_status: completed`.
- GitHub Project and Linear completion is authoritative only in configured terminal states.
- Existing blocked tickets are not silently reclassified.
- Real approval and user-input requests remain blocked.
- Do not push commits or branches.

---

### Task 1: Completed tracker query

**Files:**
- Modify: `symphony/domain/types.v`
- Modify: `symphony/tracker/port.v`
- Modify: `symphony/tracker/file.v`
- Modify: `symphony/tracker/linear.v`
- Modify: `symphony/tracker/github_project.v`
- Test: `symphony/tracker/file_test.v`
- Test: `symphony/tracker/linear_test.v`
- Test: `symphony/tracker/github_project_test.v`

**Interfaces:**
- Produces: `Tracker.fetch_completed_issues(terminal_states []string) ![]domain.Issue`
- Produces: `Issue.completed_at string`

- [ ] **Step 1: Write failing adapter tests**

```v
completed := client.fetch_completed_issues(['Done'])!
assert completed.map(it.identifier) == ['SYM-401']
assert completed[0].completed_at == '2026-07-23T01:00:00Z'
```

For GitHub Project and Linear fixtures, assert that the same method returns
only issues whose normalized state appears in `terminal_states`.

- [ ] **Step 2: Verify the tests fail**

Run:

```sh
v test symphony/tracker
```

Expected: compilation fails because `fetch_completed_issues` and
`Issue.completed_at` do not exist.

- [ ] **Step 3: Add the port and adapter implementations**

```v
pub interface Tracker {
	fetch_completed_issues(terminal_states []string) ![]domain.Issue
}
```

The file adapter loads only `dispatch_status == 'completed'` tickets and maps
frontmatter `completed_at`. Network-backed adapters delegate to their existing
state query with the supplied terminal states.

- [ ] **Step 4: Verify adapter tests pass**

Run:

```sh
v test symphony/tracker
```

Expected: all tracker tests pass.

- [ ] **Step 5: Commit**

```sh
git add symphony/domain/types.v symphony/tracker/port.v symphony/tracker/file.v \
  symphony/tracker/linear.v symphony/tracker/github_project.v \
  symphony/tracker/file_test.v symphony/tracker/linear_test.v \
  symphony/tracker/github_project_test.v
git commit -m "feat: expose completed tracker tickets"
```

### Task 2: Completed runtime synchronization

**Files:**
- Modify: `symphony/domain/types.v`
- Modify: `symphony/orchestrator/state.v`
- Modify: `symphony/orchestrator/runtime.v`
- Modify: `symphony/orchestrator/service.v`
- Test: `symphony/orchestrator/state_test.v`
- Test: `symphony/orchestrator/runtime_test.v`
- Test: `symphony/orchestrator/service_test.v`

**Interfaces:**
- Consumes: `Tracker.fetch_completed_issues(terminal_states []string) ![]domain.Issue`
- Produces: `CompletedSnapshot`
- Produces: `Runtime.replace_completed(issues []domain.Issue)`
- Produces: `Runtime.complete(issue domain.Issue, completed_at string)`

- [ ] **Step 1: Write failing state and service tests**

```v
state.replace_completed([
	domain.Issue{id: '2', identifier: 'SYM-2', state: 'Done'},
	domain.Issue{id: '1', identifier: 'SYM-1', state: 'Done'},
])
snapshot := state.snapshot(1_000)
assert snapshot.completed.map(it.issue_identifier) == ['SYM-1', 'SYM-2']
```

Add a service test proving a persisted file completion appears in
`runtime.snapshot(...).completed` without consuming a claim.

- [ ] **Step 2: Verify the tests fail**

Run:

```sh
v test symphony/orchestrator
```

Expected: compilation fails because completed runtime APIs do not exist.

- [ ] **Step 3: Implement display-only completed state**

```v
struct CompletedEntry {
	issue        domain.Issue
	completed_at string
}
```

`replace_completed` atomically rebuilds this map. `complete` releases active,
retrying, or blocked ownership before adding one immediate completion.
`poll_and_dispatch` refreshes completed issues before candidate dispatch.

- [ ] **Step 4: Verify orchestrator tests pass**

Run:

```sh
v test symphony/orchestrator
```

Expected: all orchestrator tests pass.

- [ ] **Step 5: Commit**

```sh
git add symphony/domain/types.v symphony/orchestrator/state.v \
  symphony/orchestrator/runtime.v symphony/orchestrator/service.v \
  symphony/orchestrator/state_test.v symphony/orchestrator/runtime_test.v \
  symphony/orchestrator/service_test.v
git commit -m "feat: retain durable completed runtime state"
```

### Task 3: Done API and board column

**Files:**
- Modify: `symphony/statusweb/app.v`
- Modify: `symphony/statusweb/templates/index.html`
- Modify: `symphony/statusweb/assets/symphony.css`
- Test: `symphony/statusweb/app_test.v`

**Interfaces:**
- Consumes: `RuntimeSnapshot.completed []CompletedSnapshot`
- Produces: `ApiState.completed []ApiCompleted`
- Produces: `ApiCounts.completed int`

- [ ] **Step 1: Write failing API and template tests**

```v
snapshot := domain.RuntimeSnapshot{
	completed: [domain.CompletedSnapshot{
		issue_id: 'done-1'
		issue_identifier: 'SYM-1'
		state: 'Done'
	}]
}
assert api_state(snapshot).counts.completed == 1
assert dashboard.body.contains('class="board-column queue-done"')
assert dashboard.body.contains('No issues are done yet.')
```

Also assert completed issue lookup, API response bounding, four column classes,
and CSS `repeat(4, ...)`.

- [ ] **Step 2: Verify status-web tests fail**

Run:

```sh
v test symphony/statusweb
```

Expected: compilation or assertion failure because Done is absent.

- [ ] **Step 3: Implement the API mapping and semantic column**

Add `ApiCompleted`, `DashboardCompletedRow`, completed lookup, counts, bounded
snapshot mapping, and a fourth Veb section. Add `--symphony-done`, `.queue-done`,
and `.status-done` styles and change desktop grids from three to four columns.

- [ ] **Step 4: Verify status-web tests pass**

Run:

```sh
v test symphony/statusweb
node --check symphony/statusweb/assets/symphony.js
```

Expected: all status-web tests pass and JavaScript syntax is valid.

- [ ] **Step 5: Commit**

```sh
git add symphony/statusweb/app.v symphony/statusweb/templates/index.html \
  symphony/statusweb/assets/symphony.css symphony/statusweb/app_test.v
git commit -m "feat: add done column to status board"
```

### Task 4: End-of-task branch policy

**Files:**
- Modify: `symphony/orchestrator/service.v`
- Test: `symphony/orchestrator/service_test.v`

**Interfaces:**
- Consumes: `prepend_workspace_git_policy(rendered string, branch string, base_branch string) string`

- [ ] **Step 1: Write the failing prompt test**

```v
prompt := prepend_workspace_git_policy('Implement.', 'agent/SYM-1', 'main')
assert prompt.contains('Leave the completed issue branch as-is')
assert prompt.contains('Do not ask how to merge, push, or clean up the branch')
```

- [ ] **Step 2: Verify the test fails**

Run:

```sh
v symphony/orchestrator/service_test.v
```

Expected: assertion failure because the policy text is absent.

- [ ] **Step 3: Add the minimal policy text**

Append two explicit bullets to the existing Git workspace policy. Do not alter
the protocol classification for real operator-input requests.

- [ ] **Step 4: Verify the test passes**

Run:

```sh
v symphony/orchestrator/service_test.v
```

Expected: all service tests pass.

- [ ] **Step 5: Commit**

```sh
git add symphony/orchestrator/service.v symphony/orchestrator/service_test.v
git commit -m "fix: finish completed issue branches without handoff"
```

### Task 5: Full verification and live UI

**Files:**
- Modify if required: `docs/tracker-file.md`
- Modify if required: `docs/tutorial.md`

**Interfaces:**
- Consumes: the completed tracker, runtime, API, and dashboard behavior from Tasks 1-4.

- [ ] **Step 1: Format and verify formatting**

```sh
v fmt -w bin symphony
v fmt -verify bin symphony
```

Expected: no formatting errors.

- [ ] **Step 2: Run static checks and tests**

```sh
v vet bin symphony
v test symphony
node --check symphony/statusweb/assets/symphony.js
```

Expected: vet reports no errors, all V tests pass, and JavaScript syntax is
valid.

- [ ] **Step 3: Build the production binary**

```sh
mkdir -p build
v -prod -o build/symphony bin/symphony
```

Expected: `build/symphony` is produced successfully.

- [ ] **Step 4: Verify the live board**

Run the production binary against a temporary file tracker containing one
completed ticket. Open the local dashboard and confirm:

- Running, Retrying, Blocked, and Done are simultaneously present at desktop width.
- The Done ticket appears in Done and nowhere else.
- Polling refresh updates the board without a manual reload.
- Horizontal scrolling preserves all columns at narrow width.

- [ ] **Step 5: Commit documentation or verification fixes**

```sh
git add docs/tracker-file.md docs/tutorial.md
git commit -m "docs: explain completed ticket visibility"
```

Skip this commit when no documentation changes are required.
