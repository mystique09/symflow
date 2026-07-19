# Symphony Dashboard Paper Ops Design

Date: 2026-07-19

## Goal

Replace the status dashboard's minimal presentation with a polished, responsive
Paper Ops visual system. The dashboard remains a server-rendered page produced
by V and `veb`, with Bulma vendored locally as its CSS foundation.

## Scope

The change is limited to the human dashboard returned by `GET /`. Existing
JSON routes, refresh behavior, orchestration state, and runtime semantics remain
unchanged. The page does not make runtime requests for external fonts,
stylesheets, images, scripts, or frameworks.

## Visual direction

Paper Ops uses a warm cream canvas, deep navy typography, quiet borders, and
restrained shadows. Running, retrying, and blocked states receive distinct
green, amber, and red accents without turning the interface into a high-saturation
monitoring wall.

The page contains:

1. A compact Symphony brand header with a service-live indicator.
2. An overview heading and operational metadata for generation time, runtime,
   tokens, and rate-limit usage.
3. Three summary cards for running, retrying, and blocked counts.
4. One section card per queue, each with a heading, count, responsive table,
   status badges, and a useful empty state.
5. A quiet footer identifying the local engineering-preview dashboard.

## Architecture

`symphony/statusweb/app.v` builds a presentation-only view model and returns the
compile-time `veb` template at `symphony/statusweb/templates/index.html`. All
issue-supplied strings are HTML-escaped before interpolation, and issue links
are restricted to absolute HTTP(S) URLs.

The page uses Bulma 1.0.4 from the vendored `assets/bulma.min.css`, followed by
the local Paper Ops overrides in `assets/symphony.css`. Both stylesheets are
embedded at compile time and served by dedicated `veb` routes, so the dashboard
does not depend on CDN availability or asset paths from the build machine. CSS
custom properties define the visual tokens, while Bulma provides the responsive
columns, boxes, tags, and table primitives.

## Data presentation

The dashboard renders only fields already present in `RuntimeSnapshot`:

- Running rows show issue, state, attempt, turn count, last event, and tokens.
- Retrying rows show issue, attempt, due time, and the bounded last error.
- Blocked rows show issue, state, attempt, and the bounded reason.

When an issue URL is present, its identifier becomes a safe external link.
Otherwise, the identifier remains plain text. Empty collections render a clear
human message rather than an empty table body.

## Accessibility and resilience

- Native headings, tables, links, and `<time>` elements preserve semantic
  structure.
- Text and status colors maintain readable contrast on the cream surface.
- Keyboard focus rings are visible.
- Long messages wrap without widening the page.
- The page remains useful without JavaScript and at mobile widths.
- All dynamic text remains escaped, preserving the existing XSS boundary.

## Verification

Tests cover the visual shell markers, escaped dynamic content, issue-link
rendering, empty states, and the existing HTTP dashboard route. Final
verification runs V formatting, the focused status-web tests, the complete V
test suite, vet, and a production build.

## Non-goals

- No changes to the JSON API or refresh endpoint.
- No auto-refresh or client-side state management.
- No theme switcher or dark theme.
- No external asset pipeline or runtime CDN dependency.
- No tracker, scheduler, or orchestrator changes.
