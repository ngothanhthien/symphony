defmodule Mix.Tasks.Prompt.Lint do
  use Mix.Task

  alias SymphonyElixir.PromptLint

  @moduledoc """
  Lints the Symphony workflow markdown file(s) to make sure the
  Claude-facing prompt is consistent with Symphony's read-only boundary
  with the Harness.

  The lint enforces two complementary rules on `WORKFLOW.harness-claude-runner.md`:

    1. The prompt must include every required phrase (e.g. a hard rule
       against manually editing Linear comments).
    2. The prompt must NOT include any forbidden phrase that would
       regress to a direct-Linear-writer posture (e.g. "Codex Workpad",
       "commentCreate", "issueUpdate", "Linear MCP").

  Pass `paths:` to lint a different file or glob.
  """
  @shortdoc "Fails when a workflow prompt regresses to direct Linear writes"

  @switches [paths: :keep]
  @default_paths ["WORKFLOW.harness-claude-runner.md"]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)

    paths = Keyword.get_values(opts, :paths)
    scanned_paths = if paths == [], do: @default_paths, else: paths

    findings = PromptLint.findings(scanned_paths)

    if findings == [] do
      Mix.shell().info("prompt.lint: workflow is consistent with read-only boundary")
      :ok
    else
      Enum.each(findings, fn finding ->
        message =
          case finding.kind do
            :forbidden_phrase ->
              "#{finding.file}:#{finding.line || "?"} contains forbidden phrase #{inspect(finding.phrase)}"

            :missing_required_phrase ->
              "#{finding.file} is missing required phrase #{inspect(finding.phrase)}"
          end

        Mix.shell().error(message)
      end)

      Mix.raise("prompt.lint failed with #{length(findings)} finding(s)")
    end
  end
end
