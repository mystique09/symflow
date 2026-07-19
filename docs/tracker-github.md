# GitHub Projects Tracker

The GitHub tracker treats one GitHub Project as the work queue. It reads the
Project's items, accepts only items whose content is a GitHub Issue, and maps the
Project's single-select `Status` field into Symphony workflow states. An issue is
therefore visible to Symphony only after it has been added to the configured
Project.

Pull requests, draft issues, redacted items, and issues outside the Project are
not dispatched. A Project may contain issues from multiple repositories.

## Find the Project scope

Organization-owned Project URLs look like:

```text
https://github.com/orgs/OWNER/projects/NUMBER
```

User-owned Project URLs look like:

```text
https://github.com/users/OWNER/projects/NUMBER
```

Use `organization` or `user` for `owner_type`, copy `OWNER` into `owner`, and
copy the final integer into `project_number`. This is separate from
`SYMPHONY_REPOSITORY_URL`, which remains the Git clone URL for the code Codex
will edit.

GitHub documents Project item content and the Projects v2 API in its
[Projects GraphQL reference](https://docs.github.com/en/graphql/reference/projects)
and [Projects API guide](https://docs.github.com/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects).

## Read-only configuration

```yaml
tracker:
  kind: github
  provider:
    owner_type: organization
    owner: your-organization
    project_number: 7
    token: $GITHUB_TOKEN
    status_field: Status
    state_options:
      Todo: Todo
      In Progress: In Progress
      In Review: In Review
      Agent Complete: Agent Complete
      Blocked: Blocked
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

`owner_type` defaults to `organization`; `status_field` defaults to `Status`.
`state_options` maps each Symphony state to the exact option displayed in that
single-select Project field. Comparisons trim space and ignore case, but every
state and option must remain one-to-one. Every active state needs a mapping.

The Project, field, and configured options are checked against GitHub before a
workflow becomes effective. A missing Project, wrong owner type, misspelled
field, or missing option is reported as `tracker_scope` instead of becoming an
empty queue.

`token` accepts a literal host-owned value or one `$ENV_NAME` reference. When
omitted, it defaults to `$GITHUB_TOKEN`. Environment references are recommended:
Symphony removes the declared variable from every workspace hook and Codex child
process and redacts the resolved value from its logs.

For an organization Project, a fine-grained token needs the organization's
Projects permission set to read. Write mode needs Projects write permission.
Classic tokens use `read:project` or `project`. Follow GitHub's
[Project token guidance](https://docs.github.com/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects#authenticating-to-the-graphql-api).

## How items become tickets

Candidate polling reads Project items in Project position order with bounded
cursor pagination. Each item must:

- contain an Issue rather than a pull request or draft;
- have a valid repository, issue number, node ID, URL, title, and timestamps;
- have one value in the configured single-select status field; and
- map that status option to a configured Symphony state.

Malformed or unmapped candidates are omitted with a safe warning. A malformed
already-claimed issue fails strict refresh. Closed Issues normalize to
`closed_state`, which defaults to `Closed` and must be terminal.

Issue labels are independent of Project status. Returned issue labels are
normalized for `required_labels` routing; changing the Project status never
replaces or removes repository labels. The bounded Project query reads up to 100
labels per Issue. An Issue reporting more labels is omitted rather than routed
from an incomplete label set, and strict refresh treats it as malformed.

| Symphony field | GitHub source |
| --- | --- |
| `id` | Adapter-owned `github:owner/repository#123` opaque identity. |
| `identifier` | Human-facing `owner/repository#123`. |
| `native_ref` | Issue node ID, repository and number, Project ID and number, Project item ID, status field ID, and status option ID. |
| `title`, `description`, `url` | Underlying Issue title, body, and URL. |
| `state` | Mapped Project status option, or `closed_state` for a closed Issue. |
| `labels` | Normalized underlying Issue labels. |
| `assignee_id` | First Issue assignee login when present. |
| `created_at`, `updated_at` | Valid Issue timestamps. |
| `dispatchable` | True only for an open Project Issue in an active mapped state. |

Opaque-ID refresh re-reads the configured Project, removes duplicate requested
IDs, preserves caller order, and omits issues removed from the Project. This
keeps Project membership—not repository membership—as the reconciliation
boundary.

## Optional outcome writes

Writes are disabled by default. Enable them explicitly:

```yaml
tracker:
  kind: github
  provider:
    owner_type: organization
    owner: your-organization
    project_number: 7
    token: $GITHUB_TOKEN
    status_field: Status
    state_options:
      Todo: Todo
      In Progress: In Progress
      Agent Complete: Agent Complete
      Blocked: Blocked
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

`success_state` and `blocked_state` must be distinct mapped terminal states and
must not be active. A successful attempt changes only the Project's configured
status field to the success option. An operator-input block changes it to the
blocked option. The underlying Issue stays open, and issue labels and every
other Project field remain untouched.

Failures, timeouts, stalls, process exits, and cancellations do not update the
Project. A failed mutation is a tracker error and never counts as persisted
completion. In read-only mode, a human or external automation must advance the
Project status to stop continuation behavior.

## Validate and operate

`validate` checks the local shape without requiring a live token. `run` verifies
the Project, status field, and options before accepting startup or a workflow
reload. `doctor` resolves the token and verifies adapter construction.

```sh
build/symphony validate WORKFLOW.md
build/symphony doctor WORKFLOW.md
build/symphony run WORKFLOW.md --once
```

If no issue starts, confirm that the item is actually in the selected Project,
its content type is Issue, its Status option is mapped and active, the Issue is
open, and required labels match. HTTP 401 means the credential was rejected;
HTTP 403 is classified separately as a permission failure or rate limit.
