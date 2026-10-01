defmodule Aethrion.Simulator do
  @moduledoc """
  Plays a story along routes, to see where each one ends: the tool for
  balancing endings. A route is a daily routine written the way a player
  chats, one line per line, read by `Aethrion.Interpreter` like any chat:

      오늘은 같이 그림 그리자
      네 그림 진짜 좋다
      3일마다: 내일은 좀 쉬자
      10일째: 너 주려고 물감 사 왔어

  Plain lines are said every day; `N일마다:` (or `every N:`) lines every Nth
  day, and `N일째:` (or `day N:`) lines on that day only. When a day's lines
  did not move the clock (no activity took time), a day passes at its end.
  A fight cast plays the same way, a round a day. The route stops when the
  story reaches its ending, or after `days`.

  Everything is deterministic, so a route reaches the same ending on the
  same day every time, and changing a number in the cast shows its effect
  at once.
  """

  alias Aethrion.{Event, Interpreter, Runtime, State, Story}

  @max_days 120
  @max_lines 30

  @type route :: %{name: String.t(), to: String.t(), days: pos_integer(), script: String.t()}

  @doc """
  Runs each route from `state` and returns, per route: the ending reached
  (or `nil`) and its day, where `to` stands with the player at the end, the
  closest endings with what is missing, the milestones reached, and the
  last lines said. Options go to `Aethrion.Interpreter.read/5`.
  """
  @spec run(State.t(), [route()], keyword()) :: [map()]
  def run(%State{} = state, routes, opts \\ []), do: Enum.map(routes, &run_route(state, &1, opts))

  @doc "Parses a route's script into `{:daily | {:every, n} | {:on, day}, line}` pairs."
  @spec parse(String.t()) :: [{term(), String.t()}]
  def parse(script) do
    script
    |> String.split(~r/\R/u, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.take(@max_lines)
    |> Enum.map(fn line ->
      cond do
        match = Regex.run(~r/^(\d+)\s*일\s*마다\s*:\s*(.+)$|^every\s+(\d+)\s*:\s*(.+)$/iu, line) ->
          [n, text] = Enum.reject(tl(match), &(&1 == ""))
          {{:every, max(String.to_integer(n), 1)}, text}

        match = Regex.run(~r/^(\d+)\s*일\s*째\s*:\s*(.+)$|^day\s+(\d+)\s*:\s*(.+)$/iu, line) ->
          [n, text] = Enum.reject(tl(match), &(&1 == ""))
          {{:on, String.to_integer(n)}, text}

        true ->
          {:daily, line}
      end
    end)
  end

  defp run_route(state, route, opts) do
    script = parse(Map.get(route, :script, ""))
    to = Map.get(route, :to)
    days = route |> Map.get(:days, 30) |> min(@max_days) |> max(1)

    # A model reads each distinct line once; the readings are reused on
    # later days (and asked again only if they no longer apply).
    Process.put(:aethrion_simulator_readings, %{})

    {final, log, problems, day} =
      Enum.reduce_while(1..days, {state, [], [], 0}, fn day, {state, log, problems, _} ->
        clock = state.clock

        {state, log, problems} =
          script
          |> Enum.filter(fn {when_, _line} -> today?(when_, day) end)
          |> Enum.reduce({state, log, problems}, fn {_when, line}, acc ->
            say(acc, to, line, day, opts)
          end)

        state = if state.clock == clock, do: pass_day(state, day), else: state

        if Aethrion.Rules.Ending.reached?(state),
          do: {:halt, {state, log, problems, day}},
          else: {:cont, {state, log, problems, day}}
      end)

    relationship = State.get_relationship(final, to, "user")

    %{
      name: Map.get(route, :name, "route"),
      ending: ending(final),
      day: day,
      with_player: %{
        affinity: relationship.affinity,
        trust: relationship.trust,
        tension: relationship.tension,
        bond: Aethrion.Rules.Bond.derive(relationship, final)
      },
      stats: Map.get(final.stats, to, %{}),
      closest:
        final
        |> Story.progress(Keyword.get(opts, :locale, :en))
        |> Enum.sort_by(&(-&1.closeness))
        |> Enum.take(3)
        |> Enum.map(&Map.take(&1, [:id, :title, :closeness, :missing])),
      milestones: Aethrion.Rules.Milestone.reached(final),
      log: Enum.take(log, -12),
      problems: Enum.take(problems, 5)
    }
  end

  defp today?(:daily, _day), do: true
  defp today?({:every, n}, day), do: rem(day, n) == 0
  defp today?({:on, n}, day), do: n == day

  defp say({state, log, problems}, to, line, day, opts) do
    cache = Process.get(:aethrion_simulator_readings, %{})

    case Map.fetch(cache, {to, line}) do
      {:ok, readings} ->
        case apply_readings(readings, {state, log, []}, line, day) do
          {state, log, []} -> {state, log, problems}
          _stale -> fresh({state, log, problems}, to, line, day, opts)
        end

      :error ->
        fresh({state, log, problems}, to, line, day, opts)
    end
  end

  defp fresh({state, log, problems}, to, line, day, opts) do
    {:ok, readings, _meta} = Interpreter.read(state, "user", to, line, opts)
    cache = Process.get(:aethrion_simulator_readings, %{})
    Process.put(:aethrion_simulator_readings, Map.put(cache, {to, line}, readings))
    {state, log, new_problems} = apply_readings(readings, {state, log, []}, line, day)
    {state, log, problems ++ new_problems}
  end

  defp apply_readings(readings, acc, line, day) do
    Enum.reduce(readings, acc, fn %{as: as, event: event}, {state, log, problems} ->
      case Runtime.step(state, event) do
        {:ok, step} ->
          {step.state, log ++ ["#{day}일째 · #{line} → #{as}" <> outcome(step)], problems}

        {:error, error} ->
          {state, log, problems ++ ["#{day}일째 · #{line}: #{error.message}"]}
      end
    end)
  end

  defp outcome(step) do
    case Enum.find(step.outputs, &(&1.type in [:ending_reached, :milestone_reached])) do
      %{type: :ending_reached, title: title} -> " ★ " <> title
      %{type: :milestone_reached, title: title} -> " ♥ " <> title
      nil -> ""
    end
  end

  defp pass_day(state, day) do
    case Runtime.step(state, Event.time_tick("day #{day}", hours: 24)) do
      {:ok, step} -> step.state
      {:error, _} -> state
    end
  end

  defp ending(state) do
    case Aethrion.Rules.Ending.reached(state) do
      nil -> nil
      ending -> Map.take(ending, [:id, :title, :description])
    end
  end
end
