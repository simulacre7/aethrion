defmodule Mix.Tasks.Aethrion.Journal do
  @shortdoc "Replays an event journal"

  @moduledoc """
  Replays an `Aethrion.Journal` and summarizes the rebuilt world, optionally
  exporting it as a scenario or an HTML report.

      mix aethrion.journal tmp/world.jsonl
      mix aethrion.journal tmp/world.jsonl --scenario tmp/world.json
      mix aethrion.journal tmp/world.jsonl --report tmp/world.html
      mix aethrion.journal tmp/world.jsonl --compact --archive tmp/world-2026-10.jsonl
      mix aethrion.journal tmp/world.jsonl --digest --locale ko

  `--digest` also prints what happened, as `Aethrion.Digest` lines (in
  Korean with `--locale ko`).

  `--compact` replaces the journal with one that starts from the replayed
  state (see `Aethrion.Journal.compact/2`); `--archive FILE` keeps a copy of
  the old one first. Exports run before compacting. Pass `--max-depth` and
  `--max-events` if the world runs with non-default cascade limits. Journals
  of worlds with custom rules need their pipeline, so compact those from code
  with `Aethrion.Journal.compact/2` or, while the world runs,
  `Aethrion.World.compact_journal/1`; never compact a journal a running server
  is appending to.

  Replaying proves the journal is consistent: every event must be accepted and
  receive the same id it was recorded with.
  """

  use Mix.Task

  alias Aethrion.{Journal, Report, Scenario}
  alias Aethrion.CLI.Display

  @switches [
    scenario: :string,
    report: :string,
    compact: :boolean,
    archive: :string,
    max_depth: :integer,
    max_events: :integer,
    digest: :boolean,
    locale: :string
  ]

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
    case Journal.replay(path, limits(opts)) do
      {:ok, state, steps} ->
        processed = Enum.sum(Enum.map(steps, &length(&1.events)))

        Display.heading(
          "Journal #{Path.basename(path)}",
          "#{count(length(steps), "host event")} replayed (#{processed} with cascades), clock #{state.clock}h"
        )

        Display.status(state)
        if opts[:digest], do: digest(steps, state, opts)
        export(path, opts)
        compact(path, opts)

      {:error, error} ->
        Mix.raise("could not replay #{path}: #{Aethrion.Error.format(error)}")
    end
  end

  defp export(path, opts) do
    if opts[:scenario] || opts[:report] do
      {:ok, data} = Journal.to_scenario(path, limits(opts))

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
    if opts[:compact] do
      case Journal.compact(path, Keyword.take(opts, [:archive]) ++ limits(opts)) do
        {:ok, _state, count} -> Display.message(compacted(path, count, opts[:archive]))
        {:error, error} -> Mix.raise("could not compact #{path}: #{Aethrion.Error.format(error)}")
      end
    end
  end

  defp compacted(path, count, archive) do
    kept = if archive, do: "; the old journal is at #{archive}", else: ""
    "compacted #{count(count, "event")} into the starting state of #{path}#{kept}"
  end

  defp digest(steps, state, opts) do
    locale =
      case opts[:locale] do
        nil -> :en
        "en" -> :en
        "ko" -> :ko
        other -> Mix.raise("unsupported locale #{inspect(other)}; use en or ko")
      end

    steps
    |> Enum.flat_map(& &1.outputs)
    |> Aethrion.Digest.of(state, locale: locale)
    |> Display.digest("everything the journal records")
  end

  defp limits(opts), do: Keyword.take(opts, [:max_depth, :max_events])

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
