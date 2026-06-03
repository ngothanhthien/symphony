defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Symphony transport that talks to the Claude Code CLI
  (`claude -p --output-format stream-json`) over stdio.

  Public API: `start_session/2`, `run_turn/4`, `stop_session/1`, `run/4`.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}
  alias SymphonyElixir.Claude.{Session, Stream}

  @type session :: Session.t()

  @type turn_result :: %{
          result: term(),
          session_id: String.t(),
          thread_id: String.t(),
          turn_id: String.t()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) ::
          {:ok, turn_result()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, session} <- Session.new(expanded_workspace, worker_host: worker_host) do
      {:ok, session}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, turn_result()} | {:error, term()}
  def run_turn(%Session{} = session, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    timeout_ms = Config.settings!().claude.turn_timeout_ms

    turn_id = "turn-#{System.unique_integer([:positive])}"
    session = Session.set_turn_id(session, turn_id)

    emit_message(
      on_message,
      :session_started,
      %{session_id: "#{session.thread_id}-#{turn_id}", thread_id: session.thread_id, turn_id: turn_id},
      session.metadata
    )

    send_user_message(session.port, prompt)

    case await_turn_completion(session, on_message, timeout_ms) do
      {:ok, result} ->
        {:ok,
         %{
           result: result,
           session_id: "#{session.thread_id}-#{turn_id}",
           thread_id: session.thread_id,
           turn_id: turn_id
         }}

      {:error, reason} = err ->
        emit_message(
          on_message,
          :turn_ended_with_error,
          %{session_id: "#{session.thread_id}-#{turn_id}", reason: reason},
          session.metadata
        )

        err
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%Session{port: port}) do
    stop_port(port)
    :ok
  end

  # --- internals -----------------------------------------------------------

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp await_turn_completion(session, on_message, timeout_ms) do
    Stream.drain(
      session.port,
      timeout_ms,
      &handle_message(&1, session, on_message, timeout_ms)
    )
  end

  # Callback for Stream.drain/3. Returns :ok to continue, {:halt, value} to
  # terminate the turn.
  defp handle_message(payload, session, on_message, _timeout_ms) do
    case payload do
      %{"type" => "system", "subtype" => "init"} ->
        emit_message(on_message, :notification, %{payload: payload, raw: Jason.encode!(payload)},
          Map.put(session.metadata, :claude_init, payload))
        :ok

      %{"type" => "system", "subtype" => subtype} ->
        emit_message(on_message, :notification, %{payload: payload, raw: Jason.encode!(payload)},
          session.metadata)
        Logger.debug("Claude system event: #{subtype}")
        :ok

      %{"type" => "stream_event", "event" => event} when is_map(event) ->
        handle_stream_event(event, payload, session, on_message)

      %{"type" => "assistant", "message" => msg} when is_map(msg) ->
        emit_message(on_message, :notification, %{payload: payload, raw: Jason.encode!(payload)},
          maybe_set_usage(session.metadata, msg))
        :ok

      %{"type" => "user", "message" => %{"role" => "user"}, "isReplay" => true} ->
        # Replayed user message — already accounted for at send time, ignore.
        :ok

      %{"type" => "user"} ->
        emit_message(on_message, :notification, %{payload: payload, raw: Jason.encode!(payload)},
          session.metadata)
        :ok

      %{"type" => "result", "subtype" => "success"} = payload ->
        emit_message(on_message, :turn_completed, %{payload: payload, raw: Jason.encode!(payload)},
          session.metadata)
        {:halt, :turn_completed}

      %{"type" => "result", "subtype" => subtype} = payload ->
        emit_message(on_message, :turn_failed, %{payload: payload, raw: Jason.encode!(payload)},
          session.metadata)
        {:halt, {:turn_failed, subtype}}

      _ ->
        emit_message(on_message, :other_message, %{payload: payload, raw: Jason.encode!(payload)},
          session.metadata)
        :ok
    end
  end

  defp handle_stream_event(%{"type" => "message_start", "message" => msg}, raw, session, on_message) do
    usage = get_in(msg, ["usage"]) || %{}
    metadata = maybe_set_usage(session.metadata, msg)
    emit_message(on_message, :notification, %{payload: raw, raw: Jason.encode!(raw), usage: usage}, metadata)
    :ok
  end

  defp handle_stream_event(%{"type" => "content_block_start", "content_block" => block}, raw, session, on_message) do
    case block do
      %{"type" => "tool_use", "id" => id, "name" => name} ->
        session = Session.record_tool_use(session, id, %{name: name, input: ""})
        emit_message(on_message, :notification,
          %{payload: raw, raw: Jason.encode!(raw), tool_use_id: id, tool_name: name}, session.metadata)
        :ok

      _ ->
        emit_message(on_message, :notification, %{payload: raw, raw: Jason.encode!(raw)}, session.metadata)
        :ok
    end
  end

  defp handle_stream_event(%{"type" => "content_block_delta"} = event, raw, session, on_message) do
    case event do
      %{"delta" => %{"type" => "text_delta", "text" => text}} ->
        emit_message(on_message, :notification,
          %{payload: raw, raw: Jason.encode!(raw), partial_text: text}, session.metadata)
        :ok

      %{"delta" => %{"type" => "thinking_delta"}} ->
        # Thinking tokens are noise for our use case; just track length.
        :ok

      %{"delta" => %{"type" => "input_json_delta", "partial_json" => partial}} ->
        # Append to the most recent pending tool_use. For simplicity, we attach
        # the partial to all pending tool_uses — Claude emits one tool_use at a
        # time, so this is safe.
        session = update_in(session.pending_tool_uses, &append_partial/1)
        emit_message(on_message, :notification,
          %{payload: raw, raw: Jason.encode!(raw), tool_input_delta: partial}, session.metadata)
        :ok

      _ ->
        emit_message(on_message, :notification, %{payload: raw, raw: Jason.encode!(raw)}, session.metadata)
        :ok
    end
  end

  defp handle_stream_event(%{"type" => "content_block_stop", "index" => index}, raw, session, on_message) do
    # We don't have a direct map of index → tool_use_id here; in practice
    # Claude emits one tool_use at a time and `content_block_stop` for it
    # immediately after `input_json_delta` finishes. We log the stop and
    # let the next assistant message signal completion.
    emit_message(on_message, :notification,
      %{payload: raw, raw: Jason.encode!(raw), content_block_stop: index}, session.metadata)
    :ok
  end

  defp handle_stream_event(%{"type" => "message_delta"} = event, raw, session, on_message) do
    usage = get_in(event, ["usage"]) || %{}
    metadata = maybe_set_usage(session.metadata, event)
    emit_message(on_message, :notification, %{payload: raw, raw: Jason.encode!(raw), usage: usage}, metadata)
    :ok
  end

  defp handle_stream_event(_event, raw, session, on_message) do
    emit_message(on_message, :notification, %{payload: raw, raw: Jason.encode!(raw)}, session.metadata)
    :ok
  end

  defp append_partial(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, Map.put(v, :input, v[:input] <> "")} end)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    case Map.get(payload, "usage") do
      %{} = usage -> Map.put(metadata, :usage, usage)
      _ -> metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp send_user_message(port, prompt) do
    msg = %{
      "type" => "user",
      "message" => %{
        "role" => "user",
        "content" => prompt
      }
    }

    Port.command(port, Jason.encode!(msg) <> "\n")
  end

  defp stop_port(nil), do: :ok
  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok
end
