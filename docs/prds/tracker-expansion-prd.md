# Linear Team and GitHub Projects Tracker Product Requirements Document

## Problem Statement

Symphony can currently use local Markdown tickets or a Linear project as its
source of work. This excludes teams that organize Linear issues directly under
a team without assigning them to a Linear Project. It also excludes teams whose
work queue is maintained in GitHub Projects. Operators must either reshape
their tracker data or export tickets to local files before Symphony can dispatch
them.

The tracker contract is already provider-neutral, but each adapter must define
safe scope, state normalization, pagination, blocker handling, identity,
credentials, and outcome behavior. Linear workspace URL slugs must not be
mistaken for project slugs, and a human-readable issue prefix must not become an
authorization or scoping boundary. A GitHub Project can contain issues, pull
requests, and drafts across multiple repositories, so Project membership and a
single-select status field must become explicit tracker boundaries.

## Solution

Extend the existing Linear adapter with a team-scoped mode and add a GitHub
Projects adapter scoped to one organization- or user-owned Project. Existing
Linear project configuration will remain compatible. Linear configurations
will select exactly one scope: an exact project slug or an exact team key. Both
candidate reads and opaque-ID refreshes will enforce the selected scope.

The GitHub adapter will read Project items and use a configurable single-select
status field to produce normalized Symphony issue states. It will accept only
Issue content, exclude pull requests and drafts, preserve Issue labels, paginate
in Project position order, and use a stable repository-and-number identity that
remains opaque outside the adapter. Safe read-only operation will be supported.
An explicitly enabled write mode will persist successful and blocked outcomes
through dedicated terminal status options while leaving issues open for human
review.

Both adapters will continue to implement the common tracker contract. The
orchestrator, scheduler, prompt renderer, workspace lifecycle, Codex transport,
and status surface will remain provider-neutral.

## User Stories

1. As a Linear operator, I want Symphony to read team-scoped issues that have no project, so that I do not need to create an artificial project.
2. As a Linear operator, I want existing project-scoped workflows to remain valid, so that the expansion does not disrupt current installations.
3. As a workflow author, I want project and team scope to be mutually exclusive, so that a configuration cannot silently select an unintended union of work.
4. As a workflow author, I want a missing Linear scope rejected during validation, so that Symphony cannot poll an entire workspace accidentally.
5. As a workflow author, I want a workspace URL slug rejected when supplied as a project scope that does not exist, so that tracker terminology mistakes are actionable.
6. As a Linear operator, I want team scope based on the provider's team key, so that the issue prefix and the selected team stay aligned.
7. As a Linear operator, I want the human-readable issue prefix treated as display metadata rather than a security boundary, so that scope is enforced using provider data.
8. As a Linear operator, I want candidate reads limited to the configured team and active states, so that unrelated team work is never scheduled.
9. As a Linear operator, I want issue refreshes limited to the same configured team, so that reconciliation cannot adopt an issue from another scope.
10. As a Linear operator, I want project and team modes to retain assignee filtering, so that existing ownership rules continue to work.
11. As a Linear operator, I want blocker relations normalized in team mode, so that Todo work with unresolved blockers remains non-dispatchable.
12. As a Linear operator, I want team-mode pagination to behave like project-mode pagination, so that large queues do not hide eligible issues.
13. As a GitHub operator, I want one GitHub Project to be Symphony's queue, so that Project membership is the explicit dispatch boundary.
14. As a GitHub operator, I want organization- and user-owned Projects supported, so that either ownership model can host the queue.
15. As a GitHub operator, I want private Projects supported with a host-owned credential, so that internal work can be orchestrated safely.
16. As a GitHub operator, I want only Issue content dispatched, so that pull requests, drafts, and redacted items never become coding tickets.
17. As a workflow author, I want each Symphony state mapped to one Project status option, so that Project workflow meaning is explicit.
18. As a workflow author, I want duplicate state or option mappings rejected, so that two Symphony states cannot claim the same Project status.
19. As an operator, I want Project Issues with no mapped Status omitted safely, so that incomplete board items are not dispatched accidentally.
20. As an operator, I want a missing Project, status field, or configured option rejected before activation, so that a configuration typo cannot become an empty queue.
21. As an operator, I want closed GitHub Issues normalized to a terminal state, so that their workspaces can be reconciled and cleaned.
22. As an operator, I want GitHub Issue labels preserved and normalized independently of Project status, so that required-label scheduling continues to work.
23. As an operator, I want Project position order preserved across pagination, so that dispatch follows the board's priority.
24. As an operator, I want GitHub Issue identity stable across Project moves, titles, statuses, labels, and assignee changes, so that a running claim remains attached to the same issue.
25. As an operator, I want GitHub Issue URLs, repositories, and numbers exposed in normalized issue data, so that logs and the dashboard link to the source ticket.
26. As an operator, I want GitHub Issue refreshes scoped to current Project membership, preserving caller order and removing duplicate IDs, so that reconciliation matches the tracker contract.
27. As an operator, I want authentication failures, permission failures, rate limits, malformed responses, scope failures, and transport failures reported distinctly, so that remediation is clear.
28. As a security owner, I want tracker credentials declared by each adapter and removed from hooks and Codex child processes, so that agents cannot inspect provider secrets.
29. As a security owner, I want literal credential values omitted from logs and errors, so that diagnostics are safe to retain.
30. As a GitHub operator, I want a read-only mode, so that I can evaluate polling and reconciliation without authorizing Project mutation.
31. As a GitHub operator, I want outcome writes to require explicit configuration, so that installing the adapter does not silently modify the Project.
32. As a GitHub operator, I want a successful agent attempt to select a dedicated terminal Status option while leaving the Issue open, so that human review remains possible without redispatch.
33. As a GitHub operator, I want an operator-input block to select a distinct blocked Status option while leaving the Issue open, so that attention-needed work is visible in the Project.
34. As a GitHub operator, I want failures, timeouts, stalls, process exits, and cancellations to preserve the current Project status, so that Symphony's retry policy remains authoritative.
35. As a GitHub operator, I want Issue labels and unrelated Project fields preserved during outcome updates, so that categorization and planning metadata are not destroyed.
36. As an operator, I want a persisted terminal outcome to stop continuation attempts, so that completed work is not launched repeatedly.
37. As an operator, I want read-only outcomes to retain the existing tracker-driven continuation behavior, so that external automation can still advance the issue.
38. As a workflow author, I want invalid state mappings and outcome states rejected before dispatch, so that errors appear early.
39. As an operator, I want workflow reloads to validate a replacement adapter's live scope before applying it, so that a bad tracker edit preserves the last known good runtime configuration.
40. As a developer, I want Linear team and GitHub Project adapters tested through the shared tracker contract, so that scheduler behavior does not acquire provider-specific branches.
41. As a developer, I want deterministic provider fixtures in the default suite, so that tests require no network access or live credentials.
42. As a release engineer, I want optional live smoke profiles separated from the default suite, so that production access is never required in CI.
43. As a new operator, I want focused configuration and troubleshooting documentation for each scope, so that I can select a tracker without learning provider internals.

## Implementation Decisions

- The common tracker interface remains the only orchestration dependency. It
  continues to expose candidate reads by state, refreshes by opaque ID, outcome
  recording, and secret metadata.
- Linear provider configuration accepts exactly one of a project slug or a team
  key. Supplying both or neither is a validation error. Existing project-scoped
  configuration retains its current meaning.
- A Linear workspace URL slug is not a project selector. The adapter will not
  reinterpret it as one, and an issue prefix will not be accepted as a separate
  scope when a team key is available.
- Linear candidate and ID-refresh operations use scope-specific GraphQL filters.
  Team mode filters by the exact team key; project mode continues to filter by
  the exact project slug.
- Linear scope selection does not change pagination, assignee matching, required
  record validation, label normalization, blocker normalization, or the existing
  read-only outcome policy.
- The GitHub adapter is scoped by Project owner type, owner login, and Project
  number. Organization- and user-owned Projects are supported. A Project may
  contain issues from multiple repositories.
- GitHub candidate reads use the Projects v2 GraphQL API with bounded cursor
  pagination ordered by Project item position. Only `ISSUE` content is
  normalized; pull requests, drafts, and redacted items are ignored.
- A GitHub issue's opaque Symphony ID is a stable, adapter-owned composite of
  repository identity and issue number. The provider node ID, repository, and
  number plus Project, item, status field, and option IDs remain in the native
  reference for diagnostics and outcome writes.
- GitHub ID refresh validates IDs produced by the adapter, re-reads the Project,
  treats duplicate input as a set, returns found issues in requested order, and
  omits issues that are no longer Project members.
- GitHub status configuration maps each Symphony state name to exactly one
  single-select Project option. State and option names use documented
  normalization while provider option IDs are discovered live for writes.
- Closed GitHub Issues normalize to the configured closed terminal state. Open
  Project Issues require one recognized status option. Missing or unmapped
  statuses omit a candidate safely and fail strict refresh of a requested item.
- Issue labels are independent of Project status and are normalized through the
  shared domain behavior for required-label routing. The bounded query detects
  label overflow and omits or rejects the Issue rather than routing from a
  truncated label set.
- GitHub outcome mutation is opt-in. Write mode requires configured success and
  blocked states that are distinct, have status-option mappings, and are
  terminal rather than active.
- A successful GitHub outcome updates only the configured Project status field
  to the success option. A blocked outcome selects the blocked option. Neither
  closes the Issue, rewrites Issue labels, nor touches unrelated Project fields.
  Other outcomes do not mutate provider state.
- GitHub outcome updates re-read Project membership and option IDs before the
  transition. A failed provider mutation is a tracker error and is not treated
  as persisted completion.
- Read-only GitHub mode performs no mutation and reports that completion was not
  persisted, preserving the existing continuation contract for read-only
  adapters.
- Provider credentials may be literal host-owned values or environment
  references, but environment references are the documented recommendation.
  Adapters declare both secret environment names and resolved secret values for
  child-process isolation and log redaction.
- HTTP timeouts, response-size limits, pagination-loop detection, and stable
  error categories follow the safety posture of the existing Linear adapter.
- Adapter construction validates local shape. Startup and workflow reload verify
  live Linear or GitHub Project scope before the configuration becomes effective,
  including the Project status field and configured options.
- The status dashboard and prompt context use the existing normalized issue
  fields. They require no provider-specific conditionals.

## Testing Decisions

- Tests will assert observable behavior through the tracker interface and
  adapter construction. They will not assert private helper names, query-builder
  layout beyond required filters, or internal transport call counts unrelated to
  pagination and safety.
- The primary seam is a tracker contract suite backed by deterministic injected
  HTTP transports. This is the highest existing seam that covers configuration,
  provider requests, normalization, pagination, refresh, outcome recording, and
  secret metadata without launching the full daemon.
- Linear tests will cover project backward compatibility, team-only candidate
  reads, team-only ID refresh, both-scope rejection, missing-scope rejection,
  pagination, assignee matching, terminal blockers, and safe errors.
- GitHub Project tests will cover organization and user ownership, authentication
  metadata, bounded position pagination, Issue-only content, open and closed
  normalization, missing status values, label preservation, stable IDs,
  membership-scoped refresh, duplicate refresh IDs, and strict failures.
- GitHub write-mode tests will cover successful and blocked status-option updates,
  distinct terminal mappings, preservation of Issue labels and unrelated Project
  fields, no mutation for abnormal outcomes, mutation failures, and read-only behavior.
- Adapter-factory tests will verify kind selection, provider-owned validation,
  default credential references, custom credential references, and secret
  reporting without placing credential values in assertions or diagnostics.
- One orchestrator integration test will use provider-neutral issue fixtures to
  confirm that non-dispatchable adapter output never starts a worker. Provider
  request details will remain in adapter tests.
- Default verification will use local fixture responses and temporary files. It
  will require neither network access nor live tracker credentials.
- Optional smoke profiles will validate one isolated Linear team and one isolated
  GitHub Project Issue using operator-supplied credentials. Smoke profiles
  must be explicit, bounded, and safe to skip.
- Documentation examples will be checked for mutually exclusive Linear scopes,
  valid Project owner and number syntax, non-conflicting Project status options,
  and the absence of literal credentials.

## Out of Scope

- GitHub Project views and view filters, multi-Project unions, repository-wide or
  organization-wide issue search, and using draft issues as dispatchable work.
- Treating pull requests, discussions, security alerts, or dependency alerts as
  dispatchable tracker issues.
- Automatic issue creation, comment synchronization, milestone management,
  assignee mutation, pull-request creation, merging, or deployment.
- Automatically closing GitHub issues after a successful agent attempt.
- GitHub webhooks or replacing the existing polling and reconciliation loop with
  event-driven dispatch.
- GitHub App installation flows, OAuth user flows, and organization-wide token
  brokerage in the initial release.
- Linear issue mutation, provider-native Codex tools, or automatic migration of
  team-scoped issues into projects.
- Using a Linear workspace slug or human-readable issue prefix as the primary
  provider scope.
- Combining multiple Linear projects, multiple Linear teams, or project and team
  scope in one adapter instance.
- Changes to scheduler ownership, durable retry storage, DBOS integration,
  remote workers, or the Codex app-server protocol.
- Importing existing tracker issues into the local Markdown tracker.

## Further Notes

- The upstream Symphony tracker contract permits provider scopes such as teams
  and Projects, so these adapters extend the integration surface without
  changing the orchestration model.
- Team scope is the smallest compatible correction for Linear workspaces that do
  not use Projects. It should be delivered before GitHub support because it is a
  contained extension of the existing query and validation paths.
- GitHub Project membership and the configured Status field are a deliberate
  workflow contract, not best-effort inference. Requiring an explicit Project
  and mapped options prevents Symphony from treating every repository issue as
  agent-ready work.
- Leaving successful and blocked GitHub issues open separates Symphony's dispatch
  terminal state from the team's human review and closure policy.
- The project remains local. This PRD does not authorize creating remote issues,
  repositories, pull requests, or releases.
