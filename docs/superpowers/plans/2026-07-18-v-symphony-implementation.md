# V Symphony Implementation Plan

> Execute this plan only for the V implementation. The Rust PRD remains documentation-only.

**Goal:** Build a local, testable V 0.5.2 Symphony daemon that implements the upstream service's core workflow, scheduling, workspace, tracker, Codex JSONL, orchestration, CLI, and optional loopback `veb` status behavior without DBOS or a persistent scheduler.

**Architecture:** A root V module anchors one executable composition root under `bin/symphony` and focused modules under `symphony/`. Pure policy lives in `scheduler`; integration modules own tracker HTTP, filesystem/process work, and Codex protocol details. One orchestrator thread exclusively owns mutable claims, running attempts, retries, blocked entries, and telemetry. Other threads exchange typed commands and immutable snapshots through channels.

**Toolchain:** V 0.5.2 at commit `f915d3e`, V standard-library `yaml`, `x.json2`, `net.http`, `os.Process`, `context`, channels/select, and `veb`.

## Verification Contract

Each behavior task follows red-green-refactor:

1. Add or change the public-interface test first.
2. Run the narrow test and observe a compile or assertion failure caused by the missing behavior.
3. Add the minimum production implementation.
4. Re-run the narrow test until it passes.
5. Run `v fmt -verify` on touched V files before moving on.

Final verification is:

```sh
v fmt -verify bin symphony
v vet bin symphony
v test symphony
v -o build/symphony bin/symphony
./build/symphony validate --workflow WORKFLOW.example.md
./build/symphony doctor --workflow WORKFLOW.example.md
```

The default suite must not require network access, a Linear token, or a Codex login.

## Task 1: Establish the V project contract

**Files:**

- Create: `.vvmrc`
- Create: `v.mod`
- Create: `WORKFLOW.example.md`
- Modify: `README.md`
- Create: `bin/symphony/main.v`

**Steps:**

1. Pin `.vvmrc` to the installed compiler version `0.5.2`; document commit `f915d3e` in the README because `.vvmrc` selects versions, not arbitrary commits.
2. Define root module `symphony` in `v.mod` with the supported V version and no third-party dependencies.
3. Add a realistic Linear-oriented example workflow containing YAML front matter and a Markdown prompt body, but no literal secret.
4. Document architecture, trust boundary, build/test commands, configuration, and the fact that there is no DBOS or durable state.
5. Add a minimal CLI entry point whose initial `version` command compiles; later tasks replace command stubs with real composition.

## Task 2: Define normalized domain contracts

**Files:**

- Create: `symphony/domain/types.v`
- Create: `symphony/domain/types_test.v`

**Behavior under test:**

- Tracker state and labels are normalized without changing opaque IDs.
- Issue snapshots expose stable identifiers, priority, creation time, assignment, blockers, and dispatchability inputs.
- Attempt outcomes distinguish success, failure, blocked, canceled, timed out, stalled, and process exit.
- Runtime snapshots contain running, retrying, blocked, token, and rate-limit data without exposing mutable scheduler internals.

**Steps:**

1. Write tests that construct public domain values and assert normalization helpers and redacted display behavior.
2. Run `v test symphony/domain` and observe the missing-module failure.
3. Implement the smallest public structs, enums, and helpers needed by later seams.
4. Re-run the domain tests.

## Task 3: Parse and validate workflow files

**Files:**

- Create: `symphony/workflow/config.v`
- Create: `symphony/workflow/loader.v`
- Create: `symphony/workflow/loader_test.v`

**Behavior under test:**

- Markdown-only files use documented defaults.
- `---` front matter decodes through `yaml.decode[T]` and must have a mapping root.
- Required Linear settings fail with field-specific errors when running, while syntax-only validation remains usable for example files with environment references.
- `${NAME}` environment references fail when required and missing; secret values never appear in errors.
- Relative workspace paths resolve from the workflow file directory; `~/` expands through the host home directory.
- Reloading an invalid edit preserves the last known good effective workflow.

**Steps:**

1. Add temporary-file tests for success, defaults, bad delimiters, scalar front matter, environment indirection, path resolution, and reload retention.
2. Run `v test symphony/workflow` and observe failure.
3. Implement typed nested config structs, default application, path expansion, validation modes, front-matter splitting, and an effective-workflow store.
4. Re-run the workflow tests and format the module.

## Task 4: Implement strict runtime prompt rendering

**Files:**

- Create: `symphony/prompt/render.v`
- Create: `symphony/prompt/render_test.v`

**Behavior under test:**

- Scalar paths render issue and attempt data.
- Unknown variables are errors.
- `default`, `lower`, `upper`, and `trim` filters behave deterministically.
- `if` blocks and `each` blocks over labels and blockers render correctly.
- Unclosed or mismatched blocks fail with source-position context.

**Steps:**

1. Add table-driven public rendering tests.
2. Run the test and observe failure.
3. Implement a bounded tokenizer/parser and renderer independent of `veb` templates.
4. Re-run tests, then refactor only while tests remain green.

## Task 5: Implement pure scheduler policy

**Files:**

- Create: `symphony/scheduler/policy.v`
- Create: `symphony/scheduler/policy_test.v`

**Behavior under test:**

- Candidate eligibility covers active/terminal state, assignment, blockers, required labels, claims, and retry membership.
- Ordering is stable by priority, creation timestamp, then identifier.
- Global and per-state capacity calculations never become negative.
- Failed attempts use capped exponential backoff; clean attempts use the continuation delay.
- Stall detection uses a supplied timestamp.
- Reconciliation returns explicit update, cancel-preserve, cancel-remove, or release actions without performing I/O.

**Steps:**

1. Add fixed-time fixtures and exhaustive public policy tests.
2. Run the scheduler tests and observe failure.
3. Implement pure functions only; do not import filesystem, HTTP, process, or clock modules.
4. Re-run scheduler and domain tests.

## Task 6: Make workspace lifecycle safe

**Files:**

- Create: `symphony/workspace/paths.v`
- Create: `symphony/workspace/hooks.v`
- Create: `symphony/workspace/workspace_test.v`

**Behavior under test:**

- Safe identifiers remain readable; changed identifiers receive a stable SHA-256 suffix.
- Traversal, absolute identifiers, and prefix-confusion paths cannot escape the workspace root.
- Existing workspaces are reused.
- `after_create` runs only after a newly created workspace; `before_run` runs per attempt.
- Hook output is bounded; timeout terminates the process group.
- `after_run` and `before_remove` errors are returned as warnings while terminal cleanup still follows containment rules.

**Steps:**

1. Add real temporary-directory and shell-process tests with short deterministic commands.
2. Run the workspace tests and observe failure.
3. Implement key derivation, containment validation, lifecycle operations, and a process runner using `os.Process` with `use_pgroup` and redirected stdio.
4. Re-run workspace tests and confirm no process remains alive after timeout cases.

## Task 7: Frame and interpret Codex JSONL

**Files:**

- Create: `symphony/codex/jsonl.v`
- Create: `symphony/codex/protocol.v`
- Create: `symphony/codex/jsonl_test.v`
- Create: `symphony/codex/protocol_test.v`

**Behavior under test:**

- Frames split at every byte boundary are reassembled in order.
- Multiple frames, blank lines, CRLF, invalid JSON, oversized lines, and an unterminated final line have explicit behavior.
- Responses correlate by request ID.
- Initialization, thread start, turn start, interrupt, completion, token usage, rate limits, and blocked-input notifications map to typed events.
- Unknown notifications remain bounded diagnostic events and do not become scheduler policy.

**Steps:**

1. Add framing tests before any decoder implementation.
2. Generate the installed Codex app-server schema into a temporary directory and use it to verify method names and payload shapes.
3. Add protocol fixture tests using only the verified schema subset.
4. Implement the bounded incremental decoder and concentrated protocol constructors/interpreter.
5. Re-run both Codex test files.

## Task 8: Implement tracker contracts and Linear HTTP

**Files:**

- Create: `symphony/tracker/port.v`
- Create: `symphony/tracker/linear.v`
- Create: `symphony/tracker/linear_test.v`

**Behavior under test:**

- A tracker port supports candidate fetch and opaque-ID refresh without exposing provider models.
- Linear request construction carries project scope, configured states, pagination cursor, and authorization.
- GraphQL data normalizes required and optional issue fields, labels, assignment, and blocker relationships.
- Candidate-list malformed records are skipped with diagnostics; malformed explicitly refreshed records fail.
- Transport, HTTP, GraphQL, authentication, rate-limit, decode, and validation failures remain distinguishable.

**Steps:**

1. Add normalization and request/response fixture tests first.
2. Add a local HTTP fixture test so the default suite never reaches Linear.
3. Implement the tracker interface and Linear adapter with dependency-injected endpoint and token.
4. Re-run tracker tests.

## Task 9: Supervise the Codex subprocess

**Files:**

- Create: `symphony/codex/client.v`
- Create: `symphony/codex/fake_app_server_test.v`
- Create: `symphony/codex/client_test.v`

**Behavior under test:**

- The child starts in the issue workspace with tracker secrets removed from its environment.
- Initialization precedes thread and turn requests.
- Stdout is parsed as protocol and stderr is bounded diagnostics only.
- Completion, timeout, stall, blocked request, malformed protocol, cancellation, and process exit become distinct outcomes.
- Cancellation terminates the full process group.

**Steps:**

1. Implement the fake app-server fixture as a test helper executable source.
2. Add integration tests that compile the helper into a temporary directory.
3. Run tests and observe client failures.
4. Implement process startup, request writes, pipe readers, deadlines, event reporting, and bounded shutdown.
5. Re-run client tests and verify helper descendants do not survive cancellation.

## Task 10: Own runtime state in one orchestrator loop

**Files:**

- Create: `symphony/orchestrator/commands.v`
- Create: `symphony/orchestrator/state.v`
- Create: `symphony/orchestrator/runtime.v`
- Create: `symphony/orchestrator/runtime_test.v`

**Behavior under test:**

- Reconciliation occurs before dispatch.
- One issue can be claimed only once.
- Capacity limits are honored across state transitions.
- Worker outcomes schedule continuation, backoff, blocked state, or release correctly.
- Retry refresh releases missing, inactive, terminal, or unroutable work.
- Snapshot requests are immutable copies of authoritative state.
- Refresh and shutdown commands have bounded acknowledgments.

**Steps:**

1. Add deterministic command-sequence tests around a public state machine API.
2. Run tests and observe failure.
3. Implement state transitions synchronously first.
4. Add the channel/select runtime shell that owns the state and delegates I/O through narrow tracker and runner interfaces.
5. Re-run orchestrator tests, then the complete module suite.

## Task 11: Add structured observability and optional `veb`

**Files:**

- Create: `symphony/observability/log.v`
- Create: `symphony/observability/log_test.v`
- Create: `symphony/statusweb/app.v`
- Create: `symphony/statusweb/app_test.v`

**Behavior under test:**

- NDJSON log records contain stable event and correlation fields and redact configured secrets.
- `GET /healthz`, `GET /api/v1/state`, and `GET /api/v1/issues/:id` return bounded snapshots.
- `POST /api/v1/refresh` submits a command and reports accepted or unavailable.
- Other methods and missing issues return correct errors.
- The server binds to loopback by default; a non-loopback configuration is explicit.

**Steps:**

1. Add logger tests and route-level HTTP tests first.
2. Implement a snapshot provider and refresh sender that do not expose orchestrator internals.
3. Implement a small dashboard with escaped values and no scheduler business logic.
4. Re-run observability and web tests.

## Task 12: Compose the CLI and graceful shutdown

**Files:**

- Modify: `bin/symphony/main.v`
- Create: `symphony/app/app.v`
- Create: `symphony/app/app_test.v`
- Modify: `README.md`

**Behavior under test:**

- `validate` parses and validates a workflow without requiring live credentials.
- `doctor` checks workflow, workspace root, shell, Codex executable, and optional token presence without printing secrets.
- `run` refuses invalid effective configuration before spawning runtime threads.
- CLI flags override workflow path, web enablement, host, and port deterministically.
- Shutdown stops dispatch, cancels workers, terminates child process groups, and closes the web server within a configured bound.

**Steps:**

1. Add public command parsing and validation tests.
2. Implement the app composition layer and replace the CLI stub.
3. Wire signals/interrupt handling to one shutdown command and bounded cleanup path.
4. Update operational documentation with exact commands and current limitations.

## Task 13: Conformance and final review

**Files:**

- Create: `docs/symphony-conformance.md`
- Modify any V or documentation files only for defects discovered by verification.

**Steps:**

1. Map every upstream core requirement to an implementation module and test, or mark it as an explicitly documented implementation-defined policy.
2. Run the full verification contract from a clean shell with no Linear token requirement.
3. Run a code review focused on correctness, workspace containment, secret handling, process cleanup, concurrency ownership, protocol bounds, and public test coverage.
4. Fix findings test-first and repeat the full verification contract.
5. Report the local files and exact verification results. Do not create a GitHub repository, remote, pull request, or release.
