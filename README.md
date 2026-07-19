# Symphony for V

This project is a V engineering-preview implementation of OpenAI's
language-agnostic [Symphony service specification](https://github.com/openai/symphony/blob/main/SPEC.md).
It polls eligible Markdown tickets from a local directory, prepares one isolated
workspace per ticket, and supervises Codex app-server processes with bounded
concurrency. Optional Linear and GitHub Projects adapters are available, but the
checked-in workflow and ticket queue require no tracker account, API key, or
network access.

The Rust design is intentionally documentation-only. The executable here uses V
threads created with `spawn`, typed channels, `select`, and an optional `veb`
status surface. It does not use DBOS, a scheduler database, Photon, or V's
Photon-backed `coroutines` module.

The product requirements and implementation record are in:

- `docs/prds/v-symphony-prd.md`
- `docs/prds/rust-symphony-prd.md`
- `docs/prds/tracker-expansion-prd.md`
- `docs/superpowers/plans/2026-07-18-v-symphony-implementation.md`
- `docs/symphony-conformance.md`
- `docs/tracker-file.md` — local ticket format, lifecycle, and recovery
- `docs/tracker-linear.md` — optional Linear adapter contract
- `docs/tracker-github.md` — Project-scoped GitHub Issue adapter contract
- `docs/tutorial.md` — beginner setup, including the exact meaning of
  `SYMPHONY_REPOSITORY_URL`

## Toolchain

The supported compiler is V 0.5.2 at commit `f915d3e`. `.vvmrc` selects the
matching release when a versioned V compiler is installed. Compiler upgrades
must run the complete conformance suite.

```sh
v version
v fmt -verify bin symphony
v vet bin symphony
v test symphony
v -o build/symphony bin/symphony
```

## Layout

```text
bin/symphony/         executable composition root
symphony/domain/      provider-neutral runtime values
symphony/workflow/    WORKFLOW.md parsing and typed config
symphony/prompt/      strict runtime prompt renderer
symphony/scheduler/   pure dispatch and reconciliation policy
symphony/workspace/   path safety and lifecycle hooks
symphony/tracker/     tracker seam plus file, Linear, and GitHub adapters
symphony/codex/       app-server JSONL protocol and process supervision
symphony/orchestrator single-authority runtime state
symphony/statusweb/   optional loopback veb status surface
symphony/app/         CLI and dependency composition
```

## Build and verify

Use V 0.5.2 (`f915d3e`), selected by `.vvmrc` when VVM is available:

```sh
v fmt -verify bin symphony
v vet bin symphony
v test symphony
v -prod -o build/symphony bin/symphony
```

## Configure

Copy the environment example if `WORKFLOW.md` and `.env` do not already exist:

```sh
cp .env.example .env
# Edit .env with the Git clone URL of the repository Codex should modify.
```

For `run`, `doctor`, and `validate`, Symphony automatically loads an optional
`.env` from the current directory. Use `--env /path/to/file` to select another
file. An explicitly exported process variable always wins over the file,
including an exported empty value. Never publish `.env`; it can contain
host-side credentials. The included `.gitignore` excludes `.env` variants while
retaining `.env.example` as the safe template.

The default file tracker reads direct `*.md` children of `tickets/`, relative to
`WORKFLOW.md`. Each ticket has YAML frontmatter and a Markdown description.
Only `dispatch_status: pending` tickets in an active state are candidates.
Successful attempts are changed atomically to `completed`; blocked attempts are
changed to `blocked`. See [the file tracker guide](docs/tracker-file.md).

`workspace.root` is also resolved relative to `WORKFLOW.md`; when omitted, the
default is `<system-temp>/symphony_workspaces`. Linear and GitHub adapters can
reference host environment variables from `tracker.provider.api_key` and
`tracker.provider.token`; those variables are removed from child processes.

Workflow hooks are trusted host shell programs. In particular, the example's
`after_create` hook is where a repository is cloned into a new issue workspace.
See the [first-run tutorial](docs/tutorial.md) before choosing the repository URL.

## Operate

```sh
# Parse configuration and exercise the runtime prompt without starting work.
build/symphony validate WORKFLOW.md

# Check the workflow, workspace root, shell, Codex executable, and token presence.
build/symphony doctor WORKFLOW.md

# Perform one poll/dispatch cycle and wait for the launched attempts.
build/symphony run WORKFLOW.md --once

# Run continuously with the optional loopback status server.
build/symphony run WORKFLOW.md --port 8080

# Or select a different environment file.
build/symphony run WORKFLOW.md --env ./ops/production.env
```

The web surface provides a small dashboard at `/`, plus `GET /healthz`, `GET /api/v1/state`,
`GET /api/v1/<issue-identifier>`, and `POST /api/v1/refresh`. Refresh causes an immediate
poll and releases operator-blocked claims. The default bind address is
`127.0.0.1`; a non-loopback `--web-host` is explicit and logs a warning.

`SIGINT` and `SIGTERM` stop dispatch, cancel active Codex process groups, wait
for bounded worker cleanup, and stop the optional web server.

The dashboard reports Symphony's live running, retrying, and blocked runtime
state; it is not a browser for every file in `tickets/`. Inspect the Markdown
files directly for the complete local backlog. A local queue can contain
provider-exported tickets across any configured active states.

## Trust posture

This is a trusted-host engineering preview, not a multi-tenant sandbox. Workflow
hooks and Codex can execute host commands. The implementation constrains issue
work to validated workspace paths, separates tracker credentials from child
processes, bounds protocol and hook output, and terminates process groups, but
operators remain responsible for the host account and workflow they configure.

Runtime claims, retries, and metrics are in memory. The file tracker makes final
ticket disposition durable in the Markdown frontmatter, and preserved issue
workspaces are reused after a restart. Current deviations and follow-up work are
recorded precisely in `docs/symphony-conformance.md`.

No GitHub repository, remote, pull request, or release is created by this
project.
