---
tracker:
  kind: linear
  project_slug: "YOUR_PROJECT"
  api_key: $LINEAR_API_KEY
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate

polling:
  interval_ms: 5000

workspace:
  root: ~/code/symphony-workspaces

agent:
  transport: claude
  max_concurrent_agents: 3
  max_turns: 20

claude:
  command: claude
  model: sonnet
  expose_linear_api_key: false
  turn_timeout_ms: 3600000

hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
    ./scripts/bin/harness-cli doctor
    ./scripts/bin/harness-cli tracker doctor
---

Symphony is read-only orchestration.

You are Claude working on Linear issue `{{ issue.identifier }}`.

All Linear writes must go through `./scripts/bin/harness-cli` (the Harness CLI). Symphony itself does not write to Linear, and your Claude process does not receive the Linear API token. There is no soft-policy fallback: if you cannot go through Harness, you cannot write to Linear.

Do not manually edit Linear comments.
Do not manually create Linear issues.
Do not manually transition Linear status.
Do not use raw GraphQL, curl, gh extensions, or any direct Linear API call.

Symphony handles:
- polling candidate issues
- reading issue state
- workspace lifecycle
- Claude process lifecycle
- retries, blocked state, dashboard, logs

Harness handles:
- Linear workpad
- intake
- lane
- story
- proof
- trace
- backlog
- issue status transition

You:
- read context Symphony already provided
- call `scripts/bin/harness-cli <command>` for any tracking, workpad, proof, trace, or status write
- implement code in the workspace

Issue context:

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Required flow:

1. Read project onboarding:
   - `AGENTS.md`
   - `docs/HARNESS.md`
   - `docs/FEATURE_INTAKE.md`
   - `docs/TEST_MATRIX.md`

2. Start work by transitioning the issue through Harness:

   scripts/bin/harness-cli issue transition \
     --issue {{ issue.identifier }} \
     --state "In Progress"

3. Record intake through Harness.

4. Create or update the story through Harness if the lane requires one.

5. Implement in the workspace copy. Stay in the provided repository copy; do not touch any other path.

6. Run validation per `docs/TEST_MATRIX.md`.

7. Record proof through Harness.

8. Record trace through Harness.

9. Move to `Human Review` through Harness.

## Guardrails

- If a `harness-cli` command is unavailable, treat that as a true blocker. Do not fall back to direct Linear writes.
- Do not attempt to read the Linear API token from the environment; Symphony does not pass it to your process.
- Do not modify `WORKFLOW.md` or Symphony's config.
- Operate autonomously end-to-end unless blocked by missing Harness tools, missing required secrets, or missing required permissions.
- Do not post completion summaries as top-level comments; record final notes through Harness.
- If the ticket is in a terminal state (`Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`), do nothing and end the turn.
