# Symphony Local File Tracker Design

## Goal

Run Symphony from a local, human-readable ticket directory with no Linear API
access at runtime. Import an operator-selected issue queue as one Markdown file
per ticket.

## Selected approach

Use `tickets/<IDENTIFIER>.md`, with YAML frontmatter for scheduling metadata and
Markdown for the complete issue description and exported comments. This keeps
each ticket independently readable and editable while avoiding a monolithic
JSON manifest or state-encoded directory moves.

The workflow selects the adapter with:

```yaml
tracker:
  kind: file
  provider:
    root: ./tickets
  active_states:
    - Todo
    - In Review
    - In Progress
```

The provider root resolves relative to the workflow file, like the workspace
root. The local adapter declares no secrets and performs no network requests.

## Ticket contract

Every direct child of the configured directory whose name ends in `.md` is one
ticket. Nested directories and non-Markdown files are ignored. Files use this
shape:

```markdown
---
schema_version: 1
id: "provider-opaque-id"
identifier: SYM-400
title: Refresh dashboard summaries after edits
state: Todo
priority: 2
labels:
  - bug
  - dashboard
branch_name: agent/sym-400-refresh-dashboard-summaries
source_url: https://tracker.example/issues/SYM-400
assignee_id: "user-id"
assignee_name: Example Operator
parent_identifier: SYM-385
created_at: "2026-07-15T21:20:23.626Z"
updated_at: "2026-07-15T21:23:25.923Z"
dispatch_status: pending
last_error: ""
completed_at: ""
blocked_by: []
---

Full issue description.

## Exported comments

Comments are rendered chronologically with their author and timestamp.
```

Required fields are `schema_version`, `id`, `identifier`, `title`, `state`, and
`dispatch_status`. `schema_version` must be `1`. `dispatch_status` accepts only
`pending`, `completed`, or `blocked`. Optional fields normalize to the same
provider-neutral `domain.Issue` defaults used by the Linear adapter.

The description is the Markdown body after the closing frontmatter delimiter,
including the exported comments section. The adapter retains source metadata
for provenance but never calls Linear.

## Adapter behavior

Add `FileClient` behind the existing `tracker.Tracker` interface and select it
for `tracker.kind: file`.

- `fetch_issues_by_states` parses a complete directory snapshot, validates all
  ticket files, rejects duplicate IDs or identifiers, and returns pending
  tickets whose state matches the requested states.
- `fetch_issues_by_ids` performs the same strict snapshot validation and returns
  matching pending, completed, or blocked tickets in requested-ID order so
  reconciliation can observe persisted state.
- Completed and blocked tickets normalize with `dispatchable: false`.
- Ticket filenames are informational; identity comes from frontmatter. Exported
  files use the sanitized Linear identifier for predictable names.
- A malformed file, unsupported schema version, invalid dispatch status,
  duplicate identity, unreadable root, or unsafe completion target fails the
  operation with a categorized `file_tracker_*` error. No ticket is silently
  dropped.
- Files are bounded to 1 MiB each and the directory is bounded to 10,000 direct
  Markdown files.

## Persisted outcomes

Extend the tracker seam with an outcome-recording operation. The Linear adapter
keeps its current read-only behavior. The file adapter updates only local
dispatch metadata:

- `succeeded`: atomically write `dispatch_status: completed`, clear
  `last_error`, and set `completed_at`; the orchestrator releases the claim
  instead of scheduling another continuation.
- `blocked`: atomically write `dispatch_status: blocked` and persist the bounded
  reason while retaining the in-memory blocked row for the dashboard.
- `failed`, `timed_out`, `stalled`, or `process_exited`: keep the ticket pending
  and persist the bounded error; the existing retry policy remains authoritative.
- `canceled`: keep the ticket pending without manufacturing completion.

Updates re-read the current file, change only dispatch-owned fields, preserve
operator edits and the Markdown body, write a sibling temporary file, then
rename it over the original. A persistence failure is logged and must not turn a
pending ticket into a completed one. Editing `dispatch_status` back to `pending`
requeues a completed or blocked ticket.

Running status remains in memory rather than being written to disk, preventing
stale `running` markers after process crashes.

## Provider export

The one-time export uses a connected provider reader, not Symphony runtime
credentials. Export the operator-selected tickets in configured active states.

For each issue, fetch the full description and relevant scheduling metadata,
relations, parent references, and comments. Generate deterministic
`tickets/<IDENTIFIER>.md` files with `dispatch_status: pending`. The export does
not mutate the source provider.

## Documentation and local configuration

Update `WORKFLOW.md` and `WORKFLOW.example.md` to use the file tracker and all
three active states. Make the local workflow the primary README/tutorial path.
`SYMPHONY_REPOSITORY_URL` remains required for cloning the repository agents
edit; `LINEAR_API_KEY` is no longer required for local operation. Keep the
Linear adapter documentation as an optional provider reference.

The dashboard remains an operations view of running, retrying, and blocked
attempts. Displaying the complete pending backlog is outside this change.

## Test seams

Tests exercise public behavior at these seams:

1. `FileClient.fetch_issues_by_states` and `fetch_issues_by_ids`: valid parsing,
   state filtering, persisted-status routing, duplicate detection, malformed
   files, limits, and requested-ID order.
2. `FileClient.record_outcome`: atomic completion, blocking, failure metadata,
   body preservation, and missing/changed target errors.
3. `tracker.new_adapter`: selects `file`, resolves its root relative to the
   workflow, and keeps `linear` behavior intact.
4. CLI/runtime boundary: the checked-in file workflow validates and `run
   --once` gets past adapter construction with a controlled non-dispatchable
   fixture.
5. Export validation: imported ticket files parse and have unique IDs and
   identifiers.

Run focused tracker tests during red/green cycles, then formatting, all 15-plus
test files, vet, a production build, and CLI smoke tests.

## Non-goals

- No live Linear synchronization or import command.
- No Linear mutation.
- No Git repository, commit, GitHub repository, or pull request.
- No database or durable workflow engine.
- No redesign of the status dashboard backlog model.
