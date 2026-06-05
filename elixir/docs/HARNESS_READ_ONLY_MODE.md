# Symphony ↔ Harness Read-Only Boundary

This document describes the boundary between **Symphony** (the Elixir orchestrator)
and the **Harness** (the workflow CLI that Claude drives). It is the canonical
reference for the read-only contract: what each side owns, what it must not
do, and how the boundary is enforced at the code level.

## Why this exists

Symphony runs Claude under `--permission-mode bypassPermissions`. In that mode
the agent process can do whatever its environment allows. If the Linear API
token leaks into the agent's env, the prompt is no longer a real boundary —
the agent can issue a `commentCreate` or `issueUpdate` GraphQL mutation
without any human in the loop.

To keep that from happening, the boundary is enforced in five independent
layers, each of which can be tested on its own. None of them is "soft policy";
all are code-level refusals or env-level masking.

## Ownership

### Symphony owns

- Polling Linear for candidate issues (`Tracker.fetch_candidate_issues/0`).
- Reading issue state by ID and by state (`Tracker.fetch_issue_states_by_ids/1`,
  `Tracker.fetch_issues_by_states/1`).
- Workspace lifecycle (create / remove, hooks, after_create clone).
- Claude process lifecycle (start session, run turn, stop session, persist
  session id, resume on next attempt).
- Retries, blocked-state tracking, dashboard rendering, log file rotation.
- Agent runner continuation logic (decide whether to issue another turn or
  return control to the orchestrator).

### Harness owns

- The Linear workpad (single persistent comment per issue).
- Intake / lane / story / proof / trace artifacts.
- The backlog.
- Issue status transitions (`Todo → In Progress → Human Review → Merging → Done`,
  and the `Rework` loop).
- Any other Linear write (comments, labels, links, attachments).

### Claude owns

- Reading the context Symphony already provided in the prompt and
  `AGENTS.md` / `docs/HARNESS.md` / `docs/FEATURE_INTAKE.md` /
  `docs/TEST_MATRIX.md`.
- Implementing code in the workspace copy.
- Calling `scripts/bin/harness-cli <command>` for any tracking, workpad,
  proof, trace, or status write.
- Claude must **not** call Linear directly — not via MCP, not via raw GraphQL,
  not via curl, not via gh extensions.

## Enforcement layers

1. **Tracker behaviour is read-only.** `SymphonyElixir.Tracker` exposes only
   `fetch_candidate_issues/0`, `fetch_issues_by_states/1`, and
   `fetch_issue_states_by_ids/1`. The legacy `create_comment/2` and
   `update_issue_state/2` callbacks are removed. `SymphonyElixir.Tracker.Memory`
   no longer publishes `memory_tracker_comment` or
   `memory_tracker_state_update` events.

2. **`SymphonyElixir.Linear.Adapter` is read-only.** The module file
   contains no `mutation` string, no `commentCreate`, no `issueUpdate`, and
   no `resolve_state_id/2` helper. The
   `extensions_test.exs` regression test reads the file and asserts those
   tokens are absent.

3. **`SymphonyElixir.Linear.Client` rejects mutations.** The public
   `graphql/3` entry point now refuses to send any operation that contains
   a `mutation` or `subscription` operation. The check is conservative:
   it strips `#` line comments first (so a leading explanatory comment
   cannot smuggle in a mutation), and it also matches `mutation` /
   `subscription` appearing after a leading fragment or query. Any
   detected write returns
   `{:error, :linear_write_operation_blocked}`. This is the safety net
   behind layers 1 and 2: even if a future adapter reintroduces a
   mutation, the client refuses to transport it.

4. **`LINEAR_API_KEY` is not passed to Claude.** `SymphonyElixir.Claude.Sandbox.build/2`
   builds the launch spec with a minimal env (`PATH`, `HOME`, and
   explicitly-empty `LINEAR_API_KEY` / `LINEAR_API_TOKEN`). When the
   `Claude.Session.open_port/1` helper hands that env to `Port.open/2`,
   the `env:` option replaces the inherited OS environment — so even if
   a parent shell has set `LINEAR_API_KEY`, the Claude OS process cannot
   see it. A process-level test in `claude/sandbox_test.exs` spawns a
   fake `claude` binary that writes its env to a file and asserts the
   real `LINEAR_API_KEY` / `LINEAR_API_TOKEN` from the parent shell are
   not present in the captured env.

   `claude.expose_linear_api_key` is a schema-level field that
   defaults to `false`. The `Claude.changeset/2` validator rejects
   `true` with a hard error, so the read-only contract is also a
   config contract: any workflow that tries to set
   `expose_linear_api_key: true` fails `Schema.parse/1` rather than
   silently dropping the flag.

5. **Workflow lint prevents direct-write instructions.** The
   `mix prompt.lint` task scans `WORKFLOW.harness-claude-runner.md` and
   fails the build if it contains forbidden phrases
   (`Codex Workpad`, `linear_graphql`, `Linear MCP`, `commentCreate`,
   `issueUpdate`, `create a Linear issue`, `move Linear issue`,
   `transition Linear issue directly`) or if it omits any required
   boundary phrase (`harness-cli`, `Symphony is read-only orchestration`,
   `Do not manually edit Linear comments`,
   `Do not manually transition Linear status`,
   `All Linear writes must go through`).

   This means a future workflow edit cannot quietly regress the prompt
   into a direct-Linear-writer posture.

   **Convention: forbidden phrases are forbidden everywhere.** The
   lint check is a plain `String.contains?/2` over the whole file.
   Writing "Do not use `linear_graphql`" trips the lint the same way
   the positive form would. This is intentional — a workflow that
   needs to mention a forbidden token to forbid it is a regression
   risk, because the next reader may copy the phrase into a positive
   instruction. Forbid things using language that does not contain
   the forbidden token itself (e.g. "Do not use raw GraphQL, curl,
   gh extensions, or any direct Linear API call").

## What Symphony does *not* do

- It does not create or update Linear comments.
- It does not move Linear issues between states.
- It does not expose Linear write credentials to the Claude process.
- It does not maintain a per-issue workpad, story, proof, or trace.
- It does not file backlog issues.

If you need any of those, route through `scripts/bin/harness-cli` from the
Claude process. The orchestrator will not help you.

## Regressions to watch for

- Adding a new public function to `SymphonyElixir.Tracker` that writes to
  the tracker. (The behaviour module is now strictly read-only.)
- Adding a mutation GraphQL string back into `SymphonyElixir.Linear.Adapter`.
  (Layer 2 — checked by the regression test.)
- Bypassing `SymphonyElixir.Linear.Client.graphql/3` (e.g. adding a new
  raw HTTP call in the adapter). (Layer 3 still refuses mutations —
  including mutations after leading comments or fragments.)
- Reintroducing `LINEAR_API_KEY` into the Claude launch spec. (Layer 4 —
  the spec-level test in `sandbox_test.exs` catches a regression in
  `agent_env/0`; the process-level test catches a regression in
  `Session.open_port/1`.)
- Setting `claude.expose_linear_api_key: true` in a workflow.
  `Schema.parse/1` now rejects the value at validation time, so this
  cannot slip through as a no-op.
- Editing `WORKFLOW.harness-claude-runner.md` to remove the
  `harness-cli`-only policy. (Layer 5.)
- Bringing back a Linear *write* tool under
  `bin/symphony-claude-tools/` (e.g. `linear-add-comment`,
  `linear-update-issue`). The repo only ships a read-only
  `linear-graphql` helper with a mutation/subscription guard at the
  script level (`bin/tests/linear-graphql_test.sh` covers the guard).
  Any new write helper is itself a boundary violation.
- Reintroducing `LINEAR_API_KEY` into a workspace hook's environment.
  `Workspace.run_hook/5` now `unset LINEAR_API_KEY LINEAR_API_TOKEN`
  before running both the local and remote hook scripts, and
  `workspace_and_config_test.exs` exercises the local path. The
  remote `before_remove` hook is covered by the same regression test
  — it routes through the shared `build_remote_hook_script/2` helper
  so the scrub cannot be accidentally dropped in one branch but not
  the other.
- Weakening the read-only guard so it fails to match a write that
  lacks the canonical whitespace before the selection set
  (e.g. `mutation{...}` with no space). `Linear.Client.graphql/3`
  uses a single comment-stripped regex with a `(?=\s|\{)` lookahead
  on the right, and `bin/symphony-claude-tools/linear-graphql` uses
  the equivalent `[[:space:]]|\{` boundary in `grep -E`. Both are
  covered by regression tests that probe the compact form, and the
  shell test also covers identifiers that merely contain the
  keyword (`mutationLog`).
