---
tracker:
  kind: linear
  project_slug: "fee6284555ff"
  api_key: $LINEAR_API_KEY
  active_states:
    - Todo
    - "In Progress"
    - Merging
    - Rework
  terminal_states:
    - Done
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
workspace:
  root: /tmp/symphony-test-workspaces
agent:
  transport: claude
  max_concurrent_agents: 1
  max_turns: 3
claude:
  command: claude
  model: sonnet
  turn_timeout_ms: 600000
hooks:
  after_create: |
    echo "Workspace created: $(pwd)"
    ls -la
  timeout_ms: 30000
---

You are working on a Linear ticket {{ issue.identifier }}.

Issue context:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Current status: {{ issue.state }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
(no description)
{% endif %}

Instructions:
1. Read the issue carefully.
2. Use the Bash tool to do the work in this workspace.
3. When done, use `bin/symphony-claude-tools/linear-update-issue --id <issue-id> --state "Done"` to mark it Done.
4. Post a brief comment with `bin/symphony-claude-tools/linear-add-comment --id <issue-id> --body "..."` summarizing what you did.

Available helpers (run from the workspace root):
- `bin/symphony-claude-tools/linear-graphql --query "..." [--vars '{...}']`
- `bin/symphony-claude-tools/linear-update-issue --id <uuid> --state "Done"`
- `bin/symphony-claude-tools/linear-add-comment --id <uuid> --body "..."`

The workspace is the current directory. The repo is already cloned there (or this is a fresh dir if no hook was needed).
