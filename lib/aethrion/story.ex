defmodule Aethrion.Story do
  @moduledoc """
  Endings decided by the numbers, the way a raising sim decides them: the
  same choices always lead to the same ending, and a designer can see why.

  A world's `story` (in its state, so in casts, saves, and scenarios) holds:

  - `activities` - what spending time on something does: `"study"` might add
    3 to a character's `intelligence` stat and 4 to their stress. Dispatch
    `%{type: :activity, character: "mina", activity: "study"}` to do one.
  - `endings` - an ordered list. The first ending whose conditions all hold
    is the one reached; an ending with no conditions is the one everybody
    else gets.
  - `deadline` - the simulated hour at which the ending is decided (say
    `720` for thirty days). The world emits an `:ending_reached` output
    once, the first time its clock reaches it.
  - `decide_when` - conditions that decide the ending as soon as any of them
    holds, deadline or not: the boss falls (`{"stat": ["wolf", "hp"],
    "at_most": 0}`), or the hero does.

  ```json
  "story": {
    "deadline": 720,
    "activities": {
      "study": {"intelligence": 3, "stress": 4},
      "dance": {"charm": 3, "joy": 5, "stress": 2}
    },
    "endings": [
      {"id": "lovers", "title": "Together",
       "when": [{"relationship": ["mina", "user"], "field": "affinity", "at_least": 70},
                {"bond": ["mina", "user"], "is": "close"}]},
      {"id": "scholar", "title": "The scholar",
       "when": [{"stat": ["mina", "intelligence"], "at_least": 60}]},
      {"id": "ordinary", "title": "An ordinary life", "when": []}
    ]
  }
  ```

  Conditions compare with `at_least`, `at_most`, or `equals` (`is` for a
  bond, which also takes `at_least` on the order estranged < strained <
  neutral < friendly < close):

  | condition | value |
  | --- | --- |
  | `{"stat": [actor, name]}` | a stat in the state's `stats` |
  | `{"character": id, "field": "joy"}` | `energy`, `loneliness`, `jealousy`, `joy`, `stress` |
  | `{"relationship": [from, to], "field": "affinity"}` | `affinity`, `trust`, `tension` |
  | `{"bond": [from, to]}` | the relationship's bond |
  | `{"memories": {"character": id, "event": "gift_received", "from": "user"}}` | how many such memories the character holds (faded ones included) |
  | `{"clock": true}` | the simulated hour |
  | `{"any": [conditions]}`, `{"not": condition}` | either of, or the opposite of |

  `ending/1` says which ending the world would reach now, `progress/1` how
  close every ending is and what is missing, so a game can hint at a route.
  """

  alias Aethrion.{Memories, Pipeline, State}

  @bonds [:estranged, :strained, :neutral, :friendly, :close]
  @character_fields ~w(energy loneliness jealousy joy stress)
  @relationship_fields ~w(affinity trust tension)

  @doc """
  The default pipeline, which already runs activities (`Aethrion.Rules.Activity`)
  and decides endings (`Aethrion.Rules.Ending`); for a custom pipeline, adds
  them if missing.
  """
  @spec pipeline(Pipeline.t()) :: Pipeline.t()
  def pipeline(base \\ Pipeline.default()) do
    base
    |> then(
      &if(Pipeline.handles?(&1, :activity),
        do: &1,
        else: Pipeline.append(&1, :activity, Aethrion.Rules.Activity)
      )
    )
    |> then(
      &if(Aethrion.Rules.Ending in &1.reactive_rules,
        do: &1,
        else: %{&1 | reactive_rules: &1.reactive_rules ++ [Aethrion.Rules.Ending]}
      )
    )
  end

  ## Deciding

  @doc """
  The ending the world would reach now: `{:ok, ending}` with the ending's
  `:id`, `:title`, `:description`, and the conditions that hold, or `:none`
  when no ending matches (a story without a default ending).
  """
  @spec ending(State.t()) :: {:ok, map()} | :none
  def ending(%State{story: story} = state) do
    case Enum.find(Map.get(story, :endings, []), &all_hold?(state, &1.when)) do
      nil -> :none
      ending -> {:ok, Map.put(ending, :because, Enum.map(ending.when, &describe(state, &1)))}
    end
  end

  @doc """
  Every ending with how many of its conditions hold, a description of each
  one that does not, and `closeness`, from 0 to 1, which also counts partial
  progress (54 affinity toward a needed 80 is two thirds of the way):
  `[%{id, title, met, total, closeness, missing}]`, in order.
  """
  @spec progress(State.t()) :: [map()]
  def progress(%State{story: story} = state) do
    for ending <- Map.get(story, :endings, []) do
      {met, missing} = Enum.split_with(ending.when, &holds?(state, &1))

      %{
        id: ending.id,
        title: ending.title,
        met: length(met),
        total: length(ending.when),
        closeness: closeness(state, ending.when),
        missing: Enum.map(missing, &describe(state, &1))
      }
    end
  end

  defp closeness(_state, []), do: 1.0

  defp closeness(state, conditions) do
    conditions
    |> Enum.map(&partial(state, &1))
    |> Enum.sum()
    |> Kernel./(length(conditions))
    |> Float.round(2)
  end

  # How far along a condition is: the share of a threshold reached for
  # at_least, all or nothing otherwise.
  defp partial(state, condition) do
    cond do
      holds?(state, condition) -> 1.0
      match?({:bond, _, _, :at_least, _}, condition) -> bond_share(state, condition)
      match?({_, _, :at_least, want} when want > 0, condition) -> share(state, condition)
      true -> 0.0
    end
  end

  defp share(state, {_subject, _what, :at_least, want} = condition),
    do: (value(state, condition) |> max(0)) / want

  defp bond_share(state, {:bond, from, to, _op, wanted}),
    do: rank(bond(state, from, to)) / max(rank(wanted), 1)

  @doc "Whether a parsed condition holds in `state`."
  @spec holds?(State.t(), tuple()) :: boolean()
  def holds?(state, {:any, conditions}), do: Enum.any?(conditions, &holds?(state, &1))
  def holds?(state, {:not, condition}), do: not holds?(state, condition)

  def holds?(state, {:bond, from, to, op, wanted}) do
    have = rank(bond(state, from, to))
    want = rank(wanted)

    case op do
      :equals -> have == want
      :at_least -> have >= want
      :at_most -> have <= want
    end
  end

  def holds?(state, {_subject, _what, op, wanted} = condition),
    do: compare(value(state, condition), op, wanted)

  defp all_hold?(state, conditions), do: Enum.all?(conditions, &holds?(state, &1))

  defp compare(have, :at_least, want), do: have >= want
  defp compare(have, :at_most, want), do: have <= want
  defp compare(have, :equals, want), do: have == want

  defp value(state, {:stat, {actor, name}, _op, _want}), do: State.stat(state, actor, name)

  defp value(state, {:character, {id, field}, _op, _want}) do
    case State.character(state, id) do
      nil -> 0
      character -> Map.fetch!(character.state, String.to_existing_atom(field))
    end
  end

  defp value(state, {:relationship, {from, to, field}, _op, _want}),
    do: state |> State.get_relationship(from, to) |> Map.fetch!(String.to_existing_atom(field))

  defp value(state, {:memories, filter, _op, _want}) do
    state
    |> Memories.for_character(filter["character"], include_faded: true)
    |> Enum.count(fn memory ->
      Enum.all?(Map.delete(filter, "character"), fn
        {"kind", kind} -> Atom.to_string(memory.kind) == kind
        {key, wanted} -> Map.get(memory.data, key) == wanted
      end)
    end)
  end

  defp value(state, {:clock, _what, _op, _want}), do: state.clock

  defp bond(state, from, to),
    do: state |> State.get_relationship(from, to) |> Aethrion.Rules.Bond.derive(state)

  defp rank(bond), do: Enum.find_index(@bonds, &(&1 == bond))

  @doc "A condition in words, with where things stand: `mina -> user affinity 54 (needs at least 70)`."
  @spec describe(State.t(), tuple()) :: String.t()
  def describe(state, {:any, conditions}),
    do: "any of: " <> Enum.map_join(conditions, "; ", &describe(state, &1))

  def describe(state, {:not, condition}), do: "not (" <> describe(state, condition) <> ")"

  def describe(state, {:bond, from, to, op, wanted}),
    do: "#{from} -> #{to} bond #{bond(state, from, to)} (needs #{words(op)} #{wanted})"

  def describe(state, {subject, what, op, wanted} = condition) do
    label =
      case {subject, what} do
        {:stat, {actor, name}} -> "#{actor} #{name}"
        {:character, {id, field}} -> "#{id} #{field}"
        {:relationship, {from, to, field}} -> "#{from} -> #{to} #{field}"
        {:memories, filter} -> "memories #{inspect(filter)}"
        {:clock, _} -> "hour"
      end

    "#{label} #{value(state, condition)} (needs #{words(op)} #{wanted})"
  end

  defp words(:at_least), do: "at least"
  defp words(:at_most), do: "at most"
  defp words(:equals), do: "exactly"

  ## Data

  @doc false
  # Parses untrusted story data: {:ok, story} or {:error, message, path}.
  def parse(nil), do: {:ok, %{}}

  def parse(data) when is_map(data) do
    with {:ok, activities} <- parse_activities(Map.get(data, "activities", %{})),
         {:ok, endings} <- parse_endings(Map.get(data, "endings", [])),
         {:ok, deadline} <- parse_deadline(Map.get(data, "deadline")),
         {:ok, decide} <- parse_conditions(Map.get(data, "decide_when", []), ["decide_when"]) do
      {:ok,
       %{activities: activities, endings: endings, deadline: deadline, decide_when: decide}
       |> Map.reject(fn {_k, v} -> v in [nil, %{}, []] end)}
    end
  end

  def parse(_data), do: {:error, "must be an object", []}

  @doc false
  def from_data!(data) do
    {:ok, story} = parse(data)
    story
  end

  @doc false
  def to_data(story) do
    %{}
    |> put_if("activities", story[:activities])
    |> put_if("endings", story[:endings] && Enum.map(story.endings, &ending_to_data/1))
    |> put_if("deadline", story[:deadline])
    |> put_if(
      "decide_when",
      story[:decide_when] && Enum.map(story.decide_when, &condition_to_data/1)
    )
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp parse_activities(activities) when is_map(activities) do
    Enum.reduce_while(activities, {:ok, %{}}, fn {name, effects}, {:ok, acc} ->
      if is_binary(name) and is_map(effects) and
           Enum.all?(effects, fn {k, v} -> is_binary(k) and k != "" and is_integer(v) end),
         do: {:cont, {:ok, Map.put(acc, name, effects)}},
         else:
           {:halt,
            {:error, "an activity maps stat or field names to whole numbers",
             ["activities", name]}}
    end)
  end

  defp parse_activities(_activities), do: {:error, "must be an object", ["activities"]}

  defp parse_endings(endings) when is_list(endings) do
    endings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {ending, index}, {:ok, acc} ->
      case parse_ending(ending) do
        {:ok, ending} -> {:cont, {:ok, [ending | acc]}}
        {:error, message, path} -> {:halt, {:error, message, ["endings", index | path]}}
      end
    end)
    |> case do
      {:ok, endings} -> check_ids(Enum.reverse(endings))
      error -> error
    end
  end

  defp parse_endings(_endings), do: {:error, "must be a list", ["endings"]}

  defp check_ids(endings) do
    ids = Enum.map(endings, & &1.id)

    case ids -- Enum.uniq(ids) do
      [] -> {:ok, endings}
      [id | _] -> {:error, "the ending id #{inspect(id)} is used more than once", ["endings"]}
    end
  end

  defp parse_ending(%{"id" => id} = data) when is_binary(id) and id != "" do
    with {:ok, conditions} <- parse_conditions(Map.get(data, "when", []), ["when"]) do
      {:ok,
       %{
         id: id,
         title: string_or(data["title"], id),
         description: string_or(data["description"], ""),
         when: conditions
       }}
    end
  end

  defp parse_ending(_data), do: {:error, "an ending needs a string id", []}

  defp parse_conditions(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {condition, index}, {:ok, acc} ->
      case parse_condition(condition) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, message, rest} -> {:halt, {:error, message, path ++ [index | rest]}}
      end
    end)
    |> case do
      {:ok, conditions} -> {:ok, Enum.reverse(conditions)}
      error -> error
    end
  end

  defp parse_conditions(_list, path), do: {:error, "must be a list of conditions", path}

  defp parse_condition(%{"any" => list}) do
    with {:ok, conditions} <- parse_conditions(list, ["any"]), do: {:ok, {:any, conditions}}
  end

  defp parse_condition(%{"not" => condition}) do
    with {:ok, parsed} <- parse_condition(condition), do: {:ok, {:not, parsed}}
  end

  defp parse_condition(%{"bond" => [from, to]} = data) when is_binary(from) and is_binary(to) do
    case bond_op(data) do
      {:ok, op, bond} -> {:ok, {:bond, from, to, op, bond}}
      :error -> {:error, "a bond condition needs is, at_least, or at_most with a bond name", []}
    end
  end

  defp parse_condition(%{"stat" => [actor, name]} = data)
       when is_binary(actor) and is_binary(name),
       do: with_op(data, {:stat, {actor, name}})

  defp parse_condition(%{"character" => id, "field" => field} = data)
       when is_binary(id) and field in @character_fields,
       do: with_op(data, {:character, {id, field}})

  defp parse_condition(%{"relationship" => [from, to], "field" => field} = data)
       when is_binary(from) and is_binary(to) and field in @relationship_fields,
       do: with_op(data, {:relationship, {from, to, field}})

  defp parse_condition(%{"memories" => %{"character" => id} = filter} = data)
       when is_binary(id),
       do: with_op(data, {:memories, filter})

  defp parse_condition(%{"clock" => true} = data), do: with_op(data, {:clock, nil})

  defp parse_condition(_data),
    do:
      {:error,
       "a condition is one of stat, character (with field), relationship (with field), bond, memories, clock, any, or not",
       []}

  defp with_op(data, {subject, what}) do
    case Enum.find(~w(at_least at_most equals), &is_integer(data[&1])) do
      nil -> {:error, "needs at_least, at_most, or equals with a whole number", []}
      op -> {:ok, {subject, what, String.to_existing_atom(op), data[op]}}
    end
  end

  defp bond_op(data) do
    Enum.find_value([{"is", :equals}, {"at_least", :at_least}, {"at_most", :at_most}], :error, fn
      {key, op} ->
        case Enum.find(@bonds, &(Atom.to_string(&1) == data[key])) do
          nil -> nil
          bond -> {:ok, op, bond}
        end
    end)
  end

  defp parse_deadline(nil), do: {:ok, nil}
  defp parse_deadline(hours) when is_integer(hours) and hours > 0, do: {:ok, hours}
  defp parse_deadline(_hours), do: {:error, "must be a positive number of hours", ["deadline"]}

  defp string_or(value, _default) when is_binary(value), do: value
  defp string_or(_value, default), do: default

  defp ending_to_data(ending) do
    %{
      "id" => ending.id,
      "title" => ending.title,
      "description" => ending.description,
      "when" => Enum.map(ending.when, &condition_to_data/1)
    }
  end

  defp condition_to_data({:any, list}), do: %{"any" => Enum.map(list, &condition_to_data/1)}
  defp condition_to_data({:not, c}), do: %{"not" => condition_to_data(c)}

  defp condition_to_data({:bond, from, to, op, bond}),
    do: %{"bond" => [from, to], op_key(op, :bond) => Atom.to_string(bond)}

  defp condition_to_data({subject, what, op, want}) do
    base =
      case {subject, what} do
        {:stat, {actor, name}} -> %{"stat" => [actor, name]}
        {:character, {id, field}} -> %{"character" => id, "field" => field}
        {:relationship, {from, to, field}} -> %{"relationship" => [from, to], "field" => field}
        {:memories, filter} -> %{"memories" => filter}
        {:clock, _} -> %{"clock" => true}
      end

    Map.put(base, op_key(op, subject), want)
  end

  defp op_key(:equals, :bond), do: "is"
  defp op_key(op, _subject), do: Atom.to_string(op)
end
