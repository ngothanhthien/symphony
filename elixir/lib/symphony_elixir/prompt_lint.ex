defmodule SymphonyElixir.PromptLint do
  @moduledoc """
  Lints workflow markdown files to prevent the orchestrator from regressing
  into a direct-Linear-writer posture.

  Two rules:

    * A workflow is `valid` only if it requires every line in
      `@required_phrases` somewhere in the prompt body and contains none
      of the strings in `@forbidden_phrases`.

    * Forbidden phrases are read-only triggers: anything that suggests the
      Claude process should perform a write to Linear directly. The list
      is intentionally conservative so a near-miss still trips the lint.

  ## Convention: forbidden phrases are forbidden everywhere

  The forbidden-phrase check is a plain `String.contains?/2` over the
  whole file. There is no negation handling: writing
  "Do not use `linear_graphql`" will trip the lint just as the positive
  form would.

  This is intentional. A workflow that needs to mention a forbidden token
  to *forbid* it is a regression risk — the next reader may copy the
  phrase into a positive instruction. If you need to forbid something,
  say so using language that does not contain the forbidden token itself
  (e.g. "Do not use raw GraphQL, curl, gh extensions, or any direct
  Linear API call" rather than naming the tool by its trigger string).

  A workflow that fails the lint should be treated as a violation of the
  read-only boundary between Symphony and Harness.
  """

  @forbidden_phrases [
    "Codex Workpad",
    "linear_graphql",
    "Linear MCP",
    "commentCreate",
    "issueUpdate",
    "create a Linear issue",
    "move Linear issue",
    "transition Linear issue directly"
  ]

  @required_phrases [
    "harness-cli",
    "Symphony is read-only orchestration",
    "Do not manually edit Linear comments",
    "Do not manually transition Linear status",
    "All Linear writes must go through"
  ]

  @type finding :: %{
          file: Path.t(),
          kind: :forbidden_phrase | :missing_required_phrase,
          phrase: String.t(),
          line: pos_integer() | nil
        }

  @spec findings([Path.t()]) :: [finding()]
  def findings(paths \\ ["WORKFLOW.harness-claude-runner.md"]) do
    paths
    |> Enum.flat_map(&expand_workflow_files/1)
    |> Enum.flat_map(&file_findings/1)
    |> Enum.sort_by(&{&1.file, &1.kind, &1.phrase})
  end

  defp expand_workflow_files(pattern) do
    cond do
      File.regular?(pattern) -> [pattern]
      String.contains?(pattern, "*") -> Path.wildcard(pattern)
      File.dir?(pattern) -> Path.wildcard(Path.join(pattern, "WORKFLOW*.md"))
      true -> []
    end
  end

  defp file_findings(file) do
    case File.read(file) do
      {:ok, content} ->
        forbidden_findings(file, content) ++ missing_required_findings(file, content)

      {:error, reason} ->
        Mix.raise("prompt_lint: unable to read #{file}: #{inspect(reason)}")
    end
  end

  defp forbidden_findings(file, content) do
    @forbidden_phrases
    |> Enum.flat_map(fn phrase ->
      case find_phrase_line(content, phrase) do
        nil -> []
        line -> [%{file: file, kind: :forbidden_phrase, phrase: phrase, line: line}]
      end
    end)
  end

  defp missing_required_findings(file, content) do
    @required_phrases
    |> Enum.flat_map(fn phrase ->
      if String.contains?(content, phrase) do
        []
      else
        [%{file: file, kind: :missing_required_phrase, phrase: phrase, line: nil}]
      end
    end)
  end

  defp find_phrase_line(content, phrase) do
    content
    |> String.split(~r/\R/)
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, idx} ->
      if String.contains?(line, phrase), do: idx
    end)
  end
end
