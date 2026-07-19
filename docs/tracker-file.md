# Local File Tracker

The file tracker makes a directory of Markdown files Symphony's source of work.
It requires no Linear API key and performs no tracker network calls.

## Configuration

```yaml
tracker:
  kind: file
  provider:
    root: ./tickets
  required_labels: []
  active_states:
    - Todo
    - In Review
    - In Progress
```

`root` is required. Relative paths are resolved from the directory containing
`WORKFLOW.md`, not from the shell's current directory. The directory must exist.
Only direct `*.md` children are read; nested directories are ignored.

## Ticket format

Each ticket starts with YAML frontmatter followed by its complete Markdown
description:

```markdown
---
schema_version: 1
id: "provider-opaque-id"
identifier: "SYM-400"
title: "Refresh dashboard summaries after edits"
state: "Todo"
priority: 2
labels:
  - "bug"
  - "dashboard"
branch_name: "agent/sym-400-refresh-dashboard"
source_url: "https://tracker.example/issues/SYM-400"
assignee_id: ""
assignee_name: ""
parent_identifier: ""
created_at: "2026-07-16T00:00:00Z"
updated_at: "2026-07-16T00:00:00Z"
dispatch_status: pending
last_error: ""
completed_at: ""
blocked_by: []
---

The full task description goes here.
```

Required fields are `schema_version: 1`, `id`, `identifier`, `title`, `state`,
and `dispatch_status`. IDs and identifiers must be unique across the directory.
The accepted dispatch statuses are:

- `pending`: eligible when the state, labels, slots, and blockers also allow it;
- `completed`: retained for history and never dispatched;
- `blocked`: retained for operator attention and never dispatched.

An operator can populate `tickets/` with a provider export. Original state,
labels, descriptions, comments, relations, assignees, and source URLs can be
retained for context. The runtime does not synchronize these files back to the
source provider.

## Outcome behavior

Symphony updates only dispatch-owned top-level fields and preserves the Markdown
body:

| Attempt result | File update | Automatic retry |
| --- | --- | --- |
| Success | `dispatch_status: completed`, set `completed_at` | No |
| Needs operator input | `dispatch_status: blocked`, set `last_error` | No |
| Failure, timeout, stall, process exit | keep `pending`, set `last_error` | Yes, using normal backoff |
| Cancellation | keep `pending` | No immediate completion |

The update is written to a protected sibling temporary file and renamed over the
ticket. Before writing, Symphony re-reads and validates the whole directory so
duplicate or malformed tickets stop the poll instead of producing partial work.
Files are limited to 1 MiB each and a directory to 10,000 Markdown tickets.

## Requeue or resolve a ticket

To retry a completed or blocked ticket, edit its frontmatter:

```yaml
dispatch_status: pending
last_error: ""
completed_at: ""
```

Save the file, then restart Symphony or call `POST /api/v1/refresh`. To resolve a
blocked ticket without rerunning it, set `dispatch_status: completed` and add a
`completed_at` timestamp manually.

Use `build/symphony doctor WORKFLOW.md` to validate the adapter and directory
without dispatching anything. `build/symphony run WORKFLOW.md --once` is not a
dry run: it can launch pending tickets immediately.
