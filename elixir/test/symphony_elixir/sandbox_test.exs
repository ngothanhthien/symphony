defmodule SymphonyElixir.Claude.SandboxTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Claude.{AppServer, Sandbox}
  alias SymphonyElixir.Config

  describe "build/2 env isolation" do
    test "never propagates tracker.api_key to the Claude process" do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: "super-secret-linear-token",
        claude_command: "claude"
      )

      assert Config.settings!().tracker.api_key == "super-secret-linear-token"

      with_claude_stub(fn ->
        workspace = unique_workspace()
        assert {:ok, spec} = Sandbox.build(workspace)
        assert spec.binary != ""
        # Either the env is empty, or the value is explicitly masked.
        assert spec.env["LINEAR_API_KEY"] == ""
        assert spec.env["LINEAR_API_TOKEN"] == ""
        refute Enum.any?(Map.values(spec.env), &String.contains?(&1, "super-secret-linear-token"))
      end)
    end

    test "explicitly masks parent shell LINEAR_API_KEY so Claude cannot inherit it" do
      original = System.get_env("LINEAR_API_KEY")
      System.put_env("LINEAR_API_KEY", "parent-shell-token")
      on_exit(fn -> restore_env("LINEAR_API_KEY", original) end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: nil,
        claude_command: "claude"
      )

      with_claude_stub(fn ->
        assert {:ok, spec} = Sandbox.build(unique_workspace())
        assert spec.env["LINEAR_API_KEY"] == ""
        assert spec.env["LINEAR_API_TOKEN"] == ""
      end)
    end

    test "real spawned claude process never sees LINEAR_API_KEY or LINEAR_API_TOKEN" do
      original_key = System.get_env("LINEAR_API_KEY")
      original_token = System.get_env("LINEAR_API_TOKEN")
      System.put_env("LINEAR_API_KEY", "real-shell-leak-key")
      System.put_env("LINEAR_API_TOKEN", "real-shell-leak-token")

      on_exit(fn ->
        restore_env("LINEAR_API_KEY", original_key)
        restore_env("LINEAR_API_TOKEN", original_token)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_api_token: "config-tracker-token",
        claude_command: "claude"
      )

      with_env_capturing_claude_stub(fn dir ->
        workspace_root = Config.settings!().workspace.root
        File.mkdir_p!(workspace_root)
        workspace = Path.join(workspace_root, "MT-ENV-#{System.unique_integer([:positive])}")
        File.mkdir_p!(workspace)

        # Drive the full Port.open path: Sandbox.build/2 → Session.new/2.
        # AppServer.start_session/2 is the public entry point that wires both.
        assert {:ok, session} = AppServer.start_session(workspace, session_id: "test-#{System.unique_integer([:positive])}")
        assert is_port(session.port)
        # Stub exits 0 immediately; close and wait for the port to drain.
        :ok = AppServer.stop_session(session)

        # Stub writes its env to a file; wait for it (port close races
        # with file flush under load) and then read it back.
        env_file = Path.join(dir, "env.txt")
        assert_wait_file(env_file, 2_000)
        assert File.exists?(env_file), "stub did not write env file at #{env_file}"

        captured = File.read!(env_file) |> String.split("\n", trim: true)

        refute Enum.any?(captured, &String.contains?(&1, "real-shell-leak-key")),
               "claude process should not see parent LINEAR_API_KEY"

        refute Enum.any?(captured, &String.contains?(&1, "real-shell-leak-token")),
               "claude process should not see parent LINEAR_API_TOKEN"

        refute Enum.any?(captured, &String.contains?(&1, "config-tracker-token")),
               "claude process should not see tracker.api_key from config"
      end)
    end
  end

  describe "build/2 argument assembly" do
    test "errors with :claude_binary_not_found when claude.command resolves to nothing" do
      with_empty_path(fn ->
        write_workflow_file!(Workflow.workflow_file_path(),
          claude_command: "definitely-not-a-real-binary-#{System.unique_integer([:positive])}"
        )

        assert {:error, {:claude_binary_not_found, command}} = Sandbox.build(unique_workspace())
        assert is_binary(command)
      end)
    end

    test "includes --model <name> when claude.model is configured" do
      write_workflow_file!(Workflow.workflow_file_path(),
        claude_command: "claude",
        claude_model: "sonnet"
      )

      with_claude_stub(fn ->
        assert {:ok, spec} = Sandbox.build(unique_workspace())
        assert "--model" in spec.args
        assert "sonnet" in spec.args
        assert flag_value_pair?(spec.args, "--model", "sonnet")
      end)
    end

    test "includes --add-dir for each claude.add_dirs entry" do
      write_workflow_file!(Workflow.workflow_file_path(),
        claude_command: "claude",
        claude_add_dirs: ["/tmp/extra-a", "/tmp/extra-b"]
      )

      with_claude_stub(fn ->
        workspace = unique_workspace()
        assert {:ok, spec} = Sandbox.build(workspace)

        assert flag_value_pair?(spec.args, "--add-dir", workspace)
        assert flag_value_pair?(spec.args, "--add-dir", "/tmp/extra-a")
        assert flag_value_pair?(spec.args, "--add-dir", "/tmp/extra-b")
        assert add_dir_count(spec.args) == 3
      end)
    end
  end

  # Drop a tiny stub on PATH that exits 0 so Sandbox.build/2 can resolve
  # the binary without depending on a real `claude` install on the test
  # host.
  defp with_claude_stub(fun) do
    dir = Path.join(System.tmp_dir!(), "symphony-sandbox-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "claude")
    File.write!(script, "#!/bin/sh\nexit 0\n")
    File.chmod!(script, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> (original_path || ""))

    try do
      fun.()
    after
      restore_env("PATH", original_path)
      File.rm_rf!(dir)
    end
  end

  # Drop a stub that writes its inherited env to a file, then exits 0.
  # This exercises the full Port.open path through Session.new/2 so we
  # can assert what the actual OS process saw, not just what the launch
  # spec said.
  defp with_env_capturing_claude_stub(fun) do
    dir = Path.join(System.tmp_dir!(), "symphony-sandbox-env-bin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    script = Path.join(dir, "claude")
    env_file = Path.join(dir, "env.txt")

    File.write!(script, """
    #!/bin/sh
    env > "#{env_file}"
    exit 0
    """)

    File.chmod!(script, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> (original_path || ""))

    try do
      fun.(dir)
    after
      restore_env("PATH", original_path)
      File.rm_rf!(dir)
    end
  end

  # Sandbox the search PATH to an empty directory so `System.find_executable`
  # cannot accidentally resolve a real `claude` binary the developer has
  # installed system-wide.
  defp with_empty_path(fun) do
    dir = Path.join(System.tmp_dir!(), "symphony-sandbox-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    original_path = System.get_env("PATH")
    System.put_env("PATH", dir)

    try do
      fun.()
    after
      restore_env("PATH", original_path)
      File.rm_rf!(dir)
    end
  end

  defp unique_workspace do
    Path.join(System.tmp_dir!(), "symphony-sandbox-ws-#{System.unique_integer([:positive])}")
  end

  # Poll for a file with a deadline. The env-capturing stub writes its
  # `env > file` synchronously, but the OS may not have flushed the
  # file to disk by the time `AppServer.stop_session/1` returns, so we
  # give it a short window.
  defp assert_wait_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    unless wait_until(path, deadline) do
      raise "assert_wait_file: #{path} did not appear within #{timeout_ms}ms"
    end

    :ok
  end

  defp wait_until(path, deadline) do
    if File.exists?(path) do
      true
    else
      if System.monotonic_time(:millisecond) > deadline do
        false
      else
        Process.sleep(20)
        wait_until(path, deadline)
      end
    end
  end

  defp flag_value_pair?(args, flag, value) do
    Enum.zip(args, Enum.drop(args, 1)) |> Enum.any?(fn {f, v} -> f == flag and v == value end)
  end

  defp add_dir_count(args) do
    Enum.zip(args, Enum.drop(args, 1))
    |> Enum.count(fn
      {"--add-dir", _} -> true
      _ -> false
    end)
  end
end
