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
3. Symphony is read-only orchestration. All Linear writes (status transitions,
   comments) must go through `./scripts/bin/harness-cli` (the Harness CLI).
   Symphony itself does not write to Linear, and your Claude process does not
   receive the Linear API token. There is no soft-policy fallback: if you
   cannot go through Harness, you cannot write to Linear.
4. When done, use `./scripts/bin/harness-cli issue transition --issue {{ issue.identifier }} --state "Done"` to mark it Done.
5. Record a brief proof/completion through Harness.

Available read helpers (run from the workspace root):
- `bin/symphony-claude-tools/linear-graphql --query "..." [--vars '{...}']` — read-only GraphQL executor. Mutations and subscriptions are blocked.

The workspace is the current directory. The repo is already cloned there (or this is a fresh dir if no hook was needed).
