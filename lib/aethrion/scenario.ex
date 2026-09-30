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

  ## Branches

  A scenario may continue into alternative futures after its shared events:

  ```json
  "branches": [
    {"name": "Ignore Yuna", "events": [{"type": "time_tick", "hours": 2}],
     "expect": [{"output": "proactive_message", "character": "yuna", "count": 1}]},
    {"name": "Apologize", "events": [{"type": "apology_offered", "from": "user", "to": "yuna", "reason": "sorry"},
                                     {"type": "time_tick", "hours": 2}],
     "expect": [{"output": "proactive_message", "count": 0}]}
  ]
  ```

  Every branch starts from the state after the shared events. Branch
  expectations are checked against that branch's final state and the outputs
  produced after the split.

  ## Expectations

  Expectations select a value and compare it with one of `equals`,
  `at_least`, or `at_most`. Output and memory expectations count matches;
  without a comparison they pass when at least one matches (`count` is
  shorthand for `equals` on the count).
  """

  alias Aethrion.{Error, Event, Runtime, State}

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          state: State.t(),
          events: [map()],
          expectations: [map()],
          branches: [branch()],
          path: String.t() | nil
        }

  @type branch :: %{
          name: String.t(),
          description: String.t(),
          events: [map()],
          expectations: [map()]
        }

  defstruct name: "Untitled scenario",
            description: "",
            state: nil,
            events: [],
            expectations: [],
            branches: [],
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
            checks: [check()],
            branches: [branch()]
          }

    @typedoc "The outcome of one branch, run from the state after the shared events."
    @type branch :: %{
            name: String.t(),
            description: String.t(),
            state: Aethrion.State.t(),
            steps: [Aethrion.Step.t()],
            outputs: [map()],
            checks: [check()]
          }

    defstruct [:scenario, :state, steps: [], outputs: [], checks: [], branches: []]
  end

  @doc """
  Loads a scenario from a JSON file. Errors are `%Aethrion.Error{}` with code
  `:not_found`, `:io_error`, or those of `from_data/2`.
  """
  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def load(path, opts \\ []) do
    with {:ok, json} <- read(path),
         {:ok, data} <- decode(json),
         {:ok, scenario} <- from_data(data, opts) do
      {:ok, %{scenario | path: path}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, json} ->
        {:ok, json}

      {:error, :enoent} ->
        {:error, Error.new(:not_found, "no scenario at #{path}", %{file: path})}

      {:error, reason} ->
        {:error,
         Error.new(:io_error, "could not read #{path}: #{inspect(reason)}", %{reason: reason})}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, data} ->
        {:ok, data}

      {:error, error} ->
        {:error, invalid([], "invalid JSON: #{Exception.message(error)}")}
    end
  end

  @doc """
  Builds a scenario from decoded JSON data. Errors are `%Aethrion.Error{}`;
  `details.path` points at the offending part of the document (for example
  `["events", 2]` or `["branches", 0, "expect", 1]`). Malformed structure uses
  code `:invalid_scenario`; problems found by other modules keep their codes
  (`:invalid_state` for the world, `:invalid_tuning`, `:unsupported_event`).
  """
  @spec from_data(term(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def from_data(data, opts \\ [])

  def from_data(%{} = data, opts) do
    pipeline = Keyword.get(opts, :pipeline, Aethrion.Pipeline.default())

    with :ok <- string_field(data, "name"),
         :ok <- string_field(data, "description"),
         {:ok, state} <- world(Map.get(data, "world", "demo"), pipeline),
         {:ok, tuning} <- tuning(Map.get(data, "tuning"), pipeline),
         {:ok, events} <- events(Map.get(data, "events", []), pipeline, ["events"]),
         {:ok, expectations} <- expectations(Map.get(data, "expect", []), ["expect"]),
         {:ok, branches} <- branches(Map.get(data, "branches", []), pipeline) do
      {:ok,
       %__MODULE__{
         name: data["name"] || "Untitled scenario",
         description: data["description"] || "",
         state: %{
           state
           | tuning: Map.merge(state.tuning, tuning, fn _rule, a, b -> Map.merge(a, b) end)
         },
         events: events,
         expectations: expectations,
         branches: branches
       }}
    end
  end

  def from_data(_data, _opts), do: {:error, invalid([], "a scenario must be a JSON object")}

  @doc """
  Runs the scenario and evaluates its expectations.

  Returns `{:ok, %Result{}}`, or `{:error, %Aethrion.Error{}}` when an event is
  rejected; `details` holds its `:index` and, for a branch event, the
  `:branch` name. Options are passed to `Aethrion.Runtime.step/3`.
  """
  @spec run(t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(%__MODULE__{} = scenario, opts \\ []) do
    case Runtime.run(scenario.state, scenario.events, opts) do
      {:ok, state, steps} ->
        outputs = Enum.flat_map(steps, & &1.outputs)
        checks = Enum.map(scenario.expectations, &check(&1, state, outputs))

        with {:ok, branches} <- run_branches(scenario.branches, state, opts) do
          {:ok,
           %Result{
             scenario: scenario,
             state: state,
             steps: steps,
             outputs: outputs,
             checks: checks,
             branches: branches
           }}
        end

      {:error, error} ->
        {:error, %{error | details: Map.delete(error.details, :steps)}}
    end
  end

  defp run_branches(branches, state, opts) do
    Enum.reduce_while(branches, {:ok, []}, fn branch, {:ok, acc} ->
      case Runtime.run(state, branch.events, opts) do
        {:ok, final, steps} ->
          outputs = Enum.flat_map(steps, & &1.outputs)

          result = %{
            name: branch.name,
            description: branch.description,
            state: final,
            steps: steps,
            outputs: outputs,
            checks: Enum.map(branch.expectations, &check(&1, final, outputs))
          }

          {:cont, {:ok, [result | acc]}}

        {:error, error} ->
          details = error.details |> Map.delete(:steps) |> Map.put(:branch, branch.name)
          {:halt, {:error, %{error | details: details}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc "Returns true when every expectation, including every branch's, passed."
  @spec passed?(Result.t()) :: boolean()
  def passed?(%Result{checks: checks, branches: branches}) do
    Enum.all?(checks ++ Enum.flat_map(branches, & &1.checks), & &1.passed?)
  end

  @doc "Every check in the result: shared first, then each branch's, tagged with the branch name."
  def all_checks(%Result{checks: checks, branches: branches}) do
    Enum.map(checks, &Map.put(&1, :branch, nil)) ++
      Enum.flat_map(branches, fn branch ->
        Enum.map(branch.checks, &Map.put(&1, :branch, branch.name))
      end)
  end

  @doc """
  Builds scenario data (ready for `Jason.encode!/2`) from a recorded session.

  `world` is `"demo"` or the `Aethrion.State` the session started from.
  Expectations snapshot the outcome: every character's final mood and the
  number of proactive messages and scenes per character. Replaying the file
  with `mix aethrion.scenario` turns a play session into a regression test.
  """
  def record(world, host_events, %State{} = final, outputs, opts \\ []) do
    world_data =
      case world do
        "demo" -> "demo"
        %State{} = state -> state |> State.to_data() |> Map.delete("version")
      end

    %{
      "name" => Keyword.get(opts, :name, "Recorded session"),
      "description" => Keyword.get(opts, :description, "Recorded from mix demo.interactive."),
      "world" => world_data,
      "events" =>
        Enum.map(host_events, fn event ->
          event |> Map.drop([:id, :cause]) |> Event.to_data()
        end),
      "expect" => snapshot_expectations(final, outputs)
    }
  end

  defp snapshot_expectations(final, outputs) do
    moods =
      for character <- State.sorted_characters(final) do
        %{
          "character" => character.id,
          "field" => "mood",
          "equals" => to_string(character.state.mood)
        }
      end

    counts =
      outputs
      |> Enum.filter(&(&1.type in [:proactive_message, :character_interaction]))
      |> Enum.frequencies_by(fn output ->
        {to_string(output.type), output.character_id}
      end)
      |> Enum.sort()
      |> Enum.map(fn {{type, id}, count} ->
        %{"output" => type, "character" => id, "count" => count}
      end)

    moods ++ counts
  end

  @doc "Paths of the scenarios bundled with Aethrion."
  def bundled do
    :aethrion
    |> :code.priv_dir()
    |> Path.join("scenarios/*.json")
    |> Path.wildcard()
    |> Enum.sort()
  end

  ## Parsing

  defp invalid(path, message, details \\ %{}) do
    Error.new(:invalid_scenario, message, Map.put(details, :path, path))
  end

  defp at(%Error{} = error, path) do
    Error.add_details(error, %{path: path ++ Map.get(error.details, :path, [])})
  end

  defp world("demo", _pipeline), do: {:ok, State.demo()}

  defp world(%{"characters" => characters} = data, pipeline) when is_list(characters) do
    case State.parse(data, pipeline: pipeline) do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:error, at(error, ["world"])}
    end
  end

  defp world(_other, _pipeline) do
    {:error, invalid(["world"], "world must be \"demo\" or an object with characters")}
  end

  defp tuning(data, pipeline) do
    case Aethrion.Tuning.from_data(data, pipeline: pipeline) do
      {:ok, tuning} -> {:ok, tuning}
      {:error, error} -> {:error, at(error, ["tuning"])}
    end
  end

  defp events(list, pipeline, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {data, index}, {:ok, events} ->
      case Event.from_data(data, pipeline: pipeline) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, error} -> {:halt, {:error, at(error, path ++ [index])}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp events(_list, _pipeline, path), do: {:error, invalid(path, "events must be a list")}

  defp string_field(data, key, path \\ []) do
    case Map.get(data, key) do
      nil -> :ok
      value when is_binary(value) -> :ok
      value -> {:error, invalid(path ++ [key], "#{key} must be a string", %{value: value})}
    end
  end

  defp branches(list, pipeline) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {data, index}, {:ok, acc} ->
      path = ["branches", index]

      with :ok <- object(data, path),
           :ok <- string_field(data, "name", path),
           :ok <- string_field(data, "description", path),
           {:ok, events} <- events(Map.get(data, "events", []), pipeline, path ++ ["events"]),
           {:ok, expectations} <- expectations(Map.get(data, "expect", []), path ++ ["expect"]) do
        branch = %{
          name: Map.get(data, "name", "Branch #{index + 1}"),
          description: Map.get(data, "description", ""),
          events: events,
          expectations: expectations
        }

        {:cont, {:ok, [branch | acc]}}
      else
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, branches} -> {:ok, Enum.reverse(branches)}
      error -> error
    end
  end

  defp branches(_list, _pipeline), do: {:error, invalid(["branches"], "branches must be a list")}

  defp object(data, _path) when is_map(data), do: :ok
  defp object(_data, path), do: {:error, invalid(path, "expected an object")}

  defp expectations(list, path) when is_list(list) do
    case Enum.find_index(list, &(not valid_expectation?(&1))) do
      nil ->
        {:ok, list}

      index ->
        {:error,
         invalid(path ++ [index], "unsupported expectation", %{expectation: Enum.at(list, index)})}
    end
  end

  defp expectations(_list, path), do: {:error, invalid(path, "expect must be a list")}

  defp valid_expectation?(%{"character" => id, "field" => field}) when is_binary(id),
    do: is_binary(field)

  # A bond is a name, not a number: it can only be compared with equals.
  defp valid_expectation?(%{"relationship" => [_from, _to], "field" => "bond"} = expectation),
    do: not Map.has_key?(expectation, "at_least") and not Map.has_key?(expectation, "at_most")

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

  defp actual(%{"relationship" => [from, to], "field" => "bond"}, state, _outputs) do
    state |> State.get_relationship(from, to) |> Aethrion.Rules.Bond.derive(state)
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
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{show(value)}" end)

    String.trim("#{type} #{filters}") <> " " <> count_comparison(expectation)
  end

  def describe(%{"memory" => filters} = expectation) do
    filters =
      filters |> Enum.sort() |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{show(value)}" end)

    "memory #{filters} " <> count_comparison(expectation)
  end

  def describe(%{"clock" => value}), do: "clock == #{show(value)}"

  defp comparison(%{"equals" => value}), do: "== #{show(value)}"
  defp comparison(%{"at_least" => value}), do: ">= #{show(value)}"
  defp comparison(%{"at_most" => value}), do: "<= #{show(value)}"
  defp comparison(_expectation), do: "(no comparison)"

  defp count_comparison(%{"count" => value}), do: "count == #{show(value)}"
  defp count_comparison(%{"equals" => value}), do: "count == #{show(value)}"
  defp count_comparison(%{"at_least" => value}), do: "count >= #{show(value)}"
  defp count_comparison(%{"at_most" => value}), do: "count <= #{show(value)}"
  defp count_comparison(_expectation), do: "count >= 1"

  defp show(value) when is_binary(value), do: value

  defp show(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: to_string(value)

  defp show(value), do: inspect(value)
end
