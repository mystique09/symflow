# Symphony Durable Done Queue Design

## Goal

Add a fourth `Done` column to the orchestration board so successfully completed
tickets remain visible after a process restart. Keep `Blocked` reserved for
attempts that genuinely require operator action.

## Tracker Semantics

The tracker port exposes completed issues separately from dispatch candidates:

- File tracker: tickets whose `dispatch_status` is `completed`.
- GitHub Project and Linear: tickets in the workflow's configured terminal
  states.

Completed issues are display-only. They are never claimed or dispatched.
The orchestrator refreshes the completed snapshot during each tracker poll and
replaces its previous snapshot atomically. Responses remain bounded by the
existing status API limit.

Existing file tickets marked `blocked` are not silently reclassified. Their
persisted status remains authoritative until an operator resets or completes
them.

## Runtime and Status API

`RuntimeSnapshot` gains a sorted `completed` collection containing the issue
identity, URL, tracker state, and completion timestamp when the tracker exposes
one. The status API gains:

- `counts.completed`
- `completed`
- completed-ticket lookup through the existing issue endpoints

The runtime keeps completed issues separate from its claim bookkeeping, so
completed history cannot consume an agent slot or prevent a legitimate requeue.

## Dashboard

The board always renders four columns in this order:

1. Running
2. Retrying
3. Blocked
4. Done

The Done column uses the same compact ticket-card layout and horizontal board
scrolling as the other queues. It remains visible with a zero count when no
ticket has completed.

## End-of-task Handoff Policy

The worker prompt instructs Codex to leave the issue branch as-is after verified
work and finish without asking how to merge, push, or clean up the branch.
Symphony still treats genuine approval and user-input requests as blocked; it
does not guess that every elicitation represents completed work.

## Verification

Tests cover:

- file-backed completed-ticket loading;
- terminal-state completion loading for read-only trackers;
- completed runtime snapshot replacement and sorting;
- API counts, lookup, and response bounding;
- the fourth semantic board column and empty state;
- the worker prompt's branch-handoff policy;
- automatic browser refresh preserving all four columns.

Formatting, vetting, the complete V test suite, the production build, and a
live browser check must pass before handoff.
