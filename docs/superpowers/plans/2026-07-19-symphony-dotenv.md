# Symphony Dotenv Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load optional host configuration from `.env`, with `--env PATH` support and existing process variables taking precedence.

**Architecture:** Add a dependency-free `symphony/dotenv` module that parses an entire bounded file before applying values. Extend CLI options with the selected path and explicitness bit, then load the environment before workflow/configuration reads for `run`, `doctor`, and `validate`.

**Tech Stack:** V 0.5.2, V standard library `os`, native V tests, existing Symphony CLI.

## Global Constraints

- Existing process variables win, including explicitly empty values.
- A missing default cwd `.env` is ignored; a missing explicit `--env PATH` is an error.
- Last duplicate assignment in the file wins.
- Execute no shell, variable expansion, or command substitution.
- Never include parsed values in errors or logs.
- Reject files over 1 MiB and logical lines over 64 KiB.
- Keep `v.mod` dependency-free and do not initialize Git.

---

### Task 1: Build the atomic dotenv parser and loader

**Files:**
- Create: `symphony/dotenv/dotenv.v`
- Create: `symphony/dotenv/dotenv_test.v`

**Interfaces:**
- Produces: `pub fn parse(source string) !map[string]string`
- Produces: `pub fn load(path string, required bool) !LoadResult`
- Produces: `pub struct LoadResult { path string, found bool, applied int }`

- [x] **Step 1: Write failing parser tests**

```v
fn test_parse_supports_comments_exports_quotes_and_last_duplicate() {
	values := parse('# host config\nexport LINEAR_API_KEY="line\\nkey"\nREPO=git@github.com:acme/repo.git # clone\nLITERAL=\'a # b\'\nREPO=https://github.com/acme/repo.git')!
	assert values['LINEAR_API_KEY'] == 'line\nkey'
	assert values['REPO'] == 'https://github.com/acme/repo.git'
	assert values['LITERAL'] == 'a # b'
}

fn test_parse_rejects_invalid_names_quotes_and_limits_without_values_in_errors() {
	parse('BAD-NAME=secret-value') or {
		assert err.msg().contains('dotenv_parse_error: line 1')
		assert !err.msg().contains('secret-value')
		return
	}
	assert false
}
```

- [x] **Step 2: Write failing loader tests**

```v
fn test_load_preserves_existing_environment_including_empty_values() {
	dir := test_dir()
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, '.env')
	os.write_file(path, 'SYMPHONY_DOTENV_KEEP=file\nSYMPHONY_DOTENV_EMPTY=file\nSYMPHONY_DOTENV_NEW=loaded')!
	os.setenv('SYMPHONY_DOTENV_KEEP', 'shell', true)
	os.setenv('SYMPHONY_DOTENV_EMPTY', '', true)
	os.unsetenv('SYMPHONY_DOTENV_NEW')
	defer {
		os.unsetenv('SYMPHONY_DOTENV_KEEP')
		os.unsetenv('SYMPHONY_DOTENV_EMPTY')
		os.unsetenv('SYMPHONY_DOTENV_NEW')
	}
	result := load(path, true)!
	assert os.getenv('SYMPHONY_DOTENV_KEEP') == 'shell'
	assert os.getenv_opt('SYMPHONY_DOTENV_EMPTY')? == ''
	assert os.getenv('SYMPHONY_DOTENV_NEW') == 'loaded'
	assert result.applied == 1
}

fn test_load_missing_default_is_optional_but_explicit_path_is_required() {
	assert !load(missing_path, false)!.found
	load(missing_path, true) or {
		assert err.msg().contains('dotenv_file_error')
		return
	}
	assert false
}
```

- [x] **Step 3: Run the focused test to confirm RED**

Run: `/Users/benj/.local/bin/v/v test symphony/dotenv`

Expected: FAIL because the module and interfaces do not exist.

- [x] **Step 4: Implement bounded parse-then-apply behavior**

```v
module dotenv

import os

const max_file_bytes = 1024 * 1024
const max_line_bytes = 64 * 1024

pub struct LoadResult {
pub:
	path    string
	found   bool
	applied int
}

pub fn parse(source string) !map[string]string
pub fn load(path string, required bool) !LoadResult
```

`parse` validates key names, optional `export`, quoted/unquoted values,
comments, escapes, file size, and line size. It returns categorized line-number
errors without values. `load` uses `os.abs_path`, parses before mutation, and
calls `os.setenv(name, value, false)` only when `os.getenv_opt(name)` is `none`.

- [x] **Step 5: Format and make the focused module green**

Run:

```sh
/Users/benj/.local/bin/v/v fmt -w symphony/dotenv
/Users/benj/.local/bin/v/v test symphony/dotenv
```

Expected: all dotenv tests pass.

---

### Task 2: Integrate dotenv loading into the CLI startup boundary

**Files:**
- Modify: `symphony/app/cli.v`
- Modify: `symphony/app/app.v`
- Modify: `symphony/app/app_test.v`

**Interfaces:**
- Consumes: `dotenv.load(path string, required bool) !dotenv.LoadResult`
- Produces: `Options.env_path string = '.env'`
- Produces: `Options.env_explicit bool`

- [x] **Step 1: Write failing CLI parsing and startup-order tests**

```v
fn test_parse_defaults_env_file_and_accepts_override() {
	defaults := parse_args([]string{})!
	assert defaults.env_path == '.env'
	assert !defaults.env_explicit
	override := parse_args(['doctor', 'WORKFLOW.md', '--env', 'ops/dev.env'])!
	assert override.env_path == 'ops/dev.env'
	assert override.env_explicit
}

fn test_load_command_environment_runs_before_tracker_configuration() {
	dir := os.join_path(os.temp_dir(), 'symphony-app-env-${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'test.env')
	os.write_file(path, 'SYMPHONY_APP_DOTENV_KEY=loaded')!
	os.unsetenv('SYMPHONY_APP_DOTENV_KEY')
	defer { os.unsetenv('SYMPHONY_APP_DOTENV_KEY') }
	load_command_environment(Options{
		command: .validate
		env_path: path
		env_explicit: true
	})!
	assert os.getenv('SYMPHONY_APP_DOTENV_KEY') == 'loaded'
}
```

- [x] **Step 2: Run app tests to confirm RED**

Run: `/Users/benj/.local/bin/v/v test symphony/app`

Expected: FAIL because `Options` has no dotenv fields and startup does not load a file.

- [x] **Step 3: Add `--env PATH` and load before workflow reads**

```v
pub struct Options {
pub:
	env_path     string = '.env'
	env_explicit bool
	// existing fields remain unchanged
}

fn load_command_environment(options Options) ! {
	if options.command in [.run, .doctor, .validate] {
		dotenv.load(options.env_path, options.env_explicit)!
	}
}
```

Call `load_command_environment(options)!` immediately after `parse_args` and
before the command match. Parse `--env` as a required non-empty following path
and include it in `usage()`.

- [x] **Step 4: Format and make focused app tests green**

Run:

```sh
/Users/benj/.local/bin/v/v fmt -w symphony/app
/Users/benj/.local/bin/v/v test symphony/app
```

Expected: all app tests pass.

---

### Task 3: Add safe operator examples and complete verification

**Files:**
- Create: `.env.example`
- Modify: `README.md`
- Modify: `docs/tutorial.md`
- Verify: `v.mod`

**Interfaces:**
- Consumes: the completed default `.env` and `--env PATH` behavior
- Produces: copy-edit-run instructions without real secrets

- [x] **Step 1: Add the placeholder env file and documentation**

```dotenv
LINEAR_API_KEY=replace_me
SYMPHONY_REPOSITORY_URL=git@github.com:your-org/your-repository.git
```

README and tutorial instructions use `cp .env.example .env`, explain cwd
resolution and shell precedence, show `--env /path/to/file`, and warn against
publishing `.env`.

- [x] **Step 2: Run complete regression and static checks**

Run:

```sh
/Users/benj/.local/bin/v/v fmt -verify bin symphony
/Users/benj/.local/bin/v/v test symphony
/Users/benj/.local/bin/v/v vet bin symphony
```

Expected: all test files pass; vet exits zero with only existing public-function
documentation warnings allowed.

- [x] **Step 3: Build and smoke-test the production CLI**

Run:

```sh
/Users/benj/.local/bin/v/v -prod -o build/symphony bin/symphony
build/symphony version
build/symphony validate WORKFLOW.example.md
```

Expected: version prints `symphony 0.1.0-dev` and the workflow validates.
