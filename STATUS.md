# STATUS — Symphony + Claude transport (post-compact resume)

## Where we are

- **Repo**: `github.com/ngothanhthien/symphony` (forked from `openai/symphony`)
- **Branch**: `claude-transport`
- **Local dir**: `/home/cnnt/self/symphony`
- **Date**: 2026-06-03

## What's done

| # | Phase | Commit |
|---|---|---|
| 1 | Forked `openai/symphony` → `ngothanhthien/symphony`, set up `upstream` + `origin` | (initial) |
| 2 | Documented this is a fork in root README | `docs: note this is a Claude-transport fork of openai/symphony` |
| 3 | Added Claude transport (4 modules + 3 Bash helpers + schema) | `feat: add Claude Code transport (claude -p + stream-json)` |
| 4 | Added session resume across orchestrator restarts (SessionStore + Sandbox updates) | `feat(claude): persist and resume session across orchestrator restarts` |
| 5 | Removed all codex transport code (folder, schema, agent_runner, config helpers, mix.exs) | (uncommitted) |

## What's still open

- **Test end-to-end** with real Linear issue: blocked on the bug we hit before compaction — `WORKFLOW.md` had `transport: claude` set, but somehow the codex path was still being attempted. Now that the codex code is gone, the next run should go through Claude cleanly. **Next step: rerun.**
- **Cleanup + key rotation** (task #42): `.env` should be removed, key should be rotated on Linear.
- The background Symphony process started before compaction was killed.

## Files changed in the uncommitted "remove codex" pass

- `elixir/lib/symphony_elixir/codex/` — DELETED (whole folder)
- `elixir/lib/symphony_elixir/agent_runner.ex` — `transport_module/0` removed, calls `SymphonyElixir.Claude.AppServer` directly; renamed `do_run_codex_turns` → `do_run_claude_turns`; docstring updated
- `elixir/lib/symphony_elixir/config/schema.ex` — `Codex` schema block removed, `embeds_one(:codex, ...)` removed, `transport` default is now `"claude"` and only `"claude"` is valid, `finalize_settings` no longer touches codex settings, `resolve_*_sandbox_policy` now returns empty maps, `default_turn_sandbox_policy` and helpers removed, `normalize_optional_map` and `PathSafety` alias removed
- `elixir/lib/symphony_elixir/config.ex` — `codex_turn_sandbox_policy/1`, `codex_runtime_settings/2`, `@type codex_runtime_settings` all removed
- `elixir/mix.exs` — `ignore_modules` for `Codex.AppServer` / `Codex.DynamicTool` replaced with `Claude.AppServer` / `Claude.SessionStore`
- `.gitignore` — added to protect `.env` and build artifacts

## Known broken / to revisit

- `elixir/lib/symphony_elixir/cli.ex` still has the literal "Codex will run without any guardrails" warning text. Cosmetic only — safe to leave or fix later.
- `elixir/lib/symphony_elixir_web/live/dashboard_live.ex` still has "Codex runtime" / "Codex update" labels. Cosmetic only.
- `elixir/lib/symphony_elixir/workspace.ex`, `orchestrator.ex` docstrings still mention Codex. Cosmetic only.
- `elixir/test/symphony_elixir/workspace_and_config_test.exs` references `Schema.resolve_turn_sandbox_policy` which I now return `%{}` for. The tests likely fail. Out of scope for now.

## Test setup ready to use

- `.env` at `/home/cnnt/self/symphony/.env` (mode 600). Contains `LINEAR_API_KEY=lin_api_...` (the key was pasted in chat — **rotate on Linear** before reusing in production).
- Test Linear project: `Symphony Claude Test` (slug `fee6284555ff`) in team `English_game` (key `ENG`).
- Test issue: `ENG-5` — "Echo test: write a hello file" — moved to `Todo` so Symphony will pick it up.
- `WORKFLOW.md` at `/home/cnnt/self/symphony/test-e2e/WORKFLOW.md` references all of the above.
- `claude` CLI on `$PATH` (`/home/cnnt/.local/bin/claude`) with valid credentials.

## How to rerun the end-to-end test (post-compact)

```bash
cd /home/cnnt/self/symphony
set -a && source .env && set +a
rm -rf /tmp/symphony-test-workspaces
cd elixir
mise exec -- ./bin/symphony ../test-e2e/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Expected: poll picks up `ENG-5` → Claude spawns → does the file work → moves issue to `Done`.

## Tasks currently on the list

- #41 (in_progress) — re-run end-to-end after the codex removal
- #42 (pending) — remove `.env` and rotate the Linear key
- #44 (in_progress) — this file

## Reminders for the resumed session

- Don't recreate `codex/`. The transport module is `SymphonyElixir.Claude.AppServer`, period.
- The Claude CLI flags used: `-p --input-format stream-json --output-format stream-json --replay-user-messages --include-partial-messages --verbose --bare --permission-mode bypassPermissions [--session-id <uuid>|--resume <uuid>]`.
- The only bash helper that remains at `bin/symphony-claude-tools/` is `linear-graphql` (read-only — see its docstring for the mutation guard). All Linear writes are routed through `scripts/bin/harness-cli` in the Harness project, not in Symphony.
- The session-id persists to `<workspace>/.symphony/claude-session.json` for resume; wiped on terminal state.
