# GitHub Issues Tracker

The GitHub tracker polls issues from exactly one repository and translates
explicit status labels into Symphony workflow states. It does not use GitHub
Projects, organization-wide search, pull requests, discussions, or webhooks.

## Read-only configuration

```yaml
tracker:
  kind: github
  provider:
    repository: owner/repository
    token: $GITHUB_TOKEN
    state_labels:
      Todo: "status:todo"
      In Progress: "status:in-progress"
      In Review: "status:in-review"
      Agent Complete: "status:agent-complete"
      Blocked: "status:blocked"
    closed_state: Closed
  active_states:
    - Todo
    - In Progress
    - In Review
  terminal_states:
    - Closed
    - Agent Complete
    - Blocked
```

`repository` must be one `owner/name` pair. `token` accepts a literal host-owned
value or one `$ENV_NAME` reference. When omitted, it defaults to
`$GITHUB_TOKEN`. Environment references are recommended: Symphony removes the
declared variable from hooks and Codex child processes and redacts the resolved
value from its own logs.

`state_labels` is an explicit one-to-one mapping. Every active state requires a
label, and two states cannot normalize to the same label. Label comparisons trim
space and ignore case; the configured spelling is retained for writes. Open
issues with no recognized status label or more than one recognized status label
are omitted from candidate polling. Strict refresh of an already claimed issue
fails if the state becomes ambiguous.

`closed_state` defaults to `Closed` and must be present in
`tracker.terminal_states`. Closed GitHub issues normalize to that state without
requiring a status label.

For public repositories, an unauthenticated mode is intentionally not provided.
Use a fine-grained token with repository metadata and Issues read access. Keep
automatic outcome writes disabled when evaluating the adapter or when the token
is read-only.

## Optional outcome writes

Writes are disabled by default. Enable them explicitly:

```yaml
tracker:
  kind: github
  provider:
    repository: owner/repository
    token: $GITHUB_TOKEN
    state_labels:
      Todo: "status:todo"
      In Progress: "status:in-progress"
      Agent Complete: "status:agent-complete"
      Blocked: "status:blocked"
    closed_state: Closed
    write_outcomes: true
    success_state: Agent Complete
    blocked_state: Blocked
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Closed
    - Agent Complete
    - Blocked
```

Write mode requires Issues write permission. `success_state` and
`blocked_state` must both have status-label mappings, must be terminal, and must
not be active.

Before updating an issue, Symphony re-reads its current labels. It removes only
recognized status labels, preserves every non-status label with provider
spelling, and applies the configured terminal label. Successful and blocked
issues remain open for human review. Failures, timeouts, stalls, process exits,
and cancellations do not mutate GitHub. A failed mutation is reported as a
tracker error and never counts as persisted completion.

In read-only mode, all outcomes remain provider-owned and Symphony reports no
persisted completion. External automation or a human must advance the status
label to stop continuation behavior.

## Reads, identity, and limits

Candidate polling uses GitHub's repository Issues REST endpoint with
`state=all`, 100 records per page, and a maximum of 100 pages. Pull requests are
excluded whenever the response contains pull-request metadata. Pagination URLs
must stay under the configured repository endpoint; repeated, cross-scope, or
overlong pagination fails safely before another credentialed request.

Candidate issues are sorted by issue number after all pages are normalized.
Status labels are excluded from `issue.labels`; other labels are trimmed,
lowercased, de-duplicated, and sorted for required-label scheduling.

| Symphony field | GitHub source |
| --- | --- |
| `id` | Adapter-owned `github:owner/repository#123` opaque identity. |
| `identifier` | Human-facing `owner/repository#123`. |
| `native_ref` | GitHub node ID, repository, and issue number. |
| `title`, `description`, `url` | Issue title, body, and `html_url`. |
| `state` | The one mapped status-label state, or `closed_state`. |
| `labels` | Non-status issue labels only. |
| `assignee_id` | Primary assignee login when present. |
| `created_at`, `updated_at` | Valid ISO-8601 provider timestamps. |
| `dispatchable` | True only for an unambiguous open issue in an active state. |

Opaque-ID refresh accepts only IDs for the configured repository, removes
duplicates, preserves caller order, skips missing issues, and fails on malformed
or ambiguous returned records.

HTTP reads and writes use 30-second timeouts and an 8 MiB response limit.
Authentication, permission, rate-limit, response, pagination, and transport
failures have distinct safe error prefixes. Provider response bodies and token
values are never included in those errors.

## Validate and operate

`validate` checks repository syntax, state-label uniqueness, active-state
coverage, terminal-state rules, and outcome-write configuration without
requiring a live token. `doctor` additionally resolves the token and constructs
the live adapter.

```sh
build/symphony validate WORKFLOW.md
build/symphony doctor WORKFLOW.md
build/symphony run WORKFLOW.md --once
```

If no issue starts, verify that it is an issue rather than a pull request, is
open, has exactly one configured status label, satisfies required labels, and
is not already claimed. HTTP 401 indicates an invalid credential; HTTP 403 is
reported separately as a permission failure or rate limit.
