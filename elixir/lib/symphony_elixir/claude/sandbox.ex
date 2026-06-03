defmodule SymphonyElixir.Claude.Sandbox do
  @moduledoc """
  Builds the `claude -p` command-line for a Symphony Claude transport session.

  Mirrors `SymphonyElixir.Codex.AppServer`'s view of the world so that the rest
  of Symphony (orchestrator, agent runner, dashboard) can treat a Claude session
  as a drop-in alternative to a Codex app-server session.
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
        |> append_optional("--model", claude_settings.model)
        |> append_optional("--add-dir", workspace)
        |> append_add_dirs(claude_settings.add_dirs)
        |> append_optional("--session-id", Keyword.get(opts, :session_id))
        |> List.flatten()

      spec = %{
        binary: binary,
        args: args,
        env: %{"LINEAR_API_KEY" => settings.tracker.api_key || ""},
        cd: workspace
      }

      {:ok, spec}
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
