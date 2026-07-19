---
tracker:
  kind: file
  provider:
    root: ./tickets
  required_labels: []
  active_states:
    - Todo
    - In Review
    - In Progress
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 30000
workspace:
  root: ./symphony_workspaces
hooks:
  after_create: |
    if [ -z "$SYMPHONY_REPOSITORY_URL" ]; then
      echo "SYMPHONY_REPOSITORY_URL must be a Git clone URL" >&2
      exit 1
    fi
    git clone -- "$SYMPHONY_REPOSITORY_URL" .
  before_run: |
    git status --short
  timeout_ms: 60000
agent:
  max_concurrent_agents: 2
  max_turns: 20
  max_retry_backoff_ms: 300000
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy: workspaceWrite
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
server:
  port: 8080
---
You are working on {{ issue.identifier }}: {{ issue.title }}.

Issue description:
{{ issue.description | default: "No description was supplied." }}

Current state: {{ issue.state }}
Attempt: {{ attempt | default: 0 }}

{{#if issue.labels}}
Labels:
{{#each issue.labels}}
- {{ this }}
{{/each}}
{{/if}}

Work only inside the current workspace. Follow the repository instructions,
run the relevant checks, and clearly report the final verification result.
Symphony updates the local ticket's dispatch status after the attempt ends.
