# V Symphony Spec Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the V implementation into Core Conformance with the current OpenAI Symphony Draft v1 specification and complete the HTTP extension already shipped by this project.

**Architecture:** Preserve one channel-owned orchestrator state. Make the tracker seam real by injecting the selected adapter into orchestration and keeping provider configuration inside the adapter. Stream Codex updates through a small callback into the orchestrator authority, then project that state into logs and the optional `veb` surface.

**Tech Stack:** V 0.5.2 (`f915d3e`), V standard library, `yaml`, `json2`, `veb`, POSIX process groups, Codex app-server 0.145 schema.

## Global Constraints

- Implement V only; the Rust PRD remains documentation-only.
- Do not add DBOS, Kameo, Photon, a scheduler database, or another coroutine runtime.
- Do not initialize a Git repository or create a GitHub repository, remote, pull request, or release.
- Follow the current upstream `SPEC.md`; OPTIONAL SSH workers and persistent retry/session state remain intentionally unimplemented extensions.
- Use TDD: add each behavioral test first, run it to observe the expected failure, then implement the smallest conforming change.
- Keep orchestration provider-neutral; only the selected adapter interprets provider configuration and routing semantics.

---

### Task 1: Spec-aligned tracker domain and workflow configuration

**Files:**
- Modify: `symphony/domain/types.v`
- Modify: `symphony/domain/types_test.v`
- Modify: `symphony/workflow/config.v`
- Modify: `symphony/workflow/loader_test.v`
- Modify: `symphony/scheduler/policy.v`
- Modify: `symphony/scheduler/policy_test.v`
- Modify: `WORKFLOW.example.md`
- Modify: `WORKFLOW.md`

**Interfaces:**
- Produces: `domain.Issue.dispatchable bool` and opaque JSON-safe `native_ref` data.
- Produces: `workflow.TrackerConfig.provider map[string]yaml.Any`, retaining unknown adapter keys.
- Produces: normalized Codex approval and sandbox JSON payloads that preserve scalar or object configuration.

- [ ] **Step 1: Add failing domain and scheduler tests**

  Assert that `dispatchable=false` prevents eligibility and routability without reconstructing Linear assignment or blocker semantics.

- [ ] **Step 2: Run the focused tests and observe the expected failures**

  Run: `v test symphony/domain symphony/scheduler`

- [ ] **Step 3: Implement explicit normalized tracker fields**

  Add `dispatchable` and `native_ref`, then make scheduler policy depend only on `dispatchable`, core state/label/claim rules, and capacity.

- [ ] **Step 4: Add failing workflow tests for `tracker.provider` and rich Codex policy objects**

  Cover unknown nested provider keys, `$VAR` secrets, scalar backward compatibility, and object-shaped approval/sandbox policies.

- [ ] **Step 5: Run the workflow tests and observe the expected failures**

  Run: `v test symphony/workflow`

- [ ] **Step 6: Implement typed core config plus preserved adapter-owned provider data**

  Parse the current upstream shape, preserve unknown provider values, resolve only documented adapter secrets in the adapter, and emit protocol-ready JSON for Codex-owned policy values.

- [ ] **Step 7: Update the example workflows and rerun focused tests**

  Run: `v test symphony/domain symphony/scheduler symphony/workflow`

### Task 2: Real tracker seam and conforming Linear adapter

**Files:**
- Modify: `symphony/tracker/port.v`
- Create: `symphony/tracker/factory.v`
- Modify: `symphony/tracker/linear.v`
- Modify: `symphony/tracker/linear_test.v`
- Create: `docs/tracker-linear.md`

**Interfaces:**
- Produces: `Tracker.fetch_issues_by_states([]string) ![]domain.Issue`.
- Produces: `Tracker.fetch_issues_by_ids([]string) ![]domain.Issue`.
- Produces: `Tracker.secret_environment_names() []string`.
- Produces: `tracker.new_adapter(config workflow.TrackerConfig) !Tracker`.

- [ ] **Step 1: Add failing adapter-contract tests**

  Cover empty requests without validation/transport, duplicate opaque IDs, explicit `dispatchable`, `native_ref`, stable error categories, malformed state-list omission, and strict malformed ID refresh.

- [ ] **Step 2: Run the Linear tests and observe the expected failures**

  Run: `v test symphony/tracker`

- [ ] **Step 3: Implement the small tracker interface and adapter factory**

  Remove candidate-specific and state-string-specific methods from the seam. Select `linear` through the factory and return `unsupported_tracker_kind` for other values.

- [ ] **Step 4: Move Linear configuration and normalization behind the adapter**

  Parse `endpoint`, `api_key`, `project_slug`, and optional `assignee` from `tracker.provider`; derive routing into `dispatchable`; keep credentials out of core configuration decisions; map errors to the documented portable categories.

- [ ] **Step 5: Publish the Linear adapter profile and rerun focused tests**

  Run: `v test symphony/tracker symphony/workflow symphony/scheduler`

### Task 3: Provider-neutral orchestration and live runtime state

**Files:**
- Modify: `symphony/orchestrator/service.v`
- Modify: `symphony/orchestrator/runtime.v`
- Modify: `symphony/orchestrator/state.v`
- Modify: `symphony/orchestrator/runtime_test.v`
- Modify: `symphony/orchestrator/state_test.v`
- Create: `symphony/orchestrator/service_test.v`

**Interfaces:**
- Consumes: `tracker.Tracker` at every poll, reconciliation, retry, and continuation path.
- Produces: `Runtime.reconfigure(max_concurrent int, max_backoff_ms int)`.
- Produces: `Runtime.update_session(issue_id string, update domain.SessionUpdate)`.
- Produces: live snapshots with session identity, PID, turn count, activity, URL, message, tokens, and active runtime.

- [ ] **Step 1: Add failing state tests for live updates and reconfiguration**

  Verify token deltas are not double-counted, active runtime is included, activity updates stall basis, and new capacity/backoff limits affect future transitions.

- [ ] **Step 2: Run orchestrator state tests and observe the expected failures**

  Run: `v test symphony/orchestrator/state_test.v symphony/orchestrator/runtime_test.v`

- [ ] **Step 3: Implement channel-owned session updates and dynamic configuration**

  Extend the existing command loop; workers continue to submit immutable events and never mutate state directly.

- [ ] **Step 4: Add a failing whole-poll integration test with a fake tracker**

  Exercise reconcile, candidate read, claim, dispatch, and worker completion without Linear credentials.

- [ ] **Step 5: Run the service test and observe the expected failure**

  Run: `v test symphony/orchestrator/service_test.v`

- [ ] **Step 6: Inject the tracker interface through orchestration**

  Build an adapter snapshot after each valid workflow reload, pass the same snapshot through a worker session, use active states for polling, and reconfigure runtime limits before dispatch.

- [ ] **Step 7: Guarantee `after_run` after every prepared attempt and rerun orchestrator tests**

  Run: `v test symphony/orchestrator`

### Task 4: Current Codex app-server protocol and event streaming

**Files:**
- Modify: `symphony/codex/protocol.v`
- Modify: `symphony/codex/protocol_test.v`
- Modify: `symphony/codex/client.v`
- Modify: `symphony/codex/client_test.v`

**Interfaces:**
- Produces: schema-valid initialize/thread/turn requests for installed Codex app-server 0.145.
- Produces: `run_session(..., on_update SessionUpdateHandler) !ClientResult`.
- Produces: JSON-RPC failure responses for unsupported `item/tool/call` requests while the turn continues.

- [ ] **Step 1: Add failing protocol tests**

  Cover experimental capability opt-in, object-shaped approval/sandbox pass-through, `item/tool/call`, structured tool failure responses, session IDs, absolute token totals, rate limits, and humanized bounded messages.

- [ ] **Step 2: Run protocol tests and observe the expected failures**

  Run: `v test symphony/codex/protocol_test.v`

- [ ] **Step 3: Implement protocol encoding and interpretation against generated schemas**

  Use `bash -lc`, 10 MB JSONL limits, generic JSON values for Codex-owned policies, and keep diagnostics separate from stdout.

- [ ] **Step 4: Add failing client tests for live callbacks and unsupported tools**

  Fake app-server scripts must prove updates arrive before completion and that a rejected dynamic tool call receives `success:false` without ending the session.

- [ ] **Step 5: Run client tests and observe the expected failures**

  Run: `v test symphony/codex/client_test.v`

- [ ] **Step 6: Implement streaming callbacks and safe server-request responses**

  Forward session/turn/notification/token/rate events, maintain absolute token totals, preserve timeout/cancellation cleanup, and continue after unsupported dynamic tool requests.

- [ ] **Step 7: Rerun all Codex tests**

  Run: `v test symphony/codex`

### Task 5: Complete the shipped HTTP and CLI extensions

**Files:**
- Modify: `symphony/statusweb/app.v`
- Modify: `symphony/statusweb/app_test.v`
- Modify: `symphony/app/cli.v`
- Modify: `symphony/app/app.v`
- Modify: `symphony/app/app_test.v`
- Modify: `symphony/observability/log.v`
- Modify: `symphony/observability/log_test.v`

**Interfaces:**
- Produces: positional workflow path support and `--port` override, while retaining compatible aliases.
- Produces: `server.port` workflow enablement, including port `0`.
- Produces: baseline `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh` JSON shapes and error envelopes.
- Produces: structured session-aware lifecycle logs.

- [ ] **Step 1: Add failing CLI/config tests**

  Cover positional paths, default `WORKFLOW.md`, `--port 0`, CLI precedence over `server.port`, and clean missing-path failures.

- [ ] **Step 2: Run app/workflow tests and observe the expected failures**

  Run: `v test symphony/app symphony/workflow`

- [ ] **Step 3: Implement CLI and listener selection**

  Start the HTTP extension when either source supplies a port and preserve loopback as the default host.

- [ ] **Step 4: Add failing status API and logging tests**

  Assert recommended state fields, issue lookup by human identifier, 404 JSON envelopes, refresh 202 payload, active runtime, and `session_id` in session logs.

- [ ] **Step 5: Run focused tests and observe the expected failures**

  Run: `v test symphony/statusweb symphony/observability`

- [ ] **Step 6: Implement immutable HTTP projections and structured session logs**

  Keep all scheduling decisions outside `veb`; use bounded state projections and snapshot timeouts.

- [ ] **Step 7: Rerun extension tests**

  Run: `v test symphony/app symphony/statusweb symphony/observability symphony/workflow`

### Task 6: Conformance audit, documentation, and release verification

**Files:**
- Modify: `README.md`
- Modify: `docs/prds/v-symphony-prd.md`
- Modify: `docs/symphony-conformance.md`
- Create: `docs/tutorial.md`

**Interfaces:**
- Produces: an exact Core/Extension/Real-Integration conformance matrix with no hidden gap list.

- [ ] **Step 1: Audit Sections 17 and 18 of the upstream specification line by line**

  Record every Core item as implemented with a test pointer. Mark OPTIONAL SSH workers, persistence, provider-native tools, and live credential smoke checks as unselected or operational profiles rather than core gaps.

- [ ] **Step 2: Update operator documentation and adapter configuration examples**

  Document the Linear adapter profile link, current Codex schema target, positional CLI path, `--port`, status routes, trust posture, and secret handling.

- [ ] **Step 3: Add a beginner-oriented end-to-end tutorial**

  Explain that `SYMPHONY_REPOSITORY_URL` is the Git clone URL for the repository agents should edit, with SSH and HTTPS examples. Cover installing V/Codex, obtaining a Linear key and project slug, configuring environment variables safely, copying and editing `WORKFLOW.example.md`, validating, running one poll, running continuously, opening the dashboard, expected issue state/label routing, stopping cleanly, and common setup failures.

- [ ] **Step 4: Run formatting, vetting, tests, and production build from scratch**

  Run:

  ```sh
  v fmt -w bin symphony
  v fmt -verify bin symphony
  v vet bin symphony
  v test symphony
  v -prod -o build/symphony bin/symphony
  build/symphony version
  build/symphony validate WORKFLOW.example.md
  ```

- [ ] **Step 5: Perform the required code-review skill against the complete filesystem diff**

  Because the user prohibited repository initialization, review the touched files and test evidence directly instead of committing or creating a branch.

- [ ] **Step 6: Re-run the full verification after review fixes**

  Repeat the complete command set and confirm no `.git`, `Cargo.toml`, or Rust source files were introduced.
