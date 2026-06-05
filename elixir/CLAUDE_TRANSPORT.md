# Claude Code Transport

This fork replaces the Codex app-server transport in [openai/symphony][upstream]
with a [Claude Code CLI][claude-cli] transport. Everything else — the
orchestrator, Linear polling, the workspace lifecycle, the dashboard — is
unchanged.

[upstream]: https://github.com/openai/symphony
[claude-cli]: https://code.claude.com/docs/en/agent-sdk

## What works

- `start_session` / `run_turn` / `stop_session` API matches `Codex.AppServer`
  byte-for-byte, so the orchestrator and dashboard work without changes.
- The Claude session is launched in non-interactive mode
  (`claude -p --output-format stream-json --input-format stream-json`).
- Always runs with `--permission-mode bypassPermissions`. Do not point this at
  an untrusted workspace.
- The Claude session id is generated up-front and passed to `claude` via
  `--session-id`, so it can be resumed across turns with `-r`.
- Tool calls are emitted as plain Bash invocations against helper scripts in
  `bin/symphony-claude-tools/` — see [Helpers](#helpers) below.

## What does NOT work (yet)

- **No MCP dynamic tools.** The Codex `linear_graphql` dynamic tool has been
  replaced by helper scripts the agent invokes via Bash. There is no automatic
  schema-driven tool registration.
- **No fine-grained approval flow.** Claude CLI's `--permission-mode` is
  all-or-nothing. If you need a non-`bypassPermissions` mode, fork the
  transport and add it.
- **No codex transport.** The Codex transport has been removed from this
  fork. The orchestrator calls `SymphonyElixir.Claude.AppServer` directly
  (no transport switch). To use Codex, check out `main` before the
  removal commit.

## Configuration

Add an `agent.transport: claude` field and a `claude:` block to your
`WORKFLOW.md`:

```yaml
tracker:
  kind: linear
  project_slug: "your-project"
  api_key: $LINEAR_API_KEY
  active_states: [Todo, "In Progress"]
  terminal_states: [Done, Cancelled]

agent:
  transport: claude            # required
  max_concurrent_agents: 5
  max_turns: 10

claude:
  command: claude              # path to the `claude` binary
  model: sonnet                # optional; omit to use Claude Code default
  add_dirs: ["."]              # extra --add-dir values (in addition to the
                               # per-turn workspace)
  turn_timeout_ms: 3600000     # how long to wait for one turn to complete

workspace:
  root: ~/code/symphony-workspaces
```

### Field reference

| Field | Type | Default | Notes |
|---|---|---|---|
| `agent.transport` | `"claude"` | `"claude"` | Codex transport has been removed in this fork. |
| `claude.command` | string | `"claude"` | Must be on `PATH` (or absolute path). |
| `claude.model` | string | (CLI default) | e.g. `sonnet`, `opus`. |
| `claude.add_dirs` | list of strings | `[]` | Extra `--add-dir` flags. The per-turn workspace is always added automatically. |
| `claude.turn_timeout_ms` | integer | `3600000` | One hour. |

## Helpers

`bin/symphony-claude-tools/` contains a single read-only Bash wrapper that
the agent is told (via the system prompt) to call when it needs to read from
Linear. It uses `jq` + `curl` and has no extra runtime dependencies.

| Script | Purpose |
|---|---|
| `linear-graphql --query "<QL>" [--vars '<json>']` | Run a raw GraphQL **query**. Mutations and subscriptions are blocked at the script level. Prints the `data` field as JSON. |

Exit codes: `0` success, `2` bad args, `3` missing `LINEAR_API_KEY`, `4`
network/HTTP error, `5` GraphQL errors, `6` blocked write operation
(mutation / subscription). The agent is expected to inspect `$?` and `stderr`.

> **Symphony is read-only orchestration.** `linear-graphql` is the only
> Linear read helper that ships with the Symphony repo. Any Linear write
> (comment, status transition, workpad edit) must be routed through the
> Harness CLI (`scripts/bin/harness-cli`) in the Harness project, not
> through Symphony. There is intentionally no `linear-add-comment` or
> `linear-update-issue` script in this repo.

## Security

**`--permission-mode bypassPermissions` means the agent can run any Bash
command, read or write any file under `--add-dir`, and exfiltrate to the
network.** Mitigations:

- Always pass `--add-dir` set to the per-turn workspace, not the host repo.
  Symphony does this automatically via `Claude.Sandbox`.
- Run Symphony in a dedicated user account or container.
- Audit the workspace contents before letting agents run.
- The Bash helpers never accept stdin; they only do what their args say.

## Session persistence and resume

The Claude transport persists the session id to
`<workspace>/.symphony/claude-session.json` after `start_session` succeeds.
If the orchestrator crashes (or is restarted) before the issue reaches a
terminal state, the next `start_session` call for the same workspace will
spawn `claude -p --resume <id>` instead of `--session-id <new>`, so the
agent picks up where it left off instead of losing all context.

The on-disk file is wiped by `AgentRunner` when the issue reaches a terminal
state (Done / Cancelled / etc.) or when the orchestrator returns an error,
so a fresh run on the same workspace always starts a fresh session.

### Verified behaviour

A smoke test (see git history for the script) confirmed that with the
session id persisted on disk:

1. Turn 1: `claude -p --session-id <uuid>` is told "remember BERYLLIUM",
   replies "ok".
2. The `claude` process exits, then a **new** process is spawned as
   `claude -p --resume <uuid>`.
3. Turn 2 in the new process is asked "what's the secret word?" and answers
   "**The secret word is BERYLLIUM.**"

The session store is at `<workspace>/.symphony/claude-session.json` and has
this shape:

```json
{
  "version": 1,
  "thread_id": "<uuid>",
  "created_at": "<iso8601>",
  "last_seen_at": "<iso8601>"
}
```

## Running

```bash
export LINEAR_API_KEY=linapi_...
mise exec -- ./bin/symphony ./WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

The `--i-understand-...` flag is the same one `symphony` has always required
when run without the usual guardrails. It is checked before spawning
`Claude.AppServer`.

## Files

| Path | Purpose |
|---|---|
| `elixir/lib/symphony_elixir/claude/sandbox.ex` | Builds the `claude -p` argv (incl. `--resume` vs `--session-id`). |
| `elixir/lib/symphony_elixir/claude/session.ex` | Per-turn state (port, session id, tool-use tracking, resume flag). |
| `elixir/lib/symphony_elixir/claude/session_store.ex` | Read/write `<workspace>/.symphony/claude-session.json` atomically. |
| `elixir/lib/symphony_elixir/claude/stream.ex` | Line-buffered JSON stream reader. |
| `elixir/lib/symphony_elixir/claude/app_server.ex` | Public API (start_session, run_turn, stop_session, run). |
| `elixir/lib/symphony_elixir/agent_runner.ex` | Calls `Claude.AppServer` directly (the Codex transport has been removed). Wipes the Claude session store on terminal/error. |
| `elixir/lib/symphony_elixir/config/schema.ex` | `claude` schema block; the `agent.transport` field is now `"claude"`-only. |
| `bin/symphony-claude-tools/linear-*` | Bash helpers the agent calls. |

## Limitations and known issues

- **The dashboard's "Codex" terminology is unchanged.** It will say
  `codex_app_server_pid` and `codex_worker_update` for Claude sessions too.
  A follow-up can rename these in the dashboard presenter.
- **Approval flow is `bypassPermissions` only.** If you want a non-bypass
  mode, you can spawn a second transport in a separate worktree — the
  current `claude.ex` does not accept a mode override.
- **Resume only works if the workspace directory is preserved.** If
  `workspace.before_remove` runs before resume, the session id is gone.
  The current `agent_runner` does call `SessionStore.clear/1` on terminal
  state, so resume is only useful mid-issue.
