# Symphony In Review UI Column Design

## Goal

Add an `In Review` column to the status dashboard in this exact order:

1. Running
2. Retrying
3. Blocked
4. In Review
5. Done

## Classification

This is a presentation-only classification. The status API and orchestrator
continue to report every active agent under `running`.

When the dashboard renders a running entry:

- tracker state `In Review`, normalized case-insensitively, renders in the
  `In Review` column;
- every other tracker state renders in `Running`.

The two dashboard collections are disjoint, so a ticket is never duplicated.
An In Review card retains its `Running` badge because the agent is still active.
Retrying and blocked tickets remain in their operational columns even when
their tracker state is In Review, so attention states are never hidden.

## Dashboard

The In Review column reuses the running ticket facts: state, attempt, turns,
tokens, and last event. It has a distinct color token and always renders an
empty state when no active In Review ticket exists.

Desktop and mobile grids contain five horizontally scrollable columns. The
existing live-region replacement updates the new column without a manual page
reload.

## Non-goals

- No changes to `tracker.active_states`.
- No scheduler or dispatch changes.
- No status API schema or count changes.
- No tracker mutations or drag-and-drop.

## Verification

Tests prove normalized state partitioning, disjoint cards, exact semantic
column order, five empty states, and five-column responsive CSS. The full V
suite, formatter, JavaScript syntax check, optimized build, and live browser
layout must pass.
