defmodule SymphonyElixir.Claude.Sandbox do
  @moduledoc """
  Builds the `claude -p` command-line for a Symphony Claude transport session.

  Mirrors the public API of the previous Codex transport so the rest of
  Symphony (orchestrator, agent runner, dashboard) can treat a Claude session
  as a drop-in alternative.
  """

  require Logger
  alias SymphonyElixir.Config

  @type launch_spec :: %{
          binary: String.t(),
          args: [String.t()],
          env: %{optional(String.t()) => String.t()},
          cd: String.t() | nil
        }

  @spec build(Path.t(), keyword()) :: {:ok, launch_spec()} | {:error, term()}
  def build(workspace, opts \\ []) do
    settings = Config.settings!()
    claude_settings = settings.claude

    with {:ok, binary} <- resolve_binary(claude_settings.command) do
      session_flag = session_flag(opts)

      args =
        [
          "-p",
          "--input-format", "stream-json",
          "--output-format", "stream-json",
          "--replay-user-messages",
          "--include-partial-messages",
          "--verbose",
          "--bare",
          "--permission-mode", "bypassPermissions"
        ]
        |> Kernel.++(session_flag)
        |> append_optional("--model", claude_settings.model)
        |> append_optional("--add-dir", workspace)
        |> append_add_dirs(claude_settings.add_dirs)

      spec = %{
        binary: binary,
        args: args,
        env: %{"LINEAR_API_KEY" => settings.tracker.api_key || ""},
        cd: workspace
      }

      {:ok, spec}
    end
  end

  # `opts` may carry `:resume` (continue an existing session) or `:session_id`
  # (force a specific id). If both are absent we omit the flag entirely and
  # let `claude` pick its own id. `:resume` takes precedence over `:session_id`.
  defp session_flag(opts) do
    case Keyword.get(opts, :resume) do
      id when is_binary(id) and id != "" -> ["--resume", id]
      _ ->
        case Keyword.get(opts, :session_id) do
          id when is_binary(id) and id != "" -> ["--session-id", id]
          _ -> []
        end
    end
  end

  defp resolve_binary(command) do
    case System.find_executable(command) do
      nil -> {:error, {:claude_binary_not_found, command}}
      binary -> {:ok, binary}
    end
  end

  defp append_optional(args, _flag, nil), do: args
  defp append_optional(args, _flag, ""), do: args
  defp append_optional(args, flag, value), do: args ++ [flag, value]

  defp append_add_dirs(args, nil), do: args
  defp append_add_dirs(args, []), do: args

  defp append_add_dirs(args, dirs) do
    Enum.reduce(dirs, args, fn dir, acc -> acc ++ ["--add-dir", dir] end)
  end
end
