# Symphony Dotenv Loading Design

Date: 2026-07-19

## Goal

Let operators place host-side configuration such as `LINEAR_API_KEY` and
`SYMPHONY_REPOSITORY_URL` in a local `.env` file instead of exporting each
value manually before starting Symphony.

## CLI behavior

The `run`, `doctor`, and `validate` commands automatically look for `.env` in
the process's current working directory. If that default file does not exist,
the command continues unchanged.

`--env PATH` selects a different file. The path is resolved from the current
working directory. An explicitly selected file must exist and be readable;
otherwise Symphony returns a categorized `dotenv_file_error`. `--env` without
a following non-empty path is a CLI argument error.

`help` and `version` accept normal parsing but do not load an environment file.
There is no `--no-env` flag in this initial implementation.

## Precedence and mutation

Existing process environment variables always win, including variables that
were explicitly exported with an empty value. Symphony distinguishes unset
variables with `os.getenv_opt` and only fills names that are absent.

The complete dotenv file is parsed and validated before any process environment
mutation occurs. Within the file, the last assignment to a duplicated name
wins. A malformed file therefore changes no environment variables.

Loaded values become ordinary host process variables. Existing Symphony
boundaries continue to apply: lifecycle hooks can read
`SYMPHONY_REPOSITORY_URL`, while tracker secret names such as `LINEAR_API_KEY`
are still removed from Codex child-process environments.

## Supported syntax

The internal parser supports a deliberately small, common dotenv grammar:

- blank lines and lines whose first non-whitespace character is `#`;
- optional `export` followed by whitespace;
- names matching `[A-Za-z_][A-Za-z0-9_]*`;
- `NAME=VALUE` with surrounding whitespace around the name and separator;
- unquoted values, trimming outer whitespace;
- single-quoted literal values;
- double-quoted values with `\\`, `\"`, `\n`, `\r`, and `\t` escapes;
- inline comments outside quotes when `#` is preceded by whitespace;
- empty values such as `NAME=` and `NAME=""`.

Unknown double-quoted escape sequences preserve the backslash and following
character. Quoted values may only be followed by whitespace or a comment.
Multiline quoted values, shell evaluation, command substitution, and variable
expansion are not supported.

Keys, line numbers, and categorized parse errors may be reported, but values
must never appear in errors or logs. The parser rejects files larger than 1 MiB
and logical lines larger than 64 KiB.

## Architecture

A new `symphony/dotenv` module owns parsing and application:

- `parse(source string) !map[string]string` validates text without mutation.
- `load(path string, required bool) !LoadResult` reads, parses, then fills only
  environment variables that are currently absent.
- `LoadResult` reports the normalized path and number of variables applied,
  without carrying secret values.

`symphony/app/cli.v` adds `env_path` and `env_explicit` to `Options` and parses
`--env PATH`. `symphony/app/app.v` calls the dotenv loader immediately after
argument parsing and before any workflow load for `run`, `doctor`, or
`validate`.

The project keeps `v.mod` dependency-free and never invokes a shell to parse
the file.

## Documentation

Add `.env.example` containing empty or obviously placeholder values for
`LINEAR_API_KEY` and `SYMPHONY_REPOSITORY_URL`. Do not add an actual `.env`
containing credentials. Update the README and tutorial to use:

```sh
cp .env.example .env
# edit .env
build/symphony doctor WORKFLOW.md
build/symphony run WORKFLOW.md
```

Document `--env /path/to/file`, current-directory resolution, shell precedence,
and the warning that `.env` contains secrets and must not be published.

## Verification

Tests cover parsing, comments and quotes, duplicate keys, invalid names,
unterminated quotes, file and line limits, atomic failure, default missing-file
behavior, explicit missing-file errors, shell precedence including empty
variables, CLI parsing, and startup ordering before tracker validation.

Final verification runs formatting, focused dotenv/app tests, the complete V
test suite, vet, a production build, version output, and example-workflow
validation.

## Non-goals

- No variable interpolation or shell execution.
- No recursive or multiple env-file loading.
- No automatic search in parent directories or beside `WORKFLOW.md`.
- No encrypted secret store.
- No changes to tracker, hook, or Codex secret policy.
