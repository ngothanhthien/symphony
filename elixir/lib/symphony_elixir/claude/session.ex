defmodule SymphonyElixir.Claude.Session do
  @moduledoc """
  Per-session state for a Claude transport run.

  Holds the OS process handle (`port`), the agent's session/thread id, the
  workspace metadata, and any in-flight tool call tracking needed to correlate
  streamed events back to a turn.
  """

  alias SymphonyElixir.Claude.{Sandbox, SessionStore}

  @type t :: %__MODULE__{
          port: port() | nil,
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          approval_policy: term(),
          auto_approve_requests: boolean(),
          thread_sandbox: term(),
          turn_sandbox_policy: map(),
          metadata: map(),
          pending_tool_uses: %{optional(String.t()) => map()},
          turn_id: String.t() | nil,
          resumed: boolean()
        }

  @enforce_keys [:thread_id, :workspace, :approval_policy, :auto_approve_requests]
  defstruct [
    :port,
    :thread_id,
    :workspace,
    :worker_host,
    :approval_policy,
    :auto_approve_requests,
    :thread_sandbox,
    :turn_sandbox_policy,
    :metadata,
    pending_tool_uses: %{},
    turn_id: nil,
    resumed: false
  ]

  @spec new(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    force_new = Keyword.get(opts, :force_new, false)

    {thread_id, resumed} = resolve_thread_id(workspace, force_new, opts)

    with {:ok, spec} <- Sandbox.build(workspace, build_sandbox_opts(thread_id, resumed, opts)) do
      port = open_port(spec)

      metadata =
        base_metadata(port, worker_host)
        |> Map.put(:claude_session_id, thread_id)
        |> maybe_put_resumed(resumed)

      session = %__MODULE__{
        port: port,
        thread_id: thread_id,
        workspace: workspace,
        worker_host: worker_host,
        approval_policy: :bypass,
        auto_approve_requests: true,
        thread_sandbox: :workspace_write,
        turn_sandbox_policy: %{},
        metadata: metadata,
        resumed: resumed
      }

      # Persist the session id immediately so a crash before the first turn
      # completes still leaves a recoverable handle.
      case resumed do
        true -> SessionStore.touch(workspace, thread_id)
        false -> SessionStore.write(workspace, thread_id)
      end

      {:ok, session}
    end
  end

  # --- internals -----------------------------------------------------------

  # If the caller passed a :session_id explicitly, honor it (used by tests
  # and by callers that own the id themselves). Otherwise check the on-disk
  # store; if a previous run left one, resume it. Otherwise mint a new one.
  defp resolve_thread_id(workspace, force_new, opts) do
    explicit = Keyword.get(opts, :session_id)

    cond do
      is_binary(explicit) and explicit != "" ->
        {explicit, Keyword.get(opts, :resumed, false)}

      force_new ->
        {generate_session_id(), false}

      true ->
        case SessionStore.read(workspace) do
          %{thread_id: id} -> {id, true}
          nil -> {generate_session_id(), false}
        end
    end
  end

  defp build_sandbox_opts(thread_id, true, _opts), do: [resume: thread_id]
  defp build_sandbox_opts(thread_id, false, _opts), do: [session_id: thread_id]

  defp maybe_put_resumed(metadata, true), do: Map.put(metadata, :claude_session_resumed, true)
  defp maybe_put_resumed(metadata, false), do: metadata

  defp open_port(%{binary: binary, args: args, env: env, cd: cd}) do
    Port.open(
      {:spawn_executable, String.to_charlist(binary)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: Enum.map(args, &String.to_charlist/1),
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end),
        cd: (cd && String.to_charlist(cd)) || :undefined
      ]
    )
  end

  defp base_metadata(port, worker_host) do
    pid =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> to_string(os_pid)
        _ -> nil
      end

    base = %{claude_app_server_pid: pid}
    if worker_host, do: Map.put(base, :worker_host, worker_host), else: base
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16)
    |> binary_to_hex()
    |> format_uuid()
  end

  defp binary_to_hex(bytes), do: Base.encode16(bytes, case: :lower)

  defp format_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  @spec record_tool_use(t(), String.t(), map()) :: t()
  def record_tool_use(%__MODULE__{} = session, tool_use_id, info) do
    update_in(session.pending_tool_uses[tool_use_id], fn
      nil -> info
      existing -> Map.merge(existing, info)
    end)
  end

  @spec pop_tool_use(t(), String.t()) :: {map() | nil, t()}
  def pop_tool_use(%__MODULE__{} = session, tool_use_id) do
    case Map.pop(session.pending_tool_uses, tool_use_id) do
      {nil, _} -> {nil, session}
      {info, remaining} -> {info, %{session | pending_tool_uses: remaining}}
    end
  end

  @spec set_turn_id(t(), String.t()) :: t()
  def set_turn_id(%__MODULE__{} = session, turn_id) do
    %{session | turn_id: turn_id}
  end
end
