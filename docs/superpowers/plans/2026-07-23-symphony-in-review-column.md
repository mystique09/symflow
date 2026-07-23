# Symphony In Review UI Column Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render active In Review tickets in a dedicated dashboard column without changing dispatch or API behavior.

**Architecture:** Partition `RuntimeSnapshot.running` only while building the private dashboard view. Render both partitions as running-card projections, place the new Veb section after Blocked, and expand the responsive grid from four to five columns.

**Tech Stack:** V 0.5.2, Veb templates, embedded Bulma/CSS/JavaScript.

## Global Constraints

- Exact order: Running, Retrying, Blocked, In Review, Done.
- The status API and orchestrator remain unchanged.
- In Review matching uses the existing normalized-name semantics.
- Retrying and Blocked retain precedence over tracker state.
- Do not push.

---

### Task 1: Dashboard partition and semantic column

**Files:**
- Modify: `symphony/statusweb/app.v`
- Modify: `symphony/statusweb/templates/index.html`
- Modify: `symphony/statusweb/assets/symphony.css`
- Test: `symphony/statusweb/app_test.v`

**Interfaces:**
- Consumes: `domain.RuntimeSnapshot.running []domain.RunningSnapshot`
- Produces: `DashboardView.in_review []DashboardRunningRow`

- [ ] **Step 1: Write failing tests**

```v
view := dashboard_view(domain.RuntimeSnapshot{
	running: [
		domain.RunningSnapshot{issue_identifier: 'SYM-1', state: 'In Review'},
		domain.RunningSnapshot{issue_identifier: 'SYM-2', state: 'Todo'},
	]
})
assert view.running.map(it.issue_identifier) == ['SYM-2']
assert view.in_review.map(it.issue_identifier) == ['SYM-1']
```

The HTTP test must also assert the five column classes occur in the required
order, the In Review empty state renders, and CSS contains `repeat(5`.

- [ ] **Step 2: Verify tests fail**

Run:

```sh
v test symphony/statusweb
```

Expected: compilation or assertion failure because `in_review` is absent.

- [ ] **Step 3: Implement the minimal partition and column**

Create one helper that maps a running snapshot into `DashboardRunningRow`.
During `dashboard_view`, append normalized `In Review` entries to `in_review`
and all others to `running`. Render the new section between Blocked and Done,
using the same card facts and `Running` badge.

- [ ] **Step 4: Verify focused tests pass**

Run:

```sh
v test symphony/statusweb
node --check symphony/statusweb/assets/symphony.js
```

Expected: the status-web suite and JavaScript syntax check pass.

- [ ] **Step 5: Commit**

```sh
git add symphony/statusweb/app.v symphony/statusweb/templates/index.html \
  symphony/statusweb/assets/symphony.css symphony/statusweb/app_test.v
git commit -m "feat: add in-review dashboard column"
```

### Task 2: Full verification

**Files:**
- Modify if required: `docs/tutorial.md`

**Interfaces:**
- Consumes: the completed five-column dashboard.

- [ ] **Step 1: Format and run all checks**

```sh
v fmt -w bin symphony
v fmt -verify bin symphony
v vet bin symphony
v test symphony
node --check symphony/statusweb/assets/symphony.js
```

Expected: formatting and tests pass; vet exits zero with only the project's
existing documentation warnings.

- [ ] **Step 2: Build**

```sh
v -prod -o build/symphony bin/symphony
```

Expected: the optimized binary builds successfully.

- [ ] **Step 3: Live browser verification**

Run an isolated fixture with one Todo running card, one In Review running card,
and one completed card. At 2048 by 1080, verify the exact five-column order,
that each issue appears once, and that browser polling updates without reload.
