# Symphony V Conformance Record

This record maps the local V engineering preview to the current upstream
[Symphony specification](https://github.com/openai/symphony/blob/main/SPEC.md).
It distinguishes implemented behavior from known gaps; the Rust PRD remains a
design document and has no corresponding Rust source tree.

## Implemented core

| Requirement area | Local implementation and evidence |
| --- | --- |
| Workflow file | `symphony/workflow` splits YAML front matter from Markdown, requires an object root, applies typed defaults, resolves paths, preserves arbitrary adapter-owned `tracker.provider` keys, passes schema-owned Codex policy objects through as JSON, reloads on every poll, and retains the last valid effective definition after loader or adapter validation errors. |
| Runtime prompt | `symphony/prompt` implements bounded strict interpolation, scalar issue fields, labels and blockers, conditionals, loops, and `default`, `lower`, `upper`, and `trim` filters. A first attempt is presented as absent; retry attempts are integers. |
| Tracker | `symphony/tracker` exposes state-list reads, opaque-ID refreshes, live scope validation, secret metadata, and outcome recording. The default file adapter strictly reads bounded Markdown/YAML tickets and atomically records dispatch status. Linear supports exact project or team scope with read-only GraphQL behavior. GitHub Projects supports organization- or user-owned Project scope, Issue-only item normalization, Project-position pagination, strict Project-scoped refresh, and opt-in status-field outcomes. Provider profiles are in `docs/tracker-file.md`, `docs/tracker-linear.md`, and `docs/tracker-github.md`. |
| Eligibility and scheduling | `symphony/scheduler` contains pure active/terminal, required-label, explicit-dispatchability, priority, global-slot, per-state-slot, reconciliation, stall, and exponential-backoff decisions. It contains no Linear semantics. |
| State authority | `symphony/orchestrator/runtime.v` owns claim, running, retry, blocked, token, runtime, PID, thread, turn, event, message, and rate-limit state in one channel-driven loop. Absolute token reports become positive deltas, and snapshots add active elapsed runtime. |
| Service loop | `symphony/orchestrator/service.v` reloads configuration, reconciles running issues before dispatch, refreshes due retries by opaque ID, claims eligible candidates, starts bounded workers, performs startup cleanup for terminal issues, and releases missing, inactive, terminal, or unroutable retries. |
| Retry semantics | A clean worker completion ends the local ticket when the file adapter persists `completed`. Adapters that do not persist completion retain the 1-second continuation behavior. Abnormal outcomes use capped exponential backoff. Claims remain held while queued, and retries re-check tracker routing before launch. |
| Workspace safety | `symphony/workspace` generates sanitized collision-resistant keys, verifies directory-aware root containment, reuses existing issue directories, removes tracker-secret variables from all four lifecycle hook environments, applies documented fatal/best-effort behavior, bounds hook output and time, cancels hook process groups on shutdown, and refuses to follow a workspace symlink during cleanup. |
| Codex transport | `symphony/codex` launches `bash -lc <codex.command>` in the issue workspace, removes tracker-secret environment names, separates protocol stdout from diagnostic stderr, frames JSONL with a 10 MiB line bound, initializes experimental capabilities against the installed schema, passes thread/turn policies through, runs same-thread continuations, streams live telemetry, returns structured failures for unsupported `item/tool/call` requests without ending the session, classifies blocking requests and completion, and kills process groups on every terminal path. |
| Observability | `symphony/observability` writes secret-redacted NDJSON to stderr with issue, attempt, session, thread, and turn correlation. Runtime snapshots expose live session rows, retry/blocked rows, aggregate absolute-delta tokens, active-plus-ended runtime, and the latest rate limit. |
| Optional HTTP | `symphony/statusweb` uses `veb` for a human dashboard, `GET /api/v1/state`, `GET /api/v1/<issue_identifier>`, and `POST /api/v1/refresh`. It supports `server.port`, CLI override including ephemeral port `0`, loopback defaults, recommended summary fields, JSON error envelopes, 404/405 semantics, immutable bounded projections, escaped HTML, and bounded shutdown. |
| CLI and shutdown | `symphony/app` implements cwd-default and positional workflow paths, `validate`, `doctor`, `run`, `version`, `--once`, `--port`, compatibility web flags, startup adapter validation, non-loopback warnings, `SIGINT`/`SIGTERM`, worker cancellation, process-group cleanup, always-attempted `after_run` hooks for prepared workspaces, and web shutdown. |
| Restart posture | Scheduler state is intentionally in memory. Startup derives work from the selected tracker and preserved issue workspaces; the file adapter durably excludes completed and blocked tickets through frontmatter, and terminal workspace cleanup is repeated on boot. No DBOS or database is present. |

## Verified implementation-defined policies

- Approval and user-input requests are surfaced as a blocked outcome and their
  Codex process is stopped. `POST /api/v1/refresh` is the operator action that
  releases blocked claims before polling again.
- The file adapter owns `dispatch_status`, `last_error`, and `completed_at`.
  Successful outcomes become completed, blocking outcomes become blocked, and
  failure outcomes remain pending for normal retry behavior.
- The optional Linear adapter remains read-only and reports that it did not
  persist completion, preserving the existing continuation semantics.
- The GitHub adapter is read-only by default. Explicit write mode changes only
  the configured Project status field to distinct success or blocked options;
  it does not close Issues, rewrite Issue labels, or modify other Project fields.
- Hooks run with `/bin/bash -lc` on this POSIX implementation.
- An explicit non-loopback web bind is allowed but produces a structured
  security warning. Authentication and TLS are deployment concerns for this
  preview.

## Deliberately unshipped optional extensions

| Area | Status |
| --- | --- |
| Provider-native tracker tools | Linear and GitHub mutation tools are not advertised to Codex. GitHub's host-owned Project status update is internal to the adapter; unsupported dynamic tool calls receive a failure response. |
| Durable scheduler state | Claims, retries, and live sessions remain in memory. Database/DBOS durability is an upstream follow-up, not a core requirement. Restart recovery is tracker- and workspace-driven. |
| Remote workers | The optional SSH worker appendix is not implemented. All workers are local process groups. |
| Additional log sinks | The conforming NDJSON stderr sink is implemented; configurable file sinks are not shipped. |
| Live external profile | The credential-free suite uses local Markdown tickets, injected Linear and GitHub transports, fake Codex processes, real hooks, and a real loopback server. Live provider and Codex smoke profiles remain operator-run production validation. |

These are explicit scope choices. They are not required by the upstream core
specification and do not hide a DBOS, Kameo, or Photon dependency.

## Verification contract

The default verification requires no tracker token and no live Codex service:

```sh
v fmt -verify bin symphony
v vet bin symphony
v test symphony
v -prod -o build/symphony bin/symphony
build/symphony version
build/symphony validate WORKFLOW.example.md
build/symphony doctor WORKFLOW.md
```

The tests use temporary Markdown queues, real shell subprocesses, injected
Linear and GitHub HTTP transports, a fake Codex app-server, and a live loopback
`veb` server. Live provider and Codex smoke tests remain opt-in operational
checks.
