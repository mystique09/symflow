# Linear Team and GitHub Issues Tracker Product Requirements Document

## Problem Statement

Symphony can currently use local Markdown tickets or a Linear project as its
source of work. This excludes teams that organize Linear issues directly under
a team without assigning them to a Linear Project. It also excludes repositories
whose work queue is maintained in GitHub Issues. Operators must either reshape
their tracker data or export tickets to local files before Symphony can dispatch
them.

The tracker contract is already provider-neutral, but each adapter must define
safe scope, state normalization, pagination, blocker handling, identity,
credentials, and outcome behavior. Linear workspace URL slugs must not be
mistaken for project slugs, and a human-readable issue prefix must not become an
authorization or scoping boundary. GitHub's open and closed states are also too
coarse to represent workflow states such as Todo, In Progress, and In Review
without an explicit label policy.

## Solution

Extend the existing Linear adapter with a team-scoped mode and add a GitHub
Issues adapter scoped to one repository. Existing Linear project configuration
will remain compatible. Linear configurations will select exactly one scope:
an exact project slug or an exact team key. Both candidate reads and opaque-ID
refreshes will enforce the selected scope.

The GitHub adapter will use repository issues and configurable status labels to
produce normalized Symphony issue states. It will exclude pull requests,
preserve non-status labels, paginate deterministically, and use a stable
repository-and-number identity that remains opaque outside the adapter. Safe
read-only operation will be supported. An explicitly enabled write mode will
persist successful and blocked outcomes through dedicated terminal labels while
leaving issues open for human review.

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
13. As a GitHub operator, I want Symphony to use issues from one repository, so that GitHub can be the source of work without another tracker.
14. As a GitHub operator, I want private repositories supported with a host-owned credential, so that internal work can be orchestrated safely.
15. As a GitHub operator, I want pull requests excluded from issue polling, so that review artifacts are not dispatched as coding tickets.
16. As a workflow author, I want each Symphony state mapped to one explicit GitHub status label, so that open issues have unambiguous workflow meaning.
17. As a workflow author, I want duplicate status-label mappings rejected, so that two workflow states cannot claim the same provider label.
18. As an operator, I want open issues with no recognized status label omitted safely, so that general repository issues are not dispatched accidentally.
19. As an operator, I want open issues with multiple recognized status labels omitted safely, so that conflicting workflow state does not select work nondeterministically.
20. As an operator, I want closed GitHub issues normalized to a terminal state, so that their workspaces can be reconciled and cleaned.
21. As an operator, I want non-status GitHub labels preserved and normalized, so that required-label scheduling continues to work.
22. As an operator, I want stable issue ordering across paginated GitHub responses, so that dispatch remains predictable.
23. As an operator, I want GitHub issue identity stable across title, label, and assignee changes, so that a running claim remains attached to the same issue.
24. As an operator, I want GitHub issue URLs and numbers exposed in normalized issue data, so that logs and the dashboard link to the source ticket.
25. As an operator, I want GitHub issue refreshes to preserve the caller's requested order and remove duplicate IDs, so that reconciliation matches the tracker contract.
26. As an operator, I want authentication failures, permission failures, rate limits, malformed responses, and transport failures reported distinctly, so that remediation is clear.
27. As a security owner, I want tracker credentials declared by each adapter and removed from hooks and Codex child processes, so that agents cannot inspect provider secrets.
28. As a security owner, I want literal credential values omitted from logs and errors, so that diagnostics are safe to retain.
29. As a GitHub operator, I want a read-only mode, so that I can evaluate polling and reconciliation without authorizing issue mutation.
30. As a GitHub operator, I want outcome writes to require explicit configuration, so that installing the adapter does not silently modify repository issues.
31. As a GitHub operator, I want a successful agent attempt to apply a dedicated terminal label while leaving the issue open, so that human review remains possible without redispatch.
32. As a GitHub operator, I want an operator-input block to apply a dedicated blocked label while leaving the issue open, so that attention-needed work is visible in GitHub.
33. As a GitHub operator, I want failures, timeouts, stalls, process exits, and cancellations to preserve the current status label, so that Symphony's retry policy remains authoritative.
34. As a GitHub operator, I want non-status labels preserved during outcome updates, so that categorization and routing metadata are not destroyed.
35. As an operator, I want a persisted terminal outcome to stop continuation attempts, so that completed work is not launched repeatedly.
36. As an operator, I want read-only outcomes to retain the existing tracker-driven continuation behavior, so that external automation can still advance the issue.
37. As a workflow author, I want invalid state mappings and outcome states rejected by validation and doctor commands, so that errors appear before dispatch.
38. As an operator, I want workflow reloads to validate a replacement adapter before applying it, so that a bad tracker edit preserves the last known good runtime configuration.
39. As a developer, I want both adapters tested through the shared tracker contract, so that scheduler behavior does not acquire provider-specific branches.
40. As a developer, I want deterministic provider fixtures in the default suite, so that tests require no network access or live credentials.
41. As a release engineer, I want optional live smoke profiles separated from the default suite, so that production access is never required in CI.
42. As a new operator, I want focused configuration and troubleshooting documentation for each scope, so that I can select a tracker without learning provider internals.

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
- The GitHub adapter is scoped to one repository identified by owner and name.
  Organization-wide search, multi-repository unions, and GitHub Projects are not
  part of the initial adapter.
- GitHub candidate reads use the repository Issues API with bounded pagination.
  Responses containing pull-request metadata are excluded before normalization.
- A GitHub issue's opaque Symphony ID is a stable, adapter-owned composite of
  repository identity and issue number. The provider node ID, repository, and
  number remain available in the native reference for diagnostics and future
  provider operations.
- GitHub ID refresh validates and parses only IDs produced by the adapter, reads
  the corresponding repository issues, treats duplicate input as a set, and
  returns found issues in requested order.
- GitHub state-label configuration maps each Symphony state name to exactly one
  provider label. State names and label names are compared using documented
  normalization, while provider spelling is retained for writes.
- Closed GitHub issues normalize to the configured closed terminal state.
  Open issues must have exactly one recognized status label. Missing or
  conflicting status labels make a candidate non-dispatchable and generate a
  safe warning; the same ambiguity is an error during strict ID refresh.
- Labels used for workflow state are excluded from normalized routing labels.
  All other labels are normalized through the same shared domain behavior used
  by existing adapters.
- GitHub outcome mutation is opt-in. Write mode requires configured success and
  blocked states that have status-label mappings and are included in terminal
  states rather than active states.
- A successful GitHub outcome removes the previous recognized status label and
  applies the configured success label. It does not close the issue. A blocked
  outcome applies the configured blocked label. Other outcomes do not mutate
  provider state.
- GitHub outcome updates preserve every non-status label and re-read current
  labels before applying the transition. A failed provider mutation is reported
  as a tracker error and is not treated as persisted completion.
- Read-only GitHub mode performs no mutation and reports that completion was not
  persisted, preserving the existing continuation contract for read-only
  adapters.
- Provider credentials may be literal host-owned values or environment
  references, but environment references are the documented recommendation.
  Adapters declare both secret environment names and resolved secret values for
  child-process isolation and log redaction.
- HTTP timeouts, response-size limits, pagination-loop detection, and stable
  error categories follow the safety posture of the existing Linear adapter.
- Adapter construction and workflow reload validate provider scope, repository
  syntax, state-label uniqueness, outcome states, and required credentials before
  the configuration becomes effective.
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
- GitHub tests will cover repository parsing, authentication metadata, bounded
  pagination, pull-request exclusion, open and closed state normalization,
  recognized and unrecognized labels, conflicting status labels, routing-label
  preservation, stable IDs, duplicate refresh IDs, and strict refresh failures.
- GitHub write-mode tests will cover successful terminal labeling, blocked
  labeling, preservation of non-status labels, no mutation for abnormal outcomes,
  rejected invalid outcome mappings, mutation failures, and read-only behavior.
- Adapter-factory tests will verify kind selection, provider-owned validation,
  default credential references, custom credential references, and secret
  reporting without placing credential values in assertions or diagnostics.
- One orchestrator integration test will use provider-neutral issue fixtures to
  confirm that non-dispatchable adapter output never starts a worker. Provider
  request details will remain in adapter tests.
- Default verification will use local fixture responses and temporary files. It
  will require neither network access nor live tracker credentials.
- Optional smoke profiles will validate one isolated Linear team and one isolated
  GitHub repository issue using operator-supplied credentials. Smoke profiles
  must be explicit, bounded, and safe to skip.
- Documentation examples will be checked for mutually exclusive Linear scopes,
  valid repository syntax, non-conflicting GitHub labels, and the absence of
  literal credentials.

## Out of Scope

- GitHub Projects, project fields, project boards, organization-wide issue
  search, and multi-repository queues.
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
  and repositories, so these adapters extend the integration surface without
  changing the orchestration model.
- Team scope is the smallest compatible correction for Linear workspaces that do
  not use Projects. It should be delivered before GitHub support because it is a
  contained extension of the existing query and validation paths.
- GitHub status labels are a deliberate workflow contract, not a best-effort
  inference. Requiring explicit, unambiguous labels prevents Symphony from
  treating every open repository issue as agent-ready work.
- Leaving successful and blocked GitHub issues open separates Symphony's dispatch
  terminal state from the team's human review and closure policy.
- The project remains local. This PRD does not authorize creating remote issues,
  repositories, pull requests, or releases.
