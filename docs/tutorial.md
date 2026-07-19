# Symphony V: First-Run Tutorial

This tutorial takes you from a fresh checkout to a supervised Codex run using
the local Markdown queue in `tickets/`. Symphony does not need Linear for this
mode and does not create a GitHub repository, remote, pull request, or release.

## 1. Understand `SYMPHONY_REPOSITORY_URL`

`SYMPHONY_REPOSITORY_URL` is the **Git clone URL of the code repository that
Codex should modify while working on the local tickets**. Use the clone URL for
the application repository that those tickets describe and that your machine
can access.

Examples:

```dotenv
# SSH; usually convenient for a private repository with a working SSH key.
SYMPHONY_REPOSITORY_URL=git@github.com:your-org/your-repository.git

# HTTPS; useful for a public repository or configured Git credential helper.
SYMPHONY_REPOSITORY_URL=https://github.com/your-org/your-repository.git
```

Do not use a Linear URL, issue URL, pull-request URL, directory path, API key,
or only `owner/repository`. On GitHub, open the repository, choose **Code**, and
copy its SSH or HTTPS clone URL. Do not embed a token in the URL.

If the target repository is already cloned and has an `origin`, get the exact
value with:

```sh
git -C /absolute/path/to/your-repository remote get-url origin
```

Verify access before starting Symphony:

```sh
git ls-remote 'git@github.com:your-org/your-repository.git' HEAD
```

Why this is needed: the example `after_create` hook creates one isolated
workspace per ticket and runs `git clone "$SYMPHONY_REPOSITORY_URL" .` there.
Retries reuse that checkout.

## 2. Install and build

You need:

- V 0.5.2 at commit `f915d3e`;
- Git with access to the target repository;
- the `codex` CLI, already authenticated.

Check the tools and build Symphony from this project directory:

```sh
v version
git --version
codex --version
codex login status
v -prod -o build/symphony bin/symphony
build/symphony version
```

## 3. Configure `.env`

Create the optional environment file and protect it:

```sh
cp .env.example .env
chmod 600 .env
```

Edit `.env` and set the actual repository clone URL:

```dotenv
SYMPHONY_REPOSITORY_URL=git@github.com:your-org/your-repository.git
```

No `LINEAR_API_KEY` is required. Symphony reads `.env` as data; it does not run
it as a shell script. Existing process environment variables take precedence,
including an explicitly exported empty value. Use `--env /path/to/file` to load
a different file.

## 4. Understand the local queue

The checked-in `WORKFLOW.md` uses:

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

The root is resolved relative to `WORKFLOW.md`. Every local ticket file has YAML
metadata and the full task description; imported comments can appear at the
bottom of the relevant descriptions.

The important local lifecycle field is:

```yaml
dispatch_status: pending
```

Only `pending` tickets are candidates. Symphony atomically changes a successful
ticket to `completed`, and a ticket needing operator input to `blocked`. Failed
attempts stay pending and use the configured retry backoff. See
[the file tracker reference](tracker-file.md) for the complete schema.

## 5. Validate without starting tickets

These commands do not dispatch any Codex workers:

```sh
build/symphony validate WORKFLOW.md
build/symphony doctor WORKFLOW.md
```

`doctor` checks the workflow, ticket directory, workspace root, Bash, Codex
executable, and selected file adapter. Its tracker line should be:

```text
ok: tracker: file adapter is configured
```

If you only want to inspect the imported queue, stop here and open the Markdown
files under `tickets/`.

## 6. Start work

`run` is real execution, not a dry run. With the checked-in
`max_concurrent_agents: 2`, it may immediately clone two workspaces and start two
Codex sessions. Change the value to `1` in `WORKFLOW.md` first if you want a
slower first run.

Perform one poll/dispatch cycle and wait for the launched attempts:

```sh
build/symphony run WORKFLOW.md --once
```

Run continuously with the checked-in dashboard configuration:

```sh
build/symphony run WORKFLOW.md --web-host 127.0.0.1 --web-port 8000
```

Open `http://127.0.0.1:8000/`. The dashboard shows live running, retrying, and
blocked Symphony runtime state. It intentionally does not list all pending files
before they are claimed. The complete backlog remains visible in `tickets/`.

The JSON endpoints are:

- `GET /healthz`
- `GET /api/v1/state`
- `GET /api/v1/<issue-identifier>`, for example `/api/v1/SYM-400`
- `POST /api/v1/refresh`

Press `Ctrl-C` to stop. Symphony stops new dispatch, cancels active Codex process
groups, runs best-effort cleanup hooks, and shuts down the dashboard.

## 7. Requeue a completed or blocked ticket

Open its file in `tickets/` and restore these fields:

```yaml
dispatch_status: pending
last_error: ""
completed_at: ""
```

Then restart Symphony or call `POST /api/v1/refresh`. Changing a ticket's
original `state` is optional; it only needs to be one of the active states.

## Troubleshooting

`unsupported_tracker_kind: file is not supported`

: The executable predates the file adapter. Rebuild it with
  `v -prod -o build/symphony bin/symphony`, then rerun `doctor`.

`file_tracker_directory_error`

: `tracker.provider.root` is missing, unreadable, or not a directory. With the
  example configuration it must resolve to this project's `tickets/` folder.

`file_tracker_parse_error`, `file_tracker_schema_error`, or
`file_tracker_status_error`

: One ticket has invalid frontmatter. The error names the file without printing
  its body. Compare it with the example in `docs/tracker-file.md`.

`SYMPHONY_REPOSITORY_URL must be a Git clone URL`

: `.env` is absent, loaded from the wrong directory, or contains an incomplete
  value. Pass `--env /path/to/file` if needed and test the literal URL with
  `git ls-remote`.

`Permission denied (publickey)`

: The SSH clone URL is valid, but this host account cannot authenticate. Run
  `ssh -T git@github.com`, load the correct key, or use HTTPS with a configured
  credential helper.

`Repository not found`

: Check the owner, repository name, access, and organization SSO. Copy the URL
  again from the repository's **Code** menu.

No ticket starts

: Confirm at least one direct `tickets/*.md` file has `dispatch_status: pending`,
  an active `state`, all required labels, and no open blocker when in `Todo`.
  Also check concurrency slots and `last_error`, then refresh or restart.

The dashboard shows zero even though pending files exist

: The dashboard is an operational view, not a backlog browser. It shows tickets
  after Symphony claims them. Use the Markdown directory to inspect all pending
  work and the logs to diagnose a failed poll or workspace hook.
