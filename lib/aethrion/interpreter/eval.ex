defmodule Aethrion.Interpreter.Eval do
  @moduledoc """
  Measures an interpreter against labeled chat lines
  (`priv/eval/interpret.ko.json`): each case names a cast, whom the line is
  said to, optional stat overrides, the text, and what a person means by it
  (one reading, or several in order). Only the keys a label gives are
  compared, so `{"as": "combat", "type": "attack", "to": "wolf"}` passes
  any attack on the wolf.

  `mix aethrion.interpret.eval` prints the score; with another
  interpreter (`--interpreter MyApp.JevInterpreter`) the same cases compare
  them on equal terms.
  """

  alias Aethrion.{Interpreter, State}

  @doc "Loads a labeled set: `{:ok, cases}`."
  @spec load(Path.t()) :: {:ok, [map()]} | {:error, term()}
  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"cases" => cases}} when is_list(cases) <- Jason.decode(body) do
      {:ok, cases}
    else
      {:ok, _other} -> {:error, :no_cases}
      error -> error
    end
  end

  @doc """
  Runs `cases` and returns `%{total, passed, score, by_cast, by_as,
  failures}`; each failure has the case and what was read. Options go to
  `Aethrion.Interpreter.read/5`, plus `:casts_dir` (default `priv/casts`).
  """
  @spec run([map()], keyword()) :: map()
  def run(cases, opts \\ []) do
    dir = Keyword.get(opts, :casts_dir, "priv/casts")
    casts = cases |> Enum.map(& &1["cast"]) |> Enum.uniq() |> Map.new(&{&1, cast!(dir, &1)})

    results =
      Enum.map(cases, fn c ->
        state = setup(casts[c["cast"]], Map.get(c, "setup", %{}))
        {:ok, readings, meta} = Interpreter.read(state, "user", c["to"], c["text"], opts)
        got = Enum.map(readings, &summary/1)
        %{case: c, got: got, status: meta.status, pass: matches?(List.wrap(c["expect"]), got)}
      end)

    passed = Enum.count(results, & &1.pass)

    %{
      total: length(results),
      passed: passed,
      score: if(results == [], do: 0.0, else: Float.round(passed / length(results), 3)),
      by_cast: tally(results, & &1.case["cast"]),
      by_as: tally(results, &(&1.case["expect"] |> List.wrap() |> List.last() |> Map.get("as"))),
      failures: Enum.reject(results, & &1.pass),
      results: results
    }
  end

  defp cast!(dir, name) do
    {:ok, state} =
      Path.join(dir, name <> ".json") |> File.read!() |> Jason.decode!() |> State.parse()

    state
  end

  defp setup(state, %{"stats" => stats}) when is_map(stats) do
    Enum.reduce(stats, state, fn {id, values}, state ->
      update_in(state.stats, &Map.update(&1, id, values, fn old -> Map.merge(old, values) end))
    end)
  end

  defp setup(state, _setup), do: state

  # What a reading is, in the label's terms.
  defp summary(%{as: as, event: event}) do
    %{
      "as" => Atom.to_string(as),
      "type" => type(event.type),
      "to" => Map.get(event, :to) || Map.get(event, :character),
      "from" => Map.get(event, :from),
      "tone" => event |> Map.get(:tone) |> then(&(&1 && Atom.to_string(&1))),
      "activity" => Map.get(event, :activity),
      "item" => Map.get(event, :item)
    }
  end

  defp type(:gift_received), do: "gift_received"
  defp type(type), do: Atom.to_string(type)

  defp matches?(expected, got) when length(expected) != length(got), do: false

  defp matches?(expected, got) do
    expected
    |> Enum.zip(got)
    |> Enum.all?(fn {want, have} ->
      Enum.all?(want, fn {key, value} -> have[key] == value end)
    end)
  end

  defp tally(results, key) do
    results
    |> Enum.group_by(key)
    |> Map.new(fn {k, rs} -> {k, %{total: length(rs), passed: Enum.count(rs, & &1.pass)}} end)
  end
end
