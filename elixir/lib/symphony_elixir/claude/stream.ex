defmodule SymphonyElixir.Claude.Stream do
  @moduledoc """
  Line-buffered JSON stream reader for the Claude CLI (`-p` + `stream-json`).

  Accumulates partial lines, parses one JSON object per line, and dispatches
  to a caller-supplied callback. Malformed lines are logged and dropped (the
  CLI can emit non-JSON chatter on stdout/stderr).
  """

  require Logger

  @max_log_bytes 1_000

  @type callback :: (map() -> :ok | {:ok, term()} | {:halt, term()})

  @doc """
  Drain `port` until either the callback returns `{:halt, value}` (returned as
  `{:halt, value}`) or `timeout_ms` elapses (returns `{:error, :timeout}`).

  The callback receives the decoded JSON object as a map with atom keys where
  possible (we keep both string and atom keys: `Jason.decode/1` returns
  string-keyed maps, which is what we preserve here for fidelity to the
  upstream protocol).
  """
  @spec drain(port(), pos_integer(), callback()) ::
          {:halt, term()} | {:error, :port_exit | :timeout | term()}
  def drain(port, timeout_ms, callback) do
    receive_line(port, timeout_ms, "", callback)
  end

  defp receive_line(port, timeout_ms, pending, callback) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending <> to_string(chunk)
        handle_line(port, timeout_ms, line, callback)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_line(port, timeout_ms, pending <> to_string(chunk), callback)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :timeout}
    end
  end

  defp handle_line(port, timeout_ms, line, callback) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) ->
        case callback.(payload) do
          :ok -> receive_line(port, timeout_ms, "", callback)
          {:ok, _} -> receive_line(port, timeout_ms, "", callback)
          {:halt, value} -> {:halt, value}
        end

      {:error, _reason} ->
        log_non_json(line)
        receive_line(port, timeout_ms, "", callback)
    end
  end

  defp log_non_json(line) do
    text =
      line
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude stream output: #{text}")
      else
        Logger.debug("Claude stream output: #{text}")
      end
    end
  end
end
