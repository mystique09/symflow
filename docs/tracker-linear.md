# Linear Tracker Adapter Profile

This is the compact provider profile required by the upstream Symphony
specification. The adapter is selected with the exact value:

```yaml
tracker:
  kind: linear
```

## Provider configuration

All provider-owned settings live under `tracker.provider`. Unknown keys are
preserved by the workflow loader and ignored by this adapter.

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `endpoint` | No | `https://api.linear.app/graphql` | Linear GraphQL endpoint. |
| `api_key` | No | `$LINEAR_API_KEY` | Literal API key or a single `$ENV_NAME` reference. Environment references are recommended. |
| `project_slug` | Yes | none | Exact Linear project `slugId`; all reads are scoped to this project. |
| `assignee` | No | empty | Linear user ID. Empty accepts project-routed issues; a value requires an exact assignee-ID match. |

`tracker.required_labels`, `tracker.active_states`, and
`tracker.terminal_states` are common Symphony settings, not provider keys. The
workflow defaults active states to `Todo` and `In Progress`, and terminal states
to `Closed`, `Cancelled`, `Canceled`, `Duplicate`, and `Done`.

If `api_key` is `$NAME`, the adapter resolves it when selected, declares `NAME`
as a secret environment variable, and the Codex launcher removes it from the
child environment. If `api_key` is omitted, the adapter resolves and declares
`LINEAR_API_KEY`. Literal credentials are supported for host-owned workflows but
are discouraged because the environment-isolation boundary cannot hide text
already present in a repository-owned workflow file.

## Scope, operations, and limits

The adapter implements exactly the two required read operations:

- `fetch_issues_by_states(state_names)`
- `fetch_issues_by_ids(issue_ids)`

Empty lists return immediately without configuration validation or a provider
request. State reads filter by exact project `slugId` and state names, request
50 issues per page, and follow `pageInfo.endCursor` while rejecting missing or
repeated cursors. ID refreshes treat input IDs as a set, batch 50 IDs per
request, preserve input order, and return each found issue at most once.

The current request timeout is 30 seconds, the HTTP response limit is 8 MiB,
and inverse blocker relations are requested with a limit of 50 per issue.

## Normalized issue mapping

| Symphony field | Linear source and normalization |
| --- | --- |
| `id` | Linear issue `id`, retained as the opaque dispatch identity. |
| `native_ref` | JSON-safe object containing `linear_issue_id`. No credential or secret is retained. |
| `identifier` | Linear issue key such as `ENG-42`. |
| `title` | Trimmed title. |
| `description` | Description, or an empty string when absent or unusable. |
| `priority` | Integer priorities 1–4 sort before unknown, zero, or out-of-range values. |
| `state` | Provider spelling from `state.name`; only scheduler comparisons normalize case/space. |
| `branch_name`, `url` | Provider strings, or empty when absent or unusable. |
| `labels` | Names are trimmed, lowercased, de-duplicated, sorted, and blank values are dropped. |
| `blocked_by` | Linear inverse relations whose type is `blocks`, retained as best-effort metadata. |
| `created_at`, `updated_at` | ISO-8601 strings; invalid values normalize to empty. |
| `assignee_id` | Linear assignee ID, or empty. |
| `dispatchable` | Explicit adapter output. It requires the configured assignee match. A `Todo` issue also requires no blocker outside configured terminal states. |

`id`, `identifier`, `title`, and `state` are required. State-list reads omit a
record missing any required field and emit a `tracker_record_omitted` warning.
ID refresh is strict: any malformed returned requested record fails the whole
refresh with `tracker_response`, so active work is never silently treated as
missing. Unusable optional values normalize to empty collections, empty
strings, `-1` priority, or omitted timestamps without hiding an otherwise valid
issue.

## Tools and mutation boundary

This adapter advertises no provider-native Codex tools and performs no Linear
mutations. It is a tracker reader for scheduling and reconciliation. Unexpected
Codex `item/tool/call` requests receive a structured unsupported-tool failure
and the Codex session continues. Approval, elicitation, and user-input requests
become an operator-visible blocked attempt.

## Error mapping

V errors use a stable category prefix followed by a human-readable message:

| Category | Conditions |
| --- | --- |
| `unsupported_tracker_kind` | Adapter selection receives a kind other than `linear`. |
| `invalid_tracker_config` | Endpoint or project slug is missing. |
| `missing_tracker_secret` | The literal or resolved API key is empty. |
| `tracker_request` | DNS, connection, timeout, TLS, or other HTTP transport failure. |
| `tracker_status` | Non-success HTTP response, including rejected credentials. |
| `tracker_response` | Invalid JSON, GraphQL errors, missing response structure, or malformed strict ID-refresh record. |
| `tracker_pagination` | A paginated response omits or repeats `endCursor`. |
| `tracker_rate_limited` | Linear returns HTTP 429. |

The orchestrator uses only success versus failure. Category text supports
portable logs and diagnostics; messages never include the configured API key.
