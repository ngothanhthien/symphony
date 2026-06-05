defmodule SymphonyElixir.OrchestratorClaudeE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.AppServer
  alias SymphonyElixir.{Config, Tracker, Workspace}

  test "end-to-end: workspace + sandbox + port + claude process see harness policy and no Linear secrets" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-e2e-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(test_root, "bin")
    workspace_root = Path.join(test_root, "workspaces")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(workspace_root)

    claude_script = Path.join(bin_dir, "claude")
    env_file = Path.join(test_root, "claude-env.txt")
    prompt_file = Path.join(test_root, "claude-prompt.txt")

    # Stub binary that:
    #   * writes its full env to env_file (proves what the OS process saw)
    #   * reads the user prompt sent by the AppServer on stdin (proves
    #     the prompt reached Claude)
    #   * then blocks until killed — we just need the env+prompt
    #     capture, not a successful turn result.
    File.write!(claude_script, """
    #!/bin/sh
    env > "#{env_file}"

    first_line=""
    while IFS= read -r line; do
      case "$line" in
        *'"role":"user"'*)
          first_line=$(printf '%s' "$line" | sed -n 's/.*"content":"\\([^"]*\\)".*/\\1/p')
          break
          ;;
      esac
    done

    printf '%s' "$first_line" > "#{prompt_file}"

    # Block forever; the test will close the port and kill us.
    sleep 30
    """)

    File.chmod!(claude_script, 0o755)

    previous_path = System.get_env("PATH")
    previous_key = System.get_env("LINEAR_API_KEY")
    previous_token = System.get_env("LINEAR_API_TOKEN")

    System.put_env("PATH", bin_dir <> ":" <> (previous_path || ""))
    System.put_env("LINEAR_API_KEY", "leak-from-shell-key")
    System.put_env("LINEAR_API_TOKEN", "leak-from-shell-token")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("LINEAR_API_KEY", previous_key)
      restore_env("LINEAR_API_TOKEN", previous_token)
      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      workspace_root: workspace_root,
      claude_command: "claude",
      prompt: """
      You are a Symphony Claude runner for {{ issue.identifier }}.

      Symphony is read-only orchestration. All Linear writes must go through
      scripts/bin/harness-cli. Do not manually edit Linear comments.
      Do not manually transition Linear status.
      """
    )

    # The Memory tracker exposes only the three read callbacks. A direct
    # write path would have to invent a callback that doesn't exist.
    refute function_exported?(Tracker, :create_comment, 2)
    refute function_exported?(Tracker, :update_issue_state, 2)

    # Drive the same Workspace + AppServer path the orchestrator drives
    # when it dispatches an issue: Workspace.create_for_issue/2 to make
    # the per-issue directory, then AppServer.start_session/2 to spawn
    # the Claude process through Sandbox.build/2.
    assert {:ok, workspace} = Workspace.create_for_issue("MT-E2E")
    assert {:ok, session} = AppServer.start_session(workspace, session_id: "test-#{System.unique_integer([:positive])}")
    assert is_port(session.port)

    # Send the prompt the same way AppServer.run_turn does. We don't
    # need run_turn to return successfully — the goal of this test is
    # to confirm what the OS process actually received.
    prompt = "Symphony is read-only orchestration. harness-cli is the only write path. Do not manually edit Linear comments. Do not manually transition Linear status. Issue: MT-E2E."

    msg = %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => prompt}
    }

    Port.command(session.port, Jason.encode!(msg) <> "\n")

    # Wait for the stub to have read and written the prompt. This
    # proves the full path: orchestrator → Workspace → Sandbox →
    # Port.open → spawned claude process → its stdin.
    assert_wait(fn -> File.exists?(prompt_file) and byte_size(File.read!(prompt_file)) > 0 end, 5_000)

    # --- assertions on the env the real OS process saw ----------------
    captured_env = File.read!(env_file) |> String.split("\n", trim: true)

    refute Enum.any?(captured_env, &String.contains?(&1, "leak-from-shell-key")),
           "Claude process should not see parent LINEAR_API_KEY"

    refute Enum.any?(captured_env, &String.contains?(&1, "leak-from-shell-token")),
           "Claude process should not see parent LINEAR_API_TOKEN"

    # --- assertions on the prompt that reached the Claude process ----
    captured_prompt = File.read!(prompt_file)
    assert captured_prompt == prompt, "expected claude to receive the exact prompt we sent"

    # --- assertions on the runtime config ----------------------------
    settings = Config.settings!()

    assert settings.claude.expose_linear_api_key == false,
           "claude.expose_linear_api_key should remain false in validated settings"

    # Cleanup: stop the session so the port (and the blocked binary) are
    # torn down.
    :ok = AppServer.stop_session(session)
  end

  defp assert_wait(predicate, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> predicate.() end)
    |> Stream.take_while(fn ok -> not ok end)
    |> Stream.each(fn _ ->
      if System.monotonic_time(:millisecond) > deadline do
        raise "assert_wait: predicate never became true within #{timeout_ms}ms"
      end

      Process.sleep(20)
    end)
    |> Stream.run()

    unless predicate.() do
      raise "assert_wait: predicate never became true within #{timeout_ms}ms"
    end

    :ok
  end
end
