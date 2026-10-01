defmodule Mix.Tasks.Aethrion.Interpret.Eval do
  @shortdoc "Scores an interpreter on labeled chat lines"
  @moduledoc """
  Scores how well an interpreter reads what chat lines do
  (`Aethrion.Interpreter.Eval`):

      mix aethrion.interpret.eval
      mix aethrion.interpret.eval --file priv/eval/interpret.ko.json --failures
      mix aethrion.interpret.eval --interpreter MyApp.JevInterpreter

  Options: `--file` (default `priv/eval/interpret.ko.json`), `--interpreter`
  (a module implementing `Aethrion.Interpreter`; default the rules),
  `--failures` (list every case read wrong), `--min SCORE` (exit non-zero
  below it, for CI).
  """

  use Mix.Task

  @switches [file: :string, interpreter: :string, failures: :boolean, min: :float]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    file = opts[:file] || "priv/eval/interpret.ko.json"
    {:ok, cases} = Aethrion.Interpreter.Eval.load(file)

    interpreter =
      case opts[:interpreter] do
        nil -> Aethrion.Interpreter.Rules
        name -> Module.concat([name])
      end

    report = Aethrion.Interpreter.Eval.run(cases, interpreter: interpreter)
    shell = Mix.shell()

    shell.info(
      "#{inspect(interpreter)} on #{file}: #{report.passed}/#{report.total} (#{percent(report.score)})"
    )

    for {name, t} <- Enum.sort(report.by_as),
        do: shell.info("  as #{name}: #{t.passed}/#{t.total}")

    for {name, t} <- Enum.sort(report.by_cast),
        do: shell.info("  cast #{name}: #{t.passed}/#{t.total}")

    if opts[:failures] do
      shell.info("\nRead wrong:")

      for f <- report.failures do
        shell.info("  #{f.case["id"]} #{inspect(f.case["text"])}")
        shell.info("    want #{Jason.encode!(f.case["expect"])}")

        shell.info(
          "    got  #{Jason.encode!(Enum.map(f.got, &Map.reject(&1, fn {_k, v} -> v == nil end)))}"
        )
      end
    end

    if opts[:min] && report.score < opts[:min],
      do: Mix.raise("score #{report.score} is below --min #{opts[:min]}")
  end

  defp percent(score), do: "#{Float.round(score * 100, 1)}%"
end
