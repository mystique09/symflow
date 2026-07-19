# Symphony Local File Tracker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `tracker.kind: file` run from a local Markdown ticket directory,
persist outcomes, and support an operator-selected provider export.

**Architecture:** Add a dependency-free `FileClient` behind the existing tracker
interface. It strictly parses one Markdown/YAML-frontmatter file per ticket,
filters pending tickets for dispatch, and atomically updates dispatch-owned
fields after outcomes while preserving ticket content. A one-time provider
export creates the local queue; Symphony runtime performs no provider calls in
file mode.

**Tech Stack:** V 0.5.2, V standard-library filesystem/time support, existing `yaml` module, existing tracker/orchestrator seams, native V tests.

## Global Constraints

- `tickets/<IDENTIFIER>.md` is the local source of truth.
- Preserve original Linear state separately from `dispatch_status`.
- `dispatch_status` accepts exactly `pending`, `completed`, or `blocked`.
- Successful local attempts persist completion and do not schedule continuation.
- Failed attempts remain pending and retain existing retry semantics.
- File mode performs no network calls and exposes no tracker secrets.
- Reject malformed snapshots and duplicate IDs/identifiers without silently dropping tickets.
- Bound each ticket to 1 MiB and the directory to 10,000 direct Markdown files.
- Do not read, overwrite, or expose the user's `.env` contents.
- Do not initialize Git, create commits, create a GitHub repository, or create a pull request.

---

### Task 1: Parse and query local Markdown tickets

**Files:**
- Create: `symphony/tracker/file.v`
- Create: `symphony/tracker/file_test.v`

**Interfaces:**
- Produces: `pub struct FileClient { root string }`
- Produces: `pub fn new_file_client(root string) !FileClient`
- Produces: `pub fn (client FileClient) fetch_issues_by_states(states []string) ![]domain.Issue`
- Produces: `pub fn (client FileClient) fetch_issues_by_ids(ids []string) ![]domain.Issue`

- [x] **Step 1: Write the failing public-seam tests**

Create temporary ticket directories and assert through `FileClient` only:

```v
fn test_file_client_reads_pending_markdown_and_filters_states() {
	dir := file_tracker_test_dir()
	defer { os.rmdir_all(dir) or {} }
	write_ticket(dir, 'SYM-400.md', 'SYM-400', 'Todo', 'pending', 'Full description')!
	write_ticket(dir, 'SYM-401.md', 'SYM-401', 'In Progress', 'completed', 'Done')!
	client := new_file_client(dir)!
	issues := client.fetch_issues_by_states(['Todo', 'In Progress'])!
	assert issues.map(it.identifier) == ['SYM-400']
	assert issues[0].description == 'Full description'
	assert issues[0].dispatchable
}

fn test_file_client_id_refresh_returns_non_pending_ticket_as_unroutable() {
	// A completed ticket remains observable for reconciliation but is not dispatchable.
}

fn test_file_client_rejects_duplicate_ids_and_malformed_frontmatter() {
	// Two otherwise valid files with the same id fail with file_tracker_duplicate.
	// Missing required fields fail with file_tracker_parse_error and name the file only.
}
```

- [x] **Step 2: Run the focused test and confirm RED**

Run: `/Users/benj/.local/bin/v/v test symphony/tracker`

Expected: FAIL because `FileClient` and `new_file_client` do not exist.

- [x] **Step 3: Implement strict snapshot parsing**

Use focused internal types:

```v
const max_ticket_bytes = 1_048_576
const max_ticket_files = 10_000

struct FileTicketMetadata {
	schema_version    int
	id                string
	identifier        string
	title             string
	state             string
	priority          int = -1
	labels            []string
	branch_name       string
	source_url        string
	assignee_id       string
	assignee_name     string
	parent_identifier string
	created_at        string
	updated_at        string
	dispatch_status   string
	last_error        string
	completed_at      string
	blocked_by        []FileBlocker
}

struct ParsedFileTicket {
	path         string
	front_matter string
	body         string
	metadata     FileTicketMetadata
}
```

`load_snapshot` must resolve the root, require a real directory, inspect only
direct `.md` children in sorted filename order, reject oversized files and
unsafe symlink targets, parse complete frontmatter before returning anything,
validate schema/status/required fields, and reject duplicate IDs or identifiers.

Map `source_url` to `domain.Issue.url`, body to `description`, normalized labels
to `labels`, and blocker metadata to `blocked_by`. Set `native_ref` to a JSON-safe
object containing `file_path`. Set `dispatchable` only for `pending` tickets.

- [x] **Step 4: Make focused reads green and format**

Run:

```sh
/Users/benj/.local/bin/v/v fmt -w symphony/tracker/file.v symphony/tracker/file_test.v
/Users/benj/.local/bin/v/v test symphony/tracker
```

Expected: all tracker test files pass.

---

### Task 2: Select file mode and resolve its root

**Files:**
- Modify: `symphony/workflow/config.v`
- Modify: `symphony/workflow/loader_test.v`
- Modify: `symphony/tracker/port.v`
- Modify: `symphony/tracker/linear.v`
- Modify: `symphony/tracker/linear_test.v`
- Modify: `symphony/tracker/file_test.v`

**Interfaces:**
- Consumes: `new_file_client(root string) !FileClient`
- Extends: `Tracker.record_outcome(issue domain.Issue, outcome domain.AttemptOutcome) !bool`
- Produces: absolute `tracker.provider.root` for file workflows

- [x] **Step 1: Write failing adapter and workflow-root tests**

```v
fn test_adapter_selects_file_without_tracker_secrets() {
	adapter := new_adapter(workflow.TrackerConfig{
		kind: 'file'
		provider: { 'root': yaml.Any(temp_root) }
	})!
	assert adapter.secret_environment_names() == []
	assert adapter.secret_values() == []
}

fn test_workflow_resolves_file_tracker_root_relative_to_workflow() {
	definition := load(workflow_path, .dispatch)!
	root := definition.config.tracker.provider['root'] or { panic('root') }
	assert root.str() == os.real_path(os.join_path(workflow_dir, 'tickets'))
}
```

- [x] **Step 2: Run focused tests and confirm RED**

Run: `/Users/benj/.local/bin/v/v test symphony/workflow symphony/tracker`

Expected: FAIL because file selection and provider-root normalization are absent.

- [x] **Step 3: Implement adapter selection and provider normalization**

In `normalize_config`, clone provider values and, only for `kind == 'file'`,
require a string `root`, expand `~`, and resolve relative roots against
`workflow_dir`. Keep provider-owned validation in `new_file_client`.

Extend `Tracker`:

```v
pub interface Tracker {
	fetch_issues_by_states(states []string) ![]domain.Issue
	fetch_issues_by_ids(ids []string) ![]domain.Issue
	record_outcome(issue domain.Issue, outcome domain.AttemptOutcome) !bool
	secret_environment_names() []string
	secret_values() []string
}
```

Select adapters with:

```v
return match config.kind.trim_space().to_lower() {
	'file' { Tracker(new_file_client(provider_string(config.provider, 'root')!)!) }
	'linear' { Tracker(linear_from_config(config)!) }
	else { return error('unsupported_tracker_kind: `${config.kind}` is not supported') }
}
```

Add a Linear no-op:

```v
pub fn (client LinearClient) record_outcome(_ domain.Issue, _ domain.AttemptOutcome) !bool {
	return false
}
```

File secret methods return empty arrays.

- [x] **Step 4: Make focused selection tests green**

Run:

```sh
/Users/benj/.local/bin/v/v fmt -w symphony/workflow symphony/tracker
/Users/benj/.local/bin/v/v test symphony/workflow symphony/tracker
```

Expected: all workflow and tracker tests pass.

---

### Task 3: Persist local outcomes atomically

**Files:**
- Modify: `symphony/tracker/file.v`
- Modify: `symphony/tracker/file_test.v`
- Modify: `symphony/orchestrator/service.v`
- Modify: `symphony/orchestrator/service_test.v`

**Interfaces:**
- Implements: `FileClient.record_outcome(issue domain.Issue, outcome domain.AttemptOutcome) !bool`
- Consumes: tracker outcome bool where `true` means successful completion was persisted and continuation must stop

- [x] **Step 1: Write failing outcome tests**

```v
fn test_file_outcome_completion_is_atomic_and_preserves_body() {
	client := new_file_client(dir)!
	completed := client.record_outcome(issue, domain.AttemptOutcome{
		kind: .succeeded
		issue_id: issue.id
	})!
	assert completed
	refreshed := client.fetch_issues_by_ids([issue.id])!
	assert !refreshed[0].dispatchable
	content := os.read_file(ticket_path)!
	assert content.contains('dispatch_status: completed')
	assert content.contains('Full description')
}

fn test_file_outcome_blocked_persists_reason_and_failure_remains_pending() {
	// blocked => dispatch_status blocked and false return
	// failed => dispatch_status pending, last_error updated, false return
}
```

Add an orchestrator seam test proving a tracker that returns `true` for a
successful outcome releases the claim rather than placing it in retrying.

- [x] **Step 2: Run focused tests and confirm RED**

Run: `/Users/benj/.local/bin/v/v test symphony/tracker symphony/orchestrator`

Expected: FAIL because file outcome persistence is not implemented and service
does not consume the outcome result.

- [x] **Step 3: Implement safe metadata-only writes**

Re-read and validate the current ticket by ID, then replace or append only the
top-level `dispatch_status`, `last_error`, and `completed_at` scalar lines.
Encode strings as JSON string literals, which are valid YAML scalars. Rebuild the
original frontmatter/body, write a sibling uniquely named temporary file with
mode `0600`, and rename it over the ticket. Remove the temp file on errors.

Return `true` only after a `.succeeded` update is durably renamed. Return `false`
for all other outcomes. Bound persisted error messages to 8 KiB.

- [x] **Step 4: Integrate outcome persistence with runtime state**

Before `runtime.finish`, construct the configured tracker and call
`record_outcome`. Log `tracker_outcome_persist_failed` if construction or write
fails. After `runtime.finish`, call `runtime.release(issue.id)` only when the
outcome is `.succeeded` and the adapter returned `true`. Linear continues its
existing continuation behavior because its no-op returns `false`.

- [x] **Step 5: Make outcome and orchestration tests green**

Run:

```sh
/Users/benj/.local/bin/v/v fmt -w symphony/tracker symphony/orchestrator
/Users/benj/.local/bin/v/v test symphony/tracker symphony/orchestrator
```

Expected: all focused tests pass.

---

### Task 4: Export the operator-selected queue and switch local defaults

**Files:**
- Create locally: `tickets/<IDENTIFIER>.md`
- Create: `docs/tracker-file.md`
- Modify: `WORKFLOW.example.md`
- Verify/preserve: `WORKFLOW.md`
- Modify: `.env.example`
- Modify: `README.md`
- Modify: `docs/tutorial.md`
- Modify: `docs/symphony-conformance.md`
- Verify locally: provider-exported ticket files

**Interfaces:**
- Consumes: the completed `FileClient`
- Produces: a provider-independent local workflow and a validated ticket directory

- [x] **Step 1: Fetch complete source records read-only**

Use the connected provider reader for the operator-selected identifiers. For
each, fetch the untruncated description, scheduling metadata, and comments. Do
not mutate the source provider.

- [x] **Step 2: Generate deterministic ticket files**

Write `tickets/<IDENTIFIER>.md` in identifier order. Quote unsafe YAML strings,
normalize labels to lowercase, render parent/blocker references, preserve the
full description, and append comments chronologically. Initialize every file
with `schema_version: 1` and `dispatch_status: pending`.

- [x] **Step 3: Validate the local export**

Load the complete local directory through `FileClient`, verify every imported
file parses, and confirm IDs and identifiers are unique. Keep provider-specific
ticket data ignored from the reusable source repository.

- [x] **Step 4: Switch examples and documentation to file mode**

Make `WORKFLOW.example.md` match the working `WORKFLOW.md` file configuration.
Remove `LINEAR_API_KEY` from `.env.example`; keep
`SYMPHONY_REPOSITORY_URL`. Document ticket editing/requeueing, automatic
completion, local error categories, and the fact that the dashboard shows
runtime operations rather than the entire pending backlog. Retain
`docs/tracker-linear.md` as an optional adapter profile.

- [x] **Step 5: Verify no runtime Linear requirement remains**

Run `env -u LINEAR_API_KEY ./build/symphony doctor WORKFLOW.md` after rebuilding.
Expected: doctor reports `tracker: file adapter is configured` and exits zero.

---

### Task 5: Complete regression, production build, and original repro

**Files:**
- Verify: all implementation, ticket, workflow, and documentation files
- Produce: `build/symphony`

**Interfaces:**
- Consumes: all prior tasks
- Produces: a runnable production binary

- [x] **Step 1: Run formatting and all tests**

```sh
/Users/benj/.local/bin/v/v fmt -verify bin symphony
/Users/benj/.local/bin/v/v test symphony
/Users/benj/.local/bin/v/v vet bin symphony
```

Expected: formatting and tests pass; vet exits zero with only previously known
missing-public-documentation warnings.

- [x] **Step 2: Build production binary**

Run: `/Users/benj/.local/bin/v/v -prod -o build/symphony bin/symphony`

Expected: exit zero.

- [x] **Step 3: Re-run the original failing command safely**

Use a temporary copy of the ticket directory with every ticket marked
`completed`, then run:

```sh
./build/symphony run TEMP_WORKFLOW.md --once
```

Expected: exit zero without `unsupported_tracker_kind`, without a Linear key,
and without launching a worker.

- [x] **Step 4: Smoke the real local configuration without dispatch**

Run:

```sh
./build/symphony validate WORKFLOW.md
./build/symphony doctor WORKFLOW.md
./build/symphony version
```

Expected: workflow and file tracker validate, and version prints
`symphony 0.1.0-dev`.

- [x] **Step 5: Confirm cleanup and constraints**

Search for debug tags, verify no temporary export files remain, confirm
`v.mod` still has `dependencies: []`, confirm `.env` remains mode `0600`, and
confirm `git rev-parse --is-inside-work-tree` still reports no Git repository.
