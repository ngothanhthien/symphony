defmodule SymphonyElixir.ConfigSchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Claude

  describe "Claude.expose_linear_api_key" do
    test "default is false" do
      assert %Claude{expose_linear_api_key: false} = %Claude{}
    end

    test "accepts explicit false" do
      assert {:ok, %Claude{expose_linear_api_key: false}} =
               Claude.changeset(%Claude{}, %{"expose_linear_api_key" => false}) |> Ecto.Changeset.apply_action(:validate)
    end

    test "rejects true as an invariant violation" do
      result =
        %Claude{}
        |> Claude.changeset(%{"expose_linear_api_key" => true})
        |> Ecto.Changeset.apply_action(:validate)

      assert {:error, changeset} = result

      assert %{expose_linear_api_key: ["must be false; Symphony is read-only and never passes the Linear token to Claude"]} =
               errors_on(changeset)
    end

    test "the canonical harness-claude workflow file parses with expose_linear_api_key: false" do
      workflow_path =
        Path.expand("../../WORKFLOW.harness-claude-runner.md", __DIR__)

      # Parse just the YAML front matter; the rest of the file is the
      # human-readable prompt and contains prose that confuses a
      # loose YAML parser.
      content = File.read!(workflow_path)
      [front_matter | _] = String.split(content, "---", parts: 3, trim: true)
      raw = YamlElixir.read_from_string!(front_matter)
      cfg = get_in(raw, ["claude"]) || %{}

      assert cfg["expose_linear_api_key"] == false

      assert {:ok, %Claude{expose_linear_api_key: false}} =
               Claude.changeset(%Claude{}, cfg) |> Ecto.Changeset.apply_action(:validate)
    end

    test "Schema.parse at the top level fails when expose_linear_api_key is true" do
      bad = %{
        "tracker" => %{"kind" => "linear", "api_key" => "k", "project_slug" => "p"},
        "claude" => %{"command" => "claude", "expose_linear_api_key" => true}
      }

      assert {:error, {:invalid_workflow_config, message}} = Schema.parse(bad)
      assert message =~ "expose_linear_api_key"
      assert message =~ "must be false"
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
