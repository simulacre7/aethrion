defmodule Mix.Tasks.Aethrion.Interpret.Eval do
  @shortdoc "Scores an interpreter on labeled chat lines"
  @moduledoc """
  Scores how well an interpreter reads what chat lines do
  (`Aethrion.Interpreter.Eval`):

      mix aethrion.interpret.eval
      mix aethrion.interpret.eval --file priv/eval/interpret.ko.json --failures
      mix aethrion.interpret.eval --llm claude
      mix aethrion.interpret.eval --llm ollama --model qwen3 --limit 40
      mix aethrion.interpret.eval --interpreter MyApp.JevInterpreter

  Options: `--file` (default `priv/eval/interpret.ko.json`), `--llm NAME`
  (read with `Aethrion.Interpreter.LLM` on a backend from
  `Aethrion.LLM.Backend`, with `--model` and `--base-url`), `--interpreter`
  (a module implementing `Aethrion.Interpreter`; default the rules),
  `--limit N` (the first N cases),
  `--failures` (list every case read wrong), `--min SCORE` (exit non-zero
  below it, for CI).
  """

  use Mix.Task

  @switches [
    file: :string,
    interpreter: :string,
    llm: :string,
    model: :string,
    base_url: :string,
    limit: :integer,
    failures: :boolean,
    min: :float
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")

    file = opts[:file] || "priv/eval/interpret.ko.json"
    {:ok, cases} = Aethrion.Interpreter.Eval.load(file)
    cases = if opts[:limit], do: Enum.take(cases, opts[:limit]), else: cases
    {interpreter, interpreter_opts} = interpreter(opts)

    report =
      Aethrion.Interpreter.Eval.run(cases,
        interpreter: interpreter,
        interpreter_opts: interpreter_opts,
        # Score the interpreter itself: no rules standing in when it is unsure.
        min_confidence: 0.0
      )

    fallbacks = Enum.count(report.results, &(&1.status == :fallback))
    shell = Mix.shell()

    shell.info(
      "#{inspect(interpreter)} on #{file}: #{report.passed}/#{report.total} (#{percent(report.score)})" <>
        if(fallbacks > 0, do: ", #{fallbacks} read by the rules after the model failed", else: "")
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

  defp interpreter(opts) do
    cond do
      name = opts[:llm] ->
        case Aethrion.LLM.Backend.resolve(name, model: opts[:model], base_url: opts[:base_url]) do
          {:ok, adapter, adapter_opts, _label} ->
            {Aethrion.Interpreter.LLM, [adapter: adapter, adapter_opts: adapter_opts]}

          {:error, message} ->
            Mix.raise(message)
        end

      name = opts[:interpreter] ->
        {Module.concat([name]), []}

      true ->
        {Aethrion.Interpreter.Rules, []}
    end
  end

  defp percent(score), do: "#{Float.round(score * 100, 1)}%"
end
