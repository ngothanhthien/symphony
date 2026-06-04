defmodule SymphonyElixir.PromptLintTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PromptLint

  @workflow_path "WORKFLOW.harness-claude-runner.md"

  describe "findings/1" do
    test "canonical harness-claude workflow file is lint-clean" do
      assert PromptLint.findings([@workflow_path]) == []
    end

    test "flags forbidden phrases that would regress to direct Linear writes" do
      forbidden_samples = [
        "Always open a Codex Workpad bootstrap comment first.",
        "Use the linear_graphql tool to fetch the issue.",
        "Configure the Linear MCP server before starting.",
        "Call commentCreate to add a progress note.",
        "Call issueUpdate to transition the state.",
        "Then create a Linear issue for the follow-up work.",
        "When finished, move Linear issue to Human Review.",
        "Make sure to transition Linear issue directly when the PR merges."
      ]

      for sample <- forbidden_samples do
        path = write_temp_workflow(sample)
        findings = PromptLint.findings([path])

        assert Enum.any?(findings, &(&1.kind == :forbidden_phrase)),
               "expected forbidden finding for sample: #{inspect(sample)}"
      end
    end

    test "flags missing required phrases" do
      bare = "---\ntracker:\n  kind: linear\n---\n\nSome prompt without the required boundary statements.\n"
      path = write_temp_workflow(bare)
      findings = PromptLint.findings([path])

      assert Enum.any?(findings, &(&1.kind == :missing_required_phrase))

      required = [
        "harness-cli",
        "Symphony is read-only orchestration",
        "Do not manually edit Linear comments",
        "Do not manually transition Linear status",
        "All Linear writes must go through"
      ]

      for phrase <- required do
        assert Enum.any?(findings, fn f -> f.kind == :missing_required_phrase and f.phrase == phrase end),
               "expected missing-required finding for #{inspect(phrase)}"
      end
    end
  end

  defp write_temp_workflow(content) do
    dir = Path.join(System.tmp_dir!(), "symphony-prompt-lint-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "WORKFLOW.harness-claude-runner.md")
    File.write!(path, content)
    path
  end
end
