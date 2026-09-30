defmodule Mix.Tasks.Aethrion.Scenario do
  @shortdoc "Runs scenario files and checks their expectations"

  @moduledoc """
  Runs one or more scenario files and checks their expectations.

      mix aethrion.scenario priv/scenarios/01_the_flower.json
      mix aethrion.scenario --all
      mix aethrion.scenario my_scenario.json --quiet
      mix aethrion.scenario my_scenario.json --json

  Options:

  - `--all` - run every bundled scenario
  - `--quiet` - only print expectation results
  - `--json` - print the final state, outputs, and checks as JSON

  Exits with a non-zero status when any expectation fails.
  """

  use Mix.Task

  alias Aethrion.CLI.Display
  alias Aethrion.{Output, Scenario, State}

  @switches [all: :boolean, quiet: :boolean, json: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, paths, _invalid} = OptionParser.parse(args, strict: @switches)

    paths = if opts[:all], do: Scenario.bundled(), else: paths

    if paths == [] do
      Mix.raise("usage: mix aethrion.scenario PATH [PATH...] | --all")
    end

    results = Enum.map(paths, &run_one(&1, opts))

    unless Enum.all?(results), do: exit({:shutdown, 1})
  end

  defp run_one(path, opts) do
    with {:ok, scenario} <- Scenario.load(path),
         {:ok, result} <- Scenario.run(scenario) do
      if opts[:json] do
        IO.puts(Jason.encode!(json(result), pretty: true))
      else
        print(result, opts)
      end

      Scenario.passed?(result)
    else
      {:error, {index, %Aethrion.Error{} = error}} ->
        Display.error(error)
        Mix.shell().error("event #{index} in #{path} was rejected")
        false

      {:error, reason} ->
        Mix.shell().error("could not load #{path}: #{inspect(reason)}")
        false
    end
  end

  defp print(result, opts) do
    scenario = result.scenario
    Display.heading(scenario.name, scenario.description)

    unless opts[:quiet] do
      Enum.each(result.steps, fn step ->
        Display.event(step.event, step.state)
        Enum.each(step.log, &Display.log/1)
      end)
    end

    Display.checks(result.checks)
  end

  defp json(result) do
    %{
      name: result.scenario.name,
      passed: Scenario.passed?(result),
      state: State.to_data(result.state),
      outputs:
        result.outputs
        |> Enum.filter(&Output.expressive?/1)
        |> Enum.map(
          &Map.take(&1, [:type, :character_id, :from, :to, :reason, :kind, :text, :event_id])
        ),
      checks:
        Enum.map(result.checks, fn check ->
          %{description: check.description, passed: check.passed?, actual: inspect(check.actual)}
        end)
    }
  end
end
