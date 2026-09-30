defmodule Aethrion.Scenario do
  @moduledoc """
  Data-first scenarios: a world, a script of events, and expectations, all in
  one JSON file.

  Scenarios make social behavior reviewable and testable without writing
  Elixir. `mix aethrion.scenario path.json` runs one and checks its
  expectations; `mix aethrion.report path.json` renders it as an HTML report.

  ```json
  {
    "name": "The flower",
    "description": "Yuna watches the user give Mina a flower, then is ignored.",
    "world": "demo",
    "events": [
      {"type": "gift_received", "from": "user", "to": "mina", "item": "flower", "observed_by": ["yuna"]},
      {"type": "time_tick", "hours": 2}
    ],
    "expect": [
      {"character": "yuna", "field": "mood", "equals": "neutral"},
      {"relationship": ["yuna", "haru"], "field": "trust", "at_least": 45},
      {"output": "proactive_message", "character": "yuna", "reason": "jealous", "count": 1},
      {"memory": {"character": "haru", "kind": "heard"}, "count": 1}
    ]
  }
  ```

  `world` is either `"demo"` or an object with `characters` and
  `relationships` in the persistence format (see `Aethrion.State.to_data/1`).

  An optional `tuning` object overrides rule parameters for this world, for
  example `{"autonomy": {"trust_threshold": 15}}` (see `Aethrion.Tuning`).
  Unknown rules or parameters are rejected.

  Expectations select a value and compare it with one of `equals`,
  `at_least`, or `at_most`. Output and memory expectations count matches;
  without a comparison they pass when at least one matches (`count` is
  shorthand for `equals` on the count).
  """

  alias Aethrion.{Event, Runtime, State}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          state: State.t(),
          events: [map()],
          expectations: [map()],
          path: String.t() | nil
        }

  defstruct name: "Untitled scenario",
            description: "",
            state: nil,
            events: [],
            expectations: [],
            path: nil

  defmodule Result do
    @moduledoc "The outcome of running a scenario."

    @type check :: %{
            expectation: map(),
            description: String.t(),
            passed?: boolean(),
            actual: term()
          }

    @type t :: %__MODULE__{
            scenario: Aethrion.Scenario.t(),
            state: Aethrion.State.t(),
            steps: [Aethrion.Step.t()],
            outputs: [map()],
            checks: [check()]
          }

    defstruct [:scenario, :state, steps: [], outputs: [], checks: []]
  end

  @doc "Loads a scenario from a JSON file."
  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json),
         {:ok, scenario} <- from_data(data) do
      {:ok, %{scenario | path: path}}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_json, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Builds a scenario from decoded JSON data."
  def from_data(%{} = data) do
    with {:ok, state} <- world(Map.get(data, "world", "demo")),
         {:ok, tuning} <- Aethrion.Tuning.from_data(Map.get(data, "tuning")),
         {:ok, events} <- events(Map.get(data, "events", [])),
         {:ok, expectations} <- expectations(Map.get(data, "expect", [])) do
      {:ok,
       %__MODULE__{
         name: Map.get(data, "name", "Untitled scenario"),
         description: Map.get(data, "description", ""),
         state: %{
           state
           | tuning: Map.merge(state.tuning, tuning, fn _rule, a, b -> Map.merge(a, b) end)
         },
         events: events,
         expectations: expectations
       }}
    end
  end

  def from_data(_data), do: {:error, :invalid_scenario}

  @doc """
  Runs the scenario and evaluates its expectations.

  Returns `{:ok, %Result{}}`, or `{:error, {index, error}}` when an event is
  rejected by validation. Options are passed to `Aethrion.Runtime.step/3`.
  """
  def run(%__MODULE__{} = scenario, opts \\ []) do
    case Runtime.run(scenario.state, scenario.events, opts) do
      {:ok, state, steps} ->
        outputs = Enum.flat_map(steps, & &1.outputs)
        checks = Enum.map(scenario.expectations, &check(&1, state, outputs))

        {:ok,
         %Result{scenario: scenario, state: state, steps: steps, outputs: outputs, checks: checks}}

      {:error, {index, error, _steps}} ->
        {:error, {index, error}}
    end
  end

  @doc "Returns true when every expectation passed."
  def passed?(%Result{checks: checks}), do: Enum.all?(checks, & &1.passed?)

  @doc "Paths of the scenarios bundled with Aethrion."
  def bundled do
    :aethrion
    |> :code.priv_dir()
    |> Path.join("scenarios/*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  ## Parsing

  defp world("demo"), do: {:ok, State.demo()}

  defp world(%{"characters" => characters} = data) when is_list(characters) do
    {:ok, State.from_data(data)}
  rescue
    error in [KeyError] -> {:error, {:invalid_world, Exception.message(error)}}
  end

  defp world(other), do: {:error, {:invalid_world, other}}

  defp events(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {data, index}, {:ok, events} ->
      case Event.from_data(data) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, {:invalid_event, index, reason}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp events(_list), do: {:error, :events_must_be_a_list}

  defp expectations(list) when is_list(list) do
    case Enum.find(list, &(not valid_expectation?(&1))) do
      nil -> {:ok, list}
      invalid -> {:error, {:invalid_expectation, invalid}}
    end
  end

  defp expectations(_list), do: {:error, :expect_must_be_a_list}

  defp valid_expectation?(%{"character" => id, "field" => field}) when is_binary(id),
    do: is_binary(field)

  defp valid_expectation?(%{"relationship" => [from, to], "field" => field}),
    do: is_binary(from) and is_binary(to) and is_binary(field)

  defp valid_expectation?(%{"output" => type}), do: is_binary(type)
  defp valid_expectation?(%{"memory" => %{}}), do: true
  defp valid_expectation?(%{"clock" => _}), do: true
  defp valid_expectation?(_expectation), do: false

  ## Checking

  @doc false
  def check(expectation, %State{} = state, outputs) do
    actual = actual(expectation, state, outputs)

    %{
      expectation: expectation,
      description: describe(expectation),
      actual: actual,
      passed?: compare(expectation, actual)
    }
  end

  defp actual(%{"character" => id, "field" => field}, state, _outputs) do
    case State.character(state, id) do
      nil -> :missing_character
      character -> character.state |> Map.from_struct() |> field_value(field)
    end
  end

  defp actual(%{"relationship" => [from, to], "field" => field}, state, _outputs) do
    state |> State.get_relationship(from, to) |> Map.from_struct() |> field_value(field)
  end

  defp actual(%{"output" => type} = expectation, _state, outputs) do
    filters = Map.drop(expectation, ["output", "count", "equals", "at_least", "at_most"])

    Enum.count(outputs, fn output ->
      to_string(output.type) == type and
        Enum.all?(filters, fn {key, value} -> output_field(output, key) == value end)
    end)
  end

  defp actual(%{"memory" => filters}, state, _outputs) do
    Enum.count(state.memories, fn memory ->
      Enum.all?(filters, fn {key, value} -> memory_field(memory, key) == value end)
    end)
  end

  defp actual(%{"clock" => _}, state, _outputs), do: state.clock

  defp compare(%{"clock" => value}, actual) when is_integer(value), do: actual == value

  defp compare(expectation, actual) do
    cond do
      Map.has_key?(expectation, "equals") ->
        normalize(actual) == expectation["equals"]

      Map.has_key?(expectation, "count") ->
        actual == expectation["count"]

      Map.has_key?(expectation, "at_least") ->
        is_number(actual) and actual >= expectation["at_least"]

      Map.has_key?(expectation, "at_most") ->
        is_number(actual) and actual <= expectation["at_most"]

      Map.has_key?(expectation, "output") or Map.has_key?(expectation, "memory") ->
        actual > 0

      true ->
        false
    end
  end

  defp field_value(map, field) do
    names = [field, field <> "?", field <> "_id"]

    case Enum.find(map, fn {key, _value} -> Atom.to_string(key) in names end) do
      {_key, value} -> value
      nil -> :missing_field
    end
  end

  defp output_field(output, key) do
    output |> field_value(key) |> normalize()
  end

  defp memory_field(memory, "faded"), do: Aethrion.Memory.faded?(memory)

  defp memory_field(memory, key),
    do: memory |> Map.from_struct() |> field_value(key) |> normalize()

  defp normalize(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp normalize(value), do: value

  @doc "One-line description of an expectation."
  def describe(%{"character" => id, "field" => field} = expectation),
    do: "#{id}.#{field} #{comparison(expectation)}"

  def describe(%{"relationship" => [from, to], "field" => field} = expectation),
    do: "#{from}->#{to}.#{field} #{comparison(expectation)}"

  def describe(%{"output" => type} = expectation) do
    filters =
      expectation
      |> Map.drop(["output", "count", "equals", "at_least", "at_most"])
      |> Enum.sort()
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    String.trim("#{type} #{filters}") <> " " <> count_comparison(expectation)
  end

  def describe(%{"memory" => filters} = expectation) do
    filters =
      filters |> Enum.sort() |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    "memory #{filters} " <> count_comparison(expectation)
  end

  def describe(%{"clock" => value}), do: "clock == #{value}"

  defp comparison(%{"equals" => value}), do: "== #{value}"
  defp comparison(%{"at_least" => value}), do: ">= #{value}"
  defp comparison(%{"at_most" => value}), do: "<= #{value}"
  defp comparison(_expectation), do: "(no comparison)"

  defp count_comparison(%{"count" => value}), do: "count == #{value}"
  defp count_comparison(%{"equals" => value}), do: "count == #{value}"
  defp count_comparison(%{"at_least" => value}), do: "count >= #{value}"
  defp count_comparison(%{"at_most" => value}), do: "count <= #{value}"
  defp count_comparison(_expectation), do: "count >= 1"
end
