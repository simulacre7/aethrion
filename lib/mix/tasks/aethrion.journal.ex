defmodule Mix.Tasks.Aethrion.Journal do
  @shortdoc "Replays an event journal"

  @moduledoc """
  Replays an `Aethrion.Journal` and summarizes the rebuilt world, optionally
  exporting it as a scenario or an HTML report.

      mix aethrion.journal tmp/world.jsonl
      mix aethrion.journal tmp/world.jsonl --scenario tmp/world.json
      mix aethrion.journal tmp/world.jsonl --report tmp/world.html
      mix aethrion.journal tmp/world.jsonl --compact --archive tmp/world-2026-10.jsonl

  `--compact` replaces the journal with one that starts from the replayed
  state (see `Aethrion.Journal.compact/2`); `--archive FILE` keeps a copy of
  the old one first. Exports run before compacting.

  Replaying proves the journal is consistent: every event must be accepted and
  receive the same id it was recorded with.
  """

  use Mix.Task

  alias Aethrion.{Journal, Report, Scenario}
  alias Aethrion.CLI.Display

  @switches [scenario: :string, report: :string, compact: :boolean, archive: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case OptionParser.parse(args, strict: @switches) do
      {opts, [path], []} ->
        if opts[:archive] && !opts[:compact],
          do: Mix.raise("--archive only applies with --compact")

        replay(path, opts)

      _ ->
        Mix.raise(
          "usage: mix aethrion.journal PATH [--scenario FILE] [--report FILE] [--compact [--archive FILE]]"
        )
    end
  end

  defp replay(path, opts) do
    case Journal.replay(path) do
      {:ok, state, steps} ->
        processed = Enum.sum(Enum.map(steps, &length(&1.events)))

        Display.heading(
          "Journal #{Path.basename(path)}",
          "#{length(steps)} host events replayed (#{processed} with cascades), clock #{state.clock}h"
        )

        Display.status(state)
        export(path, opts)
        compact(path, opts)

      {:error, error} ->
        Mix.raise("could not replay #{path}: #{Aethrion.Error.format(error)}")
    end
  end

  defp export(path, opts) do
    if opts[:scenario] || opts[:report] do
      {:ok, data} = Journal.to_scenario(path)

      if out = opts[:scenario] do
        File.mkdir_p!(Path.dirname(out))
        File.write!(out, Jason.encode!(data, pretty: true))
        Display.message("scenario -> #{out}")
      end

      if out = opts[:report] do
        {:ok, scenario} = data |> Jason.encode!() |> Jason.decode!() |> Scenario.from_data()
        {:ok, result} = Scenario.run(scenario)
        File.mkdir_p!(Path.dirname(out))
        File.write!(out, Report.html(result))
        Display.message("report -> #{out}")
      end
    end

    :ok
  end

  defp compact(path, opts) do
    cond do
      opts[:compact] ->
        case Journal.compact(path, Keyword.take(opts, [:archive])) do
          {:ok, _state, count} ->
            kept = if archive = opts[:archive], do: "; the old journal is at #{archive}", else: ""
            Display.message("compacted #{count} events into the starting state of #{path}#{kept}")

          {:error, error} ->
            Mix.raise("could not compact #{path}: #{Aethrion.Error.format(error)}")
        end

      true ->
        :ok
    end
  end
end
