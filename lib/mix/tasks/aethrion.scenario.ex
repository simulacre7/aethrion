defmodule Mix.Tasks.Aethrion.Scenario do
  @shortdoc "Runs scenario files and checks their expectations"

  @moduledoc """
  Runs one or more scenario files and checks their expectations.

      mix aethrion.scenario priv/scenarios/01_the_flower.json
      mix aethrion.scenario --all
      mix aethrion.scenario my_scenario.json --quiet
      mix aethrion.scenario my_scenario.json --json
      mix aethrion.scenario test/scenarios/favorite_gift.json --pipeline MyGame.Rules.pipeline

  Options:

  - `--all` - run every bundled scenario
  - `--quiet` - only print expectation results
  - `--json` - print the final state, outputs, and checks as JSON
  - `--pipeline Module.function` - run with the `Aethrion.Pipeline` that
    function returns (it takes no arguments), for scenarios of custom rules

  Exits with a non-zero status when any expectation fails.
  """

  use Mix.Task

  alias Aethrion.CLI.Display
  alias Aethrion.{Output, Scenario, State}

  @switches [all: :boolean, quiet: :boolean, json: :boolean, pipeline: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, paths, _invalid} = OptionParser.parse(args, strict: @switches)

    paths = if opts[:all], do: Scenario.bundled(), else: paths

    if paths == [] do
      Mix.raise("usage: mix aethrion.scenario PATH [PATH...] | --all")
    end

    opts = Keyword.put(opts, :pipeline, pipeline(opts[:pipeline]))
    results = Enum.map(paths, &run_one(&1, opts))
    failed = Enum.count(results, &(!&1))

    if length(results) > 1 and !opts[:json] do
      Display.message(
        if failed == 0,
          do: "\n#{length(results)} scenarios, every expectation met",
          else: "\n#{length(results)} scenarios, #{failed} with unmet expectations or errors"
      )
    end

    unless failed == 0, do: exit({:shutdown, 1})
  end

  defp run_one(path, opts) do
    pipeline = Keyword.take(opts, [:pipeline]) |> Enum.reject(&match?({_, nil}, &1))

    with {:ok, scenario} <- Scenario.load(path, pipeline),
         {:ok, result} <- Scenario.run(scenario, pipeline) do
      if opts[:json] do
        IO.puts(Jason.encode!(json(result), pretty: true))
      else
        print(result, opts)
      end

      Scenario.passed?(result)
    else
      {:error, %Aethrion.Error{} = error} ->
        Display.error(error)
        Mix.shell().error("in #{path}")
        false
    end
  end

  defp pipeline(nil), do: nil

  # "MyGame.Rules.pipeline": a module that already exists and a function of
  # no arguments on it, so no atoms are made from input.
  defp pipeline(spec) do
    with [module_name, function_name] <- String.split(spec, ~r/\.(?=[^.]+$)/),
         module when is_atom(module) <- existing_atom("Elixir." <> module_name),
         {:module, _} <- Code.ensure_loaded(module),
         function when is_atom(function) <- existing_atom(function_name),
         true <- function_exported?(module, function, 0),
         %Aethrion.Pipeline{} = pipeline <- safe_apply(module, function) do
      pipeline
    else
      _other ->
        Mix.raise("--pipeline #{spec}: expected Module.function returning an Aethrion.Pipeline")
    end
  end

  defp safe_apply(module, function) do
    apply(module, function, [])
  rescue
    _error -> nil
  end

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp print(result, opts) do
    scenario = result.scenario
    Display.heading(scenario.name, scenario.description)

    unless opts[:quiet] do
      print_steps(result.steps, result.scenario.state)

      Enum.each(result.branches, fn branch ->
        Display.heading("Branch: #{branch.name}", branch.description)
        print_steps(branch.steps, result.state)
      end)
    end

    result
    |> Scenario.all_checks()
    |> Enum.map(fn
      %{branch: nil} = check -> check
      check -> %{check | description: "[#{check.branch}] #{check.description}"}
    end)
    |> Display.checks()
  end

  defp print_steps(steps, initial) do
    Enum.reduce(steps, initial, fn step, before ->
      Display.event(step.event, before)
      Enum.each(step.log, &Display.log/1)
      step.state
    end)
  end

  defp json(result) do
    %{
      name: result.scenario.name,
      passed: Scenario.passed?(result),
      state: State.to_data(result.state),
      outputs:
        result.outputs
        |> Enum.filter(&Output.expressive?/1)
        |> Enum.map(&Map.take(&1, [:type, :character_id, :to, :reason, :kind, :text, :event_id])),
      branches:
        Enum.map(result.branches, fn branch ->
          %{name: branch.name, state: State.to_data(branch.state)}
        end),
      checks:
        Enum.map(Scenario.all_checks(result), fn check ->
          %{
            branch: check.branch,
            description: check.description,
            passed: check.passed?,
            actual: inspect(check.actual)
          }
        end)
    }
  end
end
