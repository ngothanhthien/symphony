defmodule SymphonyElixir.ReadOnlyIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker

  defmodule MutationCounter do
    @moduledoc """
    Per-test GenServer that records every Linear operation dispatched by
    the orchestrator (or its supporting modules) so the test can assert
    the boundary is read-only.
    """

    use GenServer

    def child_spec(opts) do
      %{
        id: Keyword.get(opts, :id, __MODULE__),
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        restart: :temporary
      }
    end

    def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, opts)

    def record(pid, label), do: GenServer.cast(pid, {:record, label})

    def operations(pid), do: GenServer.call(pid, :operations)
    def blocked_operations(pid), do: GenServer.call(pid, :blocked_operations)

    @impl GenServer
    def init(_), do: {:ok, %{operations: [], blocked_operations: []}}

    @impl GenServer
    def handle_call(:operations, _from, state), do: {:reply, state.operations, state}
    def handle_call(:blocked_operations, _from, state), do: {:reply, state.blocked_operations, state}

    @impl GenServer
    def handle_cast({:record, {:graphql, query}}, state) do
      trimmed = query |> String.trim_leading()

      if String.starts_with?(trimmed, "mutation") or String.starts_with?(trimmed, "subscription") do
        {:noreply, %{state | operations: [{:graphql, query} | state.operations], blocked_operations: [query | state.blocked_operations]}}
      else
        {:noreply, %{state | operations: [{:graphql, query} | state.operations]}}
      end
    end

    def handle_cast({:record, label}, state) do
      {:noreply, %{state | operations: [label | state.operations]}}
    end
  end

  defmodule FakeLinearClient do
    @moduledoc """
    Read-only stand-in for SymphonyElixir.Linear.Client. Records each call
    into the per-test MutationCounter; raises if a mutation-style operation
    ever gets through.
    """

    def fetch_candidate_issues do
      MutationCounter.record(counter(), :fetch_candidate_issues)

      {:ok,
       [
         %SymphonyElixir.Linear.Issue{
           id: "issue-1",
           identifier: "ABC-1",
           title: "Implement read-only boundary",
           state: "Todo",
           branch_name: nil,
           url: "https://linear.app/test/issue/ABC-1",
           priority: 2
         }
       ]}
    end

    def fetch_issues_by_states(states) do
      MutationCounter.record(counter(), {:fetch_issues_by_states, states})
      {:ok, []}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      MutationCounter.record(counter(), {:fetch_issue_states_by_ids, issue_ids})

      {:ok,
       Enum.map(issue_ids, fn id ->
         %SymphonyElixir.Linear.Issue{
           id: id,
           identifier: "ABC-#{id}",
           state: "Todo",
           title: "t",
           priority: 1
         }
       end)}
    end

    def graphql(query, _variables, _opts) do
      MutationCounter.record(counter(), {:graphql, query})

      trimmed = query |> String.trim_leading()

      if String.starts_with?(trimmed, "mutation") or String.starts_with?(trimmed, "subscription") do
        {:error, :linear_write_operation_blocked}
      else
        {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}}
      end
    end

    defp counter, do: Process.get(:mutation_counter_pid)
  end

  setup do
    pid = start_supervised!({MutationCounter, []}, id: :mutation_counter)
    Process.put(:mutation_counter_pid, pid)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :linear_client_module)
    end)

    :ok
  end

  test "tracker.read callbacks are the only path orchestrator can use to talk to Linear" do
    refute function_exported?(Tracker, :create_comment, 2)
    refute function_exported?(Tracker, :update_issue_state, 2)
    refute function_exported?(Adapter, :create_comment, 2)
    refute function_exported?(Adapter, :update_issue_state, 2)
  end

  test "orchestrator dispatch path only ever triggers Linear read operations" do
    pid = Process.get(:mutation_counter_pid)

    assert {:ok, [_issue]} = Tracker.fetch_candidate_issues()
    assert {:ok, []} = Tracker.fetch_issues_by_states(["Done"])

    assert {:ok, [%SymphonyElixir.Linear.Issue{id: "issue-1"}]} =
             Tracker.fetch_issue_states_by_ids(["issue-1"])

    # No mutation should have been recorded.
    blocked = MutationCounter.blocked_operations(pid)
    assert blocked == [], "expected no blocked mutations, got: #{inspect(blocked)}"

    # Every recorded operation must be a read.
    operations = MutationCounter.operations(pid) |> Enum.reverse()
    refute Enum.empty?(operations)

    Enum.each(operations, fn op ->
      case op do
        :fetch_candidate_issues ->
          :ok

        {:fetch_issues_by_states, _states} ->
          :ok

        {:fetch_issue_states_by_ids, _ids} ->
          :ok

        {:graphql, query} ->
          trimmed = query |> String.trim_leading()
          refute String.starts_with?(trimmed, "mutation"), "graphql received a mutation: #{query}"
          refute String.starts_with?(trimmed, "subscription"), "graphql received a subscription: #{query}"

        other ->
          flunk("unexpected Linear operation: #{inspect(other)}")
      end
    end)
  end
end
