# V Symphony Product Requirements Document

## Problem Statement

Teams need a small, deployable daemon that turns eligible tracker work into isolated Codex implementation runs without requiring an operator to supervise every session. The upstream Symphony specification defines the necessary workflow, scheduling, retry, reconciliation, workspace, app-server, and observability behavior, but the available reference implementation is an Elixir engineering preview. This project needs a V implementation that is easier to compile and distribute, uses a small dependency surface, and remains faithful to Symphony's single-authority scheduling model.

The main technical challenge is not serving HTTP. It is safely coordinating bounded concurrent work, streaming newline-delimited JSON to and from long-running Codex subprocesses, handling cancellation and timeouts, retaining last-known-good workflow configuration, and preventing workspace or credential escapes. V can provide the required primitives, but the design must avoid treating thread creation as magical coroutine durability and must isolate fast-moving compiler or standard-library behavior behind well-tested modules.

## Solution

Build a spec-conforming Symphony daemon in V 0.5.2, pinned to an exact compiler commit. The project will contain one package manifest, one executable composition root, and focused internal modules for domain models, workflow/configuration, templates, tracker integration, workspaces and hooks, Codex app-server communication, scheduler transitions, runtime orchestration, structured logs, and an optional `veb` status surface.

The runtime will use one orchestrator loop as the sole owner of mutable scheduling state. Pollers, retry timing, issue workers, Codex pipe readers, workflow watching, and the web server will communicate with that loop through typed channels. V `context` values will carry cancellation and deadlines inside the process, while explicit process-group termination will stop Codex and descendant commands. The first release will recover from tracker state and preserved workspaces and will not add DBOS or a scheduler database.

## User Stories

1. As an operator, I want to start Symphony with an explicit workflow file, so that one installation can run different repository policies.
2. As an operator, I want Symphony to default to a workflow file in the current directory, so that local startup remains simple.
3. As an operator, I want missing or unreadable workflow files reported as typed startup failures, so that I can correct the path immediately.
4. As a workflow author, I want optional YAML front matter and a Markdown prompt body, so that runtime settings and instructions live together.
5. As a workflow author, I want front matter constrained to an object, so that invalid scalar or list configuration cannot be misinterpreted.
6. As an operator, I want documented defaults for optional configuration, so that a minimal workflow is runnable.
7. As an operator, I want environment references resolved for secrets and paths, so that credentials and host-specific roots stay outside version control.
8. As an operator, I want relative workspace roots resolved from the workflow file directory, so that repository-local configuration is deterministic.
9. As an operator, I want home-directory expansion for path configuration, so that local setup is concise.
10. As an operator, I want valid workflow changes detected without restart, so that prompt and scheduling policy can be adjusted while the daemon runs.
11. As an operator, I want invalid reloads to preserve the last known good workflow, so that a partial edit does not interrupt active work.
12. As a workflow author, I want strict runtime template rendering, so that an unknown variable stops an attempt instead of producing incomplete instructions.
13. As a workflow author, I want normalized issue fields and retry attempt data available to the prompt, so that agents receive complete task context.
14. As a workflow author, I want labels and blocker data available to iteration constructs, so that prompts can explain routing and dependency state.
15. As a workflow author, I want common string and default-value filters, so that optional issue data can be rendered safely.
16. As an operator, I want tracker behavior selected through configuration, so that provider-specific concerns do not enter scheduler logic.
17. As an operator, I want a production Linear adapter, so that the initial implementation can run against a Linear project.
18. As an operator, I want Linear API tokens taken from host configuration, so that agents cannot read them from the workflow file.
19. As an operator, I want Linear candidate queries scoped to the configured project and states, so that unrelated issues are never scheduled.
20. As an operator, I want Linear pagination followed deterministically, so that large projects do not hide eligible work.
21. As an operator, I want issue IDs treated as opaque dispatch identities, so that provider-specific identifiers do not leak into orchestration.
22. As an operator, I want labels normalized and blank labels discarded, so that routing comparisons are stable.
23. As an operator, I want optional malformed fields normalized without losing otherwise valid issues, so that provider irregularities do not stop all dispatch.
24. As an operator, I want malformed required fields logged and excluded from candidates, so that unsafe work is never launched.
25. As an operator, I want malformed records requested during reconciliation to fail visibly, so that active issues are not treated as missing.
26. As an operator, I want assignment and blocker policy represented by a normalized dispatchable value, so that generic scheduling remains provider-neutral.
27. As an operator, I want stable priority, creation-time, and identifier sorting, so that candidate order remains predictable.
28. As an operator, I want one orchestrator loop to own all claims, running entries, retries, metrics, and blocked runs, so that duplicate dispatch cannot arise from shared mutation.
29. As an operator, I want bounded global concurrency, so that agent processes cannot overwhelm the host.
30. As an operator, I want per-state concurrency overrides, so that different workflow stages can have different capacity.
31. As an operator, I want required-label matching to ignore case and surrounding whitespace, so that tracker formatting does not change eligibility.
32. As an operator, I want reconciliation to run before candidate dispatch, so that released capacity reflects current tracker state.
33. As an operator, I want active issue snapshots refreshed in running state, so that dashboards and later reconciliation use current metadata.
34. As an operator, I want non-active issues to cancel their workers but preserve workspaces, so that paused work can resume.
35. As an operator, I want terminal issues to cancel workers and remove workspaces, so that completed work is cleaned safely.
36. As an operator, I want a clean attempt exit to schedule a short continuation check, so that still-active issues can continue without an immediate tight loop.
37. As an operator, I want failed attempts to use capped exponential backoff, so that transient failures recover without flooding dependencies.
38. As an operator, I want a retry refresh to release claims for missing, inactive, terminal, or unroutable work, so that claims cannot remain stuck.
39. As an operator, I want stalled sessions terminated based on their last activity timestamp, so that silent processes do not consume concurrency forever.
40. As an operator, I want each issue to receive a deterministic collision-resistant workspace directory, so that identifiers remain safe as paths.
41. As a security owner, I want every computed workspace validated under the configured root, so that path traversal and absolute identifier tricks are rejected.
42. As an operator, I want existing workspaces reused across attempts, so that agent progress survives continuation and transient failure.
43. As a workflow author, I want an after-create hook only for new directories, so that repository cloning happens once.
44. As a workflow author, I want a before-run hook for every attempt, so that the workspace can be synchronized before Codex starts.
45. As a workflow author, I want after-run and before-remove hooks attempted with nonfatal failure behavior, so that best-effort cleanup cannot corrupt scheduler state.
46. As an operator, I want all hook execution bounded by a timeout, so that arbitrary shell configuration cannot hang the daemon.
47. As an operator, I want hook output bounded and secrets redacted, so that logs remain useful and safe.
48. As an operator, I want Codex launched in the exact issue workspace, so that agent filesystem actions cannot target another repository.
49. As an operator, I want tracker secret variables removed from the child environment, so that the agent receives only the credentials it needs.
50. As an operator, I want the configured Codex shell command preserved, so that wrappers and local command flags remain possible.
51. As a Codex client integrator, I want newline-delimited JSON framing buffered across arbitrary pipe chunks, so that partial reads never corrupt messages.
52. As a Codex client integrator, I want protocol stdout separated from diagnostic stderr, so that logs cannot be parsed as app-server messages.
53. As a Codex client integrator, I want request IDs correlated with responses, so that initialization, thread, turn, interrupt, and tool calls complete correctly.
54. As an operator, I want app-server initialization followed by thread and turn startup in protocol order, so that every attempt has a valid session.
55. As an operator, I want continuation turns to remain on one live thread, so that the original prompt does not need to be resent.
56. As an operator, I want request, turn, stall, and process-exit timeouts distinguished, so that retries contain the correct failure reason.
57. As an operator, I want cancellations to terminate the full process group, so that Codex descendants do not become orphans.
58. As an operator, I want approval, elicitation, or user-input requests surfaced as blocked work, so that no attempt waits indefinitely without visibility.
59. As an operator, I want token totals calculated from absolute usage updates without double counting, so that reported consumption is accurate.
60. As an operator, I want the latest rate-limit snapshot retained, so that capacity problems can be diagnosed.
61. As an operator, I want structured JSON logs containing issue, attempt, process, thread, and turn context, so that one run can be traced across modules.
62. As an operator, I want a `veb` dashboard showing running, retrying, blocked, token, runtime, and error information, so that I can inspect the daemon quickly.
63. As an integration author, I want a versioned JSON state endpoint and issue-detail endpoint, so that operational tools can consume current state.
64. As an operator, I want an HTTP refresh trigger, so that I can request a poll and reconciliation pass without restarting.
65. As an operator, I want the web server to default to loopback and remain optional, so that enabling observability does not expose the host unexpectedly.
66. As an operator, I want web errors isolated from scheduler behavior, so that presentation failures cannot stop agent work.
67. As an operator, I want graceful shutdown to stop dispatch, cancel retry activity, terminate active process groups, and close the web server, so that deployments do not leave child processes behind.
68. As a developer, I want deterministic scheduler decisions expressed as pure functions, so that concurrency policy can be tested without sleeping or spawning processes.
69. As a developer, I want workflow, scheduler, workspace, tracker, and app-server modules tested at their public interfaces, so that implementation refactors do not invalidate behavior tests.
70. As a developer, I want fake tracker and fake app-server integrations available in tests, so that the default suite needs no external credentials.
71. As a developer, I want the V compiler version and commit pinned, so that compiler or standard-library drift cannot silently change production behavior.
72. As a release engineer, I want one native executable with statically compiled internal modules and templates, so that deployment is simple.
73. As a release engineer, I want formatting, vetting, unit tests, integration tests, and a production build in the verification contract, so that releases are repeatable.
74. As a release engineer, I want live Linear and Codex smoke tests to be opt-in, so that ordinary development remains deterministic and credential-free.

## Implementation Decisions

- The V implementation will follow the current upstream language-agnostic Symphony specification and will document implementation-defined policies.
- The supported compiler baseline is V 0.5.2 at an exact commit recorded in project configuration. Upgrading the compiler requires running the full conformance suite.
- The project will use one root package manifest as the module lookup anchor, one executable composition root, and focused internal modules organized by responsibility.
- The executable composition root will construct concrete adapters, validate startup configuration, start orchestration and optional web processes, install signal handling, and coordinate shutdown.
- Internal modules will cover domain types, workflow parsing, typed configuration, prompt templates, tracker normalization, the Linear adapter, workspace lifecycle and hooks, Codex protocol framing and subprocess control, scheduler decisions, runtime orchestration, observability, and the `veb` surface.
- V's `coroutines` module and its Photon dependency will not be used. Bounded concurrency will use V threads created with `spawn`, typed buffered channels, `select`, and explicit contexts.
- A single orchestrator loop will own mutable claim, running, retry, blocked, token, runtime, and rate-limit state. Other threads can submit commands and receive snapshots but cannot mutate scheduler state.
- The command model will distinguish poll ticks, workflow reloads, retry deadlines, worker events, telemetry events, snapshot requests, refresh triggers, and shutdown.
- The scheduler module will contain pure eligibility, sorting, slot, retry-delay, stall, and reconciliation decisions. It will not perform HTTP, filesystem, process, channel, or clock I/O.
- Worker threads will own one run attempt and its Codex subprocess. They will report structured events to the orchestrator and will not schedule their own retries.
- V contexts will provide cooperative cancellation and deadlines for internal loops. Codex and hook cancellation will additionally send operating-system termination and process-group kill signals because contexts cannot stop external processes by themselves.
- The first release will use tracker-driven and filesystem-driven restart recovery. Scheduler state, retry deadlines, blocked entries, and live sessions will remain in memory.
- DBOS, databases, durable queues, and third-party coroutine runtimes will not be introduced.
- The workflow loader will split optional YAML front matter from the Markdown body, require an object root, preserve adapter-owned provider keys, and retain a last-known-good effective workflow after reload errors.
- File reload detection will use a portable modification-time polling loop by default. Platform notification APIs may be evaluated later only if they do not change workflow-store behavior.
- Prompt rendering will be a runtime module separate from `veb` templates. It will implement strict variable paths, iteration over labels and blockers, conditionals, and a documented small filter set needed by repository workflows.
- The tracker seam will normalize candidate and opaque-ID refresh operations. The production implementation will support Linear; tests will use an in-memory fixture adapter at the same seam.
- Linear HTTP behavior will include project scope, pagination, configurable endpoint, authorization, response classification, GraphQL error handling, required-field validation, optional-field normalization, blocker interpretation, and rate-limit categorization.
- Provider-native tracker mutation tools are not required for initial conformance. The orchestrator remains read-only toward tracker state.
- Workspace keys will replace disallowed characters and append the first 64 bits or more of a SHA-256 digest when sanitization changes the identifier.
- Workspace containment will be checked using normalized absolute paths and directory-aware prefix logic before hooks or Codex launch.
- Hooks will run through the documented host shell in the issue workspace with bounded output, timeout enforcement, and exact fatal or best-effort semantics from the Symphony specification.
- The Codex process adapter will configure cwd, arguments, environment, redirected standard streams, process-group ownership, and cleanup through V's process module.
- A dedicated JSONL decoder will retain partial frames between pipe reads, reject oversized lines, ignore blank lines, and return complete frames in order.
- App-server request construction and response interpretation will be version-aware and concentrated in the Codex module. Arbitrary protocol notifications will be retained as typed event names plus bounded raw context rather than driving scheduler behavior from humanized text.
- The documented approval policy will mark a run blocked in memory, expose it through logs and status, and stop its process. A later operator action or tracker change can release or re-dispatch it.
- Structured logs will be newline-delimited JSON written to stderr and optionally to configured files. Secret values and unbounded provider or app-server payloads will never be logged.
- `veb` will implement only the optional operational dashboard, state and issue JSON endpoints, and refresh trigger. It will consume immutable snapshots and submit refresh commands; correctness will never depend on HTTP availability.
- The default web bind address will be loopback. A non-loopback bind is an explicit operator decision and will produce a security warning.
- Graceful shutdown will prevent new dispatch, cancel contexts, stop retry progression, terminate child process groups, wait for bounded cleanup, and then stop the optional `veb` server.
- The project will remain local. No GitHub repository, remote, external PRD ticket, or release will be created without a later explicit request.

## Testing Decisions

- Tests will validate external behavior at module interfaces and process/HTTP surfaces rather than private fields, helper calls, thread counts, or channel capacity implementation.
- Workflow tests will use real temporary files and environment fixtures to cover discovery, parsing, path resolution, defaults, strict errors, reload, and last-known-good retention.
- Template tests will cover scalar variables, null/default behavior, labels, blockers, loops, conditionals, filters, escaping expectations, and unknown-variable failures.
- Scheduler tests will use fixed timestamps and issue fixtures to cover sorting, labels, states, dispatchability, claims, global and per-state slots, retry delays, stall thresholds, reconciliation, and release behavior.
- Workspace tests will use temporary directories and real shell hooks to cover safe names, collision suffixes, containment rejection, reuse, new-only hooks, per-attempt hooks, timeouts, cleanup, and nonfatal hook failures.
- JSONL tests will feed frames split at every possible byte boundary, multiple frames per chunk, blank lines, invalid JSON, oversized frames, and final unterminated data.
- Codex client integration tests will launch a deterministic fake process that implements initialization, thread start, turn start, notifications, completion, stderr noise, delays, malformed output, and cancellation.
- Tracker contract tests will run against an in-memory adapter. Linear adapter tests will run against a local fixture HTTP server and provider-shaped JSON for pagination, normalization, malformed data, authentication, GraphQL failures, and rate limits.
- Orchestrator integration tests will combine fake tracker, temporary workspace, fake Codex runner, and controllable time to test dispatch, continuation, failures, retry exhaustion behavior, reconciliation, blocked runs, metrics, and shutdown.
- `veb` tests will validate dashboard availability, state JSON, issue detail, refresh acceptance, 404 and method errors, loopback defaults, and isolation from scheduler failures.
- CLI tests will cover default and explicit workflow paths, invalid arguments, port selection, startup failures, signal shutdown, and exit codes.
- The default test suite will be network-free and credential-free.
- Live Linear and real Codex profiles will be opt-in, use isolated test issues and temporary workspaces, and report missing prerequisites as explicit skips.
- Required verification will include `v fmt -verify`, `v vet`, all module tests, integration tests, a normal debug build, a production build, a fake end-to-end run, and a bounded real startup smoke test when Codex authentication is available.

## Out of Scope

- The Rust implementation described by the companion PRD.
- DBOS or any other durable-workflow engine.
- Persistent scheduler, retry, blocked-run, or live-session recovery.
- The V Photon coroutine wrapper or another third-party coroutine runtime.
- Multi-tenant hosting, tenant-level authorization, billing, or usage enforcement.
- Remote SSH workers, distributed execution, containers, Kubernetes, or microVM orchestration.
- A general-purpose workflow engine or distributed queue.
- More than one production tracker adapter in the first release.
- Provider-native tracker mutation tools in the initial conformance release.
- Automatic tracker transitions, comments, pull-request merging, or deployment business logic in the orchestrator.
- A full project-management web application; `veb` is an operational status and control surface only.
- Creation of a GitHub repository, remote, issue-tracker project, or public package.

## Further Notes

- V's current standard concurrency model uses threads for `spawn`; this is acceptable because Symphony's configured concurrency is bounded and every active unit already supervises an external Codex process.
- `veb` templates are compile-time assets and are not suitable for dynamic repository-owned workflow prompts. The runtime prompt renderer is therefore an independent module.
- V's process reads return arbitrary chunks rather than protocol frames. JSONL buffering is a correctness-critical module and must be implemented and tested before the real app-server client.
- The upstream Symphony trust posture is an engineering preview for trusted environments. This implementation will enforce workspace containment, secret separation, timeouts, bounded messages, and explicit approval behavior, but it will not claim to be a hardened multi-tenant sandbox.
