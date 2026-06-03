defmodule SymphonyElixir.Claude.SessionStore do
  @moduledoc """
  Persists the Claude session id for a workspace so a fresh `claude -p` invocation
  can resume the conversation after an orchestrator restart.

  The store lives at `<workspace>/.symphony/claude-session.json` and contains:

      {
        "version": 1,
        "thread_id": "<uuid>",
        "created_at": "<iso8601>",
        "last_seen_at": "<iso8601>"
      }

  Writes are atomic (write-to-temp + rename) so a crash mid-write never leaves
  a half-baked file.
  """

  require Logger

  @version 1
  @dir ".symphony"
  @filename "claude-session.json"

  @type entry :: %{
          version: pos_integer(),
          thread_id: String.t(),
          created_at: String.t(),
          last_seen_at: String.t()
        }

  @spec path(Path.t()) :: Path.t()
  def path(workspace), do: Path.join(Path.join(workspace, @dir), @filename)

  @doc """
  Read the persisted session entry for `workspace`, or `nil` if none exists
  or the file is unreadable.
  """
  @spec read(Path.t()) :: entry() | nil
  def read(workspace) do
    file = path(workspace)

    with true <- File.regular?(file),
         {:ok, raw} <- File.read(file),
         {:ok, entry} <- decode(raw) do
      entry
    else
      _ -> nil
    end
  end

  @doc """
  Persist a session entry atomically. Returns `:ok` on success.
  """
  @spec write(Path.t(), String.t()) :: :ok | {:error, term()}
  def write(workspace, thread_id) do
    file = path(workspace)
    dir = Path.dirname(file)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    entry = %{
      version: @version,
      thread_id: thread_id,
      created_at: now,
      last_seen_at: now
    }

    with :ok <- File.mkdir_p(dir),
         json <- Jason.encode!(entry),
         :ok <- atomic_write(file, json) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Claude.SessionStore: failed to write #{file}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Bump the `last_seen_at` field. Reads the entry first to preserve the original
  `created_at`. Returns the new entry on success.
  """
  @spec touch(Path.t(), String.t()) :: {:ok, entry()} | {:error, term()}
  def touch(workspace, thread_id) do
    file = path(workspace)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    base =
      case read(workspace) do
        nil -> %{version: @version, created_at: now}
        entry -> %{entry | version: @version}
      end

    entry = %{base | thread_id: thread_id, last_seen_at: now}

    with :ok <- File.mkdir_p(Path.dirname(file)),
         json <- Jason.encode!(entry),
         :ok <- atomic_write(file, json) do
      {:ok, entry}
    else
      {:error, reason} = err ->
        Logger.warning("Claude.SessionStore: failed to touch #{file}: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Remove the persisted entry, if any. Missing file is not an error.
  """
  @spec clear(Path.t()) :: :ok
  def clear(workspace) do
    file = path(workspace)
    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} ->
        Logger.warning("Claude.SessionStore: failed to remove #{file}: #{inspect(reason)}")
        :ok
    end
  end

  # --- internals -----------------------------------------------------------

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{"version" => @version, "thread_id" => thread_id, "created_at" => created_at, "last_seen_at" => last_seen_at}}
      when is_binary(thread_id) and is_binary(created_at) and is_binary(last_seen_at) ->
        {:ok,
         %{
           version: @version,
           thread_id: thread_id,
           created_at: created_at,
           last_seen_at: last_seen_at
         }}

      _ ->
        :error
    end
  end

  defp atomic_write(file, contents) do
    tmp = file <> ".tmp"
    with :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end
end
