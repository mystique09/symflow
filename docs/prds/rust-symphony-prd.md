# Rust Symphony Product Requirements Document

## Problem Statement

Teams can delegate individual coding tasks to Codex, but they still have to notice eligible tracker work, prepare isolated workspaces, launch and supervise agent sessions, handle retries, reconcile tracker state, and inspect runtime progress manually. The upstream Symphony specification defines this orchestration behavior without prescribing an implementation language. This project needs a native Rust implementation that follows that contract, adopts the established ReForged workspace organization, and remains understandable and testable without introducing a durable-workflow database in its first release.

The implementation must safely coordinate several long-running Codex subprocesses while retaining a single authority for claims, dispatch, cancellation, retry scheduling, and runtime accounting. It must also keep provider credentials outside child environments, constrain every agent to its issue workspace, and expose enough structured observability for an operator to understand failures without attaching a debugger.

## Solution

Build a spec-conforming Symphony daemon as a Rust virtual workspace. A dedicated binary package will be the composition root, while reusable behavior is separated into focused library crates for domain types, workflow/configuration loading, tracker integration, workspace lifecycle, Codex app-server communication, orchestration, observability, and the optional Actix Web status surface.

Tokio will provide asynchronous processes, channels, cancellation, timers, and bounded concurrency. The orchestrator will be an ordinary Tokio task that exclusively owns mutable scheduling state and processes typed commands serially. Actix Web will be used only for the optional dashboard and JSON operational interface. Kameo, the Actix actor framework, DBOS, and persistent scheduler state are intentionally excluded from the first implementation.

## User Stories

1. As an operator, I want Symphony to load a repository-owned workflow file, so that prompts and runtime policy are versioned with the project.
2. As an operator, I want to choose an explicit workflow path or use the current-directory default, so that the same binary can serve different repositories.
3. As an operator, I want malformed workflow configuration to produce a typed startup error, so that configuration mistakes are immediately actionable.
4. As an operator, I want a failed hot reload to retain the last known good configuration, so that an edit does not stop active work.
5. As an operator, I want valid workflow changes to apply without restarting Symphony, so that polling, limits, prompts, and hooks can be adjusted safely.
6. As a workflow author, I want strict prompt rendering, so that misspelled variables fail visibly instead of silently producing bad agent instructions.
7. As a workflow author, I want issue fields, labels, blockers, native references, and retry attempts available to templates, so that prompts can contain useful tracker context.
8. As an operator, I want provider secrets referenced through environment variables, so that literal credentials do not live in the repository.
9. As an operator, I want tracker secrets removed from the Codex child environment, so that agents cannot read credentials they do not need.
10. As an operator, I want tracker-specific configuration isolated behind an adapter, so that orchestration policy remains provider-neutral.
11. As an operator, I want a production Linear adapter, so that Symphony can poll and reconcile work from a Linear project.
12. As an operator, I want candidate fetches to honor provider scope, pagination, active states, assignment, labels, and blockers, so that only intended work is dispatched.
13. As an operator, I want issue refreshes to use opaque dispatch IDs, so that reconciliation does not depend on human-readable identifiers.
14. As an operator, I want malformed requested issue records to fail refresh rather than disappear, so that active work is never canceled because of silent data loss.
15. As an operator, I want deterministic priority, creation-time, and identifier ordering, so that dispatch remains predictable.
16. As an operator, I want a global concurrency limit, so that Codex sessions cannot exhaust the host.
17. As an operator, I want per-tracker-state concurrency limits, so that expensive classes of work can be throttled independently.
18. As an operator, I want one authoritative scheduler state, so that the same issue cannot be dispatched twice within a running process.
19. As an operator, I want reconciliation before every dispatch pass, so that stale active work is stopped before new work starts.
20. As an operator, I want terminal issues to stop their agent and remove their workspace, so that completed work does not consume resources indefinitely.
21. As an operator, I want non-active, non-terminal issues to stop their agent without removing the workspace, so that paused work can be resumed later.
22. As an operator, I want missing or newly unroutable issues to release their claims safely, so that the scheduler does not deadlock work.
23. As an operator, I want clean worker exits to schedule a short continuation check, so that an active issue can receive another bounded agent session.
24. As an operator, I want abnormal exits to use capped exponential backoff, so that transient failures recover without causing retry storms.
25. As an operator, I want retry entries to retain attempt, due time, identifier, and error, so that pending recovery is observable.
26. As an operator, I want stalled sessions detected from their last event time, so that silent Codex failures do not occupy slots forever.
27. As an operator, I want cancellation to terminate the entire Codex process group, so that hooks or child commands do not become orphans.
28. As an operator, I want retry and cancellation timers to be cancelable, so that obsolete work cannot reappear after reconciliation.
29. As an operator, I want deterministic collision-resistant workspace names, so that unusual issue identifiers cannot collide.
30. As a security owner, I want every workspace path validated under the configured root, so that traversal cannot launch Codex elsewhere on the host.
31. As an operator, I want existing issue workspaces reused, so that retries and continuation sessions preserve prior progress.
32. As a workflow author, I want an after-create hook that runs only for new workspaces, so that repository bootstrapping is not repeated.
33. As a workflow author, I want a before-run hook for every attempt, so that reused workspaces can be synchronized or prepared.
34. As a workflow author, I want after-run and before-remove hooks with nonfatal failure semantics, so that cleanup attempts do not corrupt scheduler state.
35. As an operator, I want every hook to have a configurable timeout, so that a shell script cannot hang orchestration indefinitely.
36. As an operator, I want Codex launched only with the issue workspace as its working directory, so that agent file operations remain isolated.
37. As an operator, I want the Codex command preserved as a shell command string, so that local wrappers and configuration flags remain usable.
38. As a client integrator, I want Codex app-server schemas generated from the installed Codex version, so that protocol bindings match the deployed executable.
39. As an operator, I want app-server initialization, thread startup, turns, and continuation turns handled automatically, so that issue execution requires no manual terminal session.
40. As an operator, I want protocol stdout separated from diagnostic stderr, so that logging cannot corrupt JSONL framing.
41. As an operator, I want bounded message sizes and request timeouts, so that malformed or silent app-server behavior cannot exhaust memory or hang a worker.
42. As an operator, I want turn completion, failure, cancellation, timeout, and process exit mapped to distinct outcomes, so that retry reasons remain accurate.
43. As an operator, I want approval and user-input requirements resolved by a documented policy, so that a run never stalls indefinitely.
44. As an operator, I want token usage and rate-limit events aggregated without double counting, so that status information reflects actual consumption.
45. As an operator, I want issue, attempt, process, thread, and turn identifiers in structured logs, so that a run can be traced end to end.
46. As an operator, I want startup and validation failures visible without a debugger, so that the daemon is operable from logs alone.
47. As an operator, I want an optional human-readable dashboard, so that active sessions and retries can be understood at a glance.
48. As an integration author, I want a versioned JSON status interface, so that external tools can inspect current state without reading logs.
49. As an operator, I want an HTTP refresh trigger, so that I can request an immediate poll and reconciliation pass.
50. As an operator, I want status-surface failures isolated from orchestration, so that a broken dashboard cannot stop coding agents.
51. As a developer, I want pure scheduler transition logic separated from Tokio task wiring, so that eligibility, sorting, retries, and reconciliation are deterministic to test.
52. As a developer, I want production and in-memory tracker adapters at one narrow seam, so that orchestration tests do not require external credentials.
53. As a developer, I want the workspace and Codex clients tested through their public interfaces, so that internal refactors do not rewrite behavioral tests.
54. As a developer, I want all third-party versions declared in the root workspace manifest, so that dependency policy is centralized.
55. As a developer, I want each binary and library package to declare only the dependencies it uses, so that compile times remain bounded.
56. As a developer, I want a generated Hakari workspace-hack crate, so that feature unification is explicit and repeatable.
57. As a developer, I want the root manifest to remain a virtual workspace, so that executable wiring cannot leak into the workspace root.
58. As a release engineer, I want one self-contained Symphony executable, so that deployment does not require a language runtime.
59. As a release engineer, I want deterministic unit, integration, and fake-app-server tests in CI, so that core conformance does not depend on live services.
60. As a release engineer, I want opt-in real Linear and Codex smoke tests, so that production credentials are never required for the default test suite.

## Implementation Decisions

- The Rust implementation will follow the upstream language-agnostic Symphony service specification and will document every implementation-defined behavior.
- The project will be a virtual Cargo workspace using resolver version 3 and the Rust 2024 edition.
- Executable composition will live in a dedicated package under the binary-package family; reusable behavior will live in focused library crates under the library-package family.
- Library crates will cover domain models, workflow parsing and typed configuration, prompt rendering, tracker ports and adapters, workspace lifecycle, Codex app-server communication, orchestration, observability, and the optional HTTP surface.
- The binary package will own startup ordering, dependency construction, signal handling, and coordinated shutdown. Business and integration behavior will not be implemented in the binary.
- All third-party dependencies will be versioned once in the root workspace dependency table. Member packages will opt into them through workspace inheritance and will declare only what they use.
- Cargo Hakari will generate and maintain one workspace-hack package. Every first-party package will depend on the workspace-hack package according to Hakari guidance.
- Tokio will provide the multithreaded runtime, process management, channels, timers, filesystem operations, and cancellation tokens.
- Kameo and the Actix actor framework will not be used. The orchestrator will be one Tokio task that owns all scheduler state and consumes typed commands through a bounded channel.
- Actix Web will be restricted to the optional operator dashboard, JSON endpoints, and refresh trigger. Its state will contain only a handle to the orchestration interface and static presentation dependencies.
- The scheduler core will be a deterministic module that calculates candidate eligibility, ordering, slot availability, retry delays, and reconciliation actions without performing I/O.
- Runtime commands will include poll ticks, retry deadlines, worker lifecycle events, Codex telemetry updates, workflow reloads, snapshot requests, refresh requests, and shutdown.
- Tokio tasks running issue attempts will report structured outcomes to the orchestrator. They will never mutate claim, retry, or aggregate metric state directly.
- Worker task panics and process exits will be converted into explicit failure outcomes. Automatic transparent worker restarts are forbidden because retry behavior belongs to the orchestrator.
- The first release will keep scheduler state in memory. Restart recovery will come from tracker reads and preserved workspaces exactly as defined by the Symphony specification.
- DBOS, durable workflow engines, and persistent retry/session restoration are excluded. Stable run and attempt identifiers will nevertheless be used so persistence can be added later without changing caller-facing models.
- The tracker seam will expose candidate reads and opaque-ID refreshes returning normalized issue snapshots. The first production adapter will support Linear.
- Provider-specific eligibility, authentication, pagination, rate limiting, scope selection, and payload normalization will remain inside the Linear adapter.
- The workspace module will sanitize identifiers, append a stable SHA-256-derived suffix when sanitization changes an identifier, canonicalize roots, and reject any path that escapes the configured root.
- Workspace hooks will execute in the issue workspace using the configured shell contract. Hook output will be bounded and secrets will be redacted.
- The Codex module will isolate the version-specific app-server protocol behind a small interface. Generated schemas will be checked against the installed Codex version selected for the release.
- The app-server client will use newline-delimited JSON over redirected stdio, maintain request correlation, stream notifications, enforce read and turn timeouts, and keep stderr out of the protocol stream.
- The initial approval policy will surface approval, user-input, and MCP-elicitation requirements as an in-memory blocked run visible to logs and status endpoints. The active process will be stopped so the run cannot remain silently stalled.
- Tracker secret environment names will be declared by adapters and removed from child environments before hooks or Codex are started.
- Structured logging will use stable event names and key-value fields. Humanized summaries will be derived observability data and will never drive scheduling decisions.
- The HTTP extension will provide a dashboard, a versioned state summary, per-issue details, and an immediate refresh trigger. It will default to loopback and remain optional.
- Graceful shutdown will stop dispatch, cancel retry timers, terminate active process groups, wait for bounded worker cleanup, and then stop optional observability servers.
- The project will remain local until the user explicitly requests a GitHub repository or remote publication.

## Testing Decisions

- Tests will assert observable behavior at public module interfaces and the CLI/HTTP surfaces. They will not assert private field layouts, Tokio task counts, channel implementation, or internal helper calls.
- Workflow tests will cover path precedence, missing files, YAML front matter, non-map roots, defaults, environment indirection, strict rendering, nested issue context, and last-known-good reload behavior.
- Scheduler tests will use pure fixtures and a controllable clock to cover stable ordering, labels, active and terminal states, global and per-state concurrency, duplicate-claim prevention, retry formulas, continuation delays, stale-session detection, and reconciliation actions.
- Workspace tests will use temporary roots and real filesystem operations to cover deterministic reuse, sanitized collisions, containment, new-only hooks, per-attempt hooks, timeout behavior, and terminal cleanup.
- Tracker contract tests will run against an in-memory adapter. Linear adapter tests will use a local HTTP fixture server and recorded provider-shaped payloads for pagination, normalization, authentication, malformed records, and error taxonomy.
- Codex client tests will launch a deterministic fake app-server subprocess and verify initialization order, JSONL chunking, request correlation, notification streaming, timeouts, cancellation, stderr separation, message limits, and process-group cleanup.
- Orchestrator integration tests will combine in-memory tracker, temporary workspace, fake agent runner, and controllable time to verify complete dispatch, retry, reconciliation, continuation, and shutdown flows.
- HTTP extension tests will verify state, issue detail, refresh, method errors, unavailable orchestration, and that status failures do not mutate or stop scheduler state.
- The default suite will not require network access, Linear credentials, or a real Codex login.
- Real Linear and Codex tests will be separate opt-in profiles, will use isolated identifiers and temporary workspaces, and will report skips explicitly when credentials are absent.
- Workspace verification will include formatting, linting, unit tests, integration tests, documentation tests, Cargo metadata validation, Hakari verification, and a release build of the binary.

## Out of Scope

- A DBOS integration or any other durable-workflow engine.
- Persistent restoration of retry timers, live sessions, blocked entries, or exact in-memory state after process restart.
- Kameo, the Actix actor framework, or distributed actor communication.
- A general-purpose workflow engine or distributed job scheduler.
- Multi-tenant hosting, tenant billing, or tenant-level authorization.
- Remote worker fleets, SSH execution, container orchestration, or microVM management.
- Tracker write business logic in the orchestrator.
- More than one production tracker adapter in the first release.
- A rich project-management UI; the web surface is operational observability and control only.
- Automatic pull-request merging, deployment, or repository-specific completion policy outside the workflow prompt.
- Creation of a GitHub repository, remote, release, or issue-tracker project.

## Further Notes

- The upstream Symphony reference implementation is an engineering preview intended for trusted environments. This Rust implementation must state the same initial trust posture while still enforcing workspace containment, credential separation, bounded execution, and explicit approval behavior.
- The Codex app-server protocol is version-sensitive. Release work must pin and test a supported Codex version instead of maintaining a hand-written permanent protocol enum.
- The Rust PRD is documentation only in the current project phase. The V implementation is the only implementation authorized by the user after both PRDs are created.
