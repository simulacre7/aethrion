defmodule Aethrion.Rules.Proactive do
  @moduledoc """
  Characters reach out to people (actors who are not characters, such as
  `"user"`) on their own when social pressure crosses a threshold. A character
  sends at most one proactive message per simulated hour (`min_gap_hours`), so a
  cascade never produces a burst of messages from one character.

  Who they reach out to: jealousy goes to whoever gave the gift they saw,
  loneliness to the person they feel closest to, curiosity to the person the
  news is about, and a character who saw someone be hostile to a friend
  speaks up to that person. A world with no relationships to people addresses
  `"user"`.

  Characters do not reach out to someone they currently feel tense toward
  (tension >= 10); they turn to friends instead.

  | reason     | condition                                                  | cooldown |
  | ---------- | ---------------------------------------------------------- | -------- |
  | `:jealous` | jealousy >= 15 and jealousy + loneliness >= 45             | 24h      |
  | `:lonely`  | loneliness >= 60 and jealousy < 15                         | 24h      |
  | `:protective` | saw a person be hostile to a character they care about (affinity >= 30) | 24h per person and friend |
  | `:curious` | heard secondhand news about a person and is `:playful` or has affinity >= 30 toward them | once per topic |

  Reasons are tried in the order of the table.
  """

  use Aethrion.Rule,
    id: :proactive,
    description:
      "Jealous (pressure>=45), protective (saw hostility to a friend), lonely (>=60), or curious (heard news about someone) characters message that person, at most once an hour.",
    params: [
      jealousy_floor: 15,
      pressure_threshold: 45,
      loneliness_threshold: 60,
      cooldown_hours: 24,
      curious_affinity: 30,
      protective_affinity: 30,
      avoid_tension: 10,
      min_gap_hours: 1
    ]

  alias Aethrion.{Character, Expression, Memories, Memory, Output, State, Transition}

  @default_recipient "user"

  @impl true
  def apply(%Transition{} = transition) do
    state = transition.state
    params = Map.new(params(), fn {key, _default} -> {key, Transition.param(transition, key)} end)

    # Checked on every event: curiosity can become possible after any change
    # (affinity rising, tension easing, a character being unblocked).
    {heard, witnessed} = secondhand_about_people(state)

    params = params |> Map.put(:heard, heard) |> Map.put(:witnessed, witnessed)
    outgoing = State.relationships_by_from(state)

    transition = prune_curiosity(transition, heard)
    state = transition.state

    state
    |> State.sorted_characters()
    |> Enum.filter(&(Character.can_act?(&1) and could_reach_out?(&1, params)))
    |> Enum.filter(&State.cooldown_ready?(state, gap_key(&1.id), params.min_gap_hours))
    |> Enum.reduce(transition, fn character, transition ->
      people = people(transition.state, character.id, outgoing, params)

      case first_trigger(transition.state, character, people, params) do
        nil ->
          transition

        {reason, key, recipient, opts} ->
          send_message(transition, character, reason, key, recipient, opts)
      end
    end)
  end

  @doc """
  The people (actors who are not characters) `character_id` could reach out
  to, closest first: those they have a relationship with and do not feel tense
  toward. A world with no such relationships addresses `"user"`.
  """
  def people(%State{} = state, character_id, outgoing \\ nil, params \\ nil) do
    outgoing = outgoing || State.relationships_by_from(state)
    avoid = if params, do: params.avoid_tension, else: Keyword.fetch!(params(), :avoid_tension)

    relationships =
      outgoing
      |> Map.get(character_id, [])
      |> Enum.reject(&State.character?(state, &1.to))

    known =
      case relationships do
        [] -> [State.get_relationship(state, character_id, @default_recipient)]
        relationships -> relationships
      end

    known
    |> Enum.filter(&(&1.tension < avoid))
    |> Enum.sort_by(&{-&1.affinity, &1.to})
    |> Enum.map(& &1.to)
  end

  # Any proactive message from this character, to space messages out.
  defp gap_key(id), do: "proactive:#{id}"

  # Cheap numeric pre-check so people are only computed for characters who
  # might actually reach out.
  defp could_reach_out?(%Character{id: id, state: cs}, params) do
    (cs.jealousy >= params.jealousy_floor and
       cs.jealousy + cs.loneliness >= params.pressure_threshold) or
      cs.loneliness >= params.loneliness_threshold or Map.has_key?(params.heard, id) or
      Map.has_key?(params.witnessed, id)
  end

  defp first_trigger(_state, _character, [], _params), do: nil

  defp first_trigger(state, character, people, params) do
    Enum.find_value(
      [:jealous, :protective, :lonely, :curious],
      &trigger(&1, state, character, people, params)
    )
  end

  # Reach out to whoever gave the gift that caused the jealousy, when reachable.
  defp trigger(:jealous, state, %Character{id: id, state: cs}, [closest | _] = people, params) do
    key = "proactive:#{id}:jealous"

    if cs.jealousy >= params.jealousy_floor and
         cs.jealousy + cs.loneliness >= params.pressure_threshold and
         State.cooldown_ready?(state, key, params.cooldown_hours) do
      giver =
        state
        |> Memories.for_character(id)
        |> Enum.find_value(fn
          %Memory{kind: :observed, data: %{"event" => "gift_received", "from" => from}} ->
            if from in people, do: from

          _memory ->
            nil
        end)

      {:jealous, key, giver || closest, []}
    end
  end

  defp trigger(:lonely, state, %Character{id: id, state: cs}, [closest | _], params) do
    key = "proactive:#{id}:lonely"

    if cs.loneliness >= params.loneliness_threshold and cs.jealousy < params.jealousy_floor and
         State.cooldown_ready?(state, key, params.cooldown_hours) do
      {:lonely, key, closest, []}
    end
  end

  # Speak up to the person who was hostile to someone this character cares about.
  defp trigger(:protective, state, %Character{id: id}, people, params) do
    params.witnessed
    |> Map.get(id, [])
    |> Enum.find_value(fn %Memory{data: %{"from" => person, "to" => friend}} = memory ->
      # One protest per person and friend a day, however many hostile
      # messages were witnessed.
      key = "proactive:#{id}:protective:#{person}:#{friend}"

      if person in people and friend != id and
           State.get_relationship(state, id, friend).affinity >= params.protective_affinity and
           State.cooldown_ready?(state, key, params.cooldown_hours) do
        {:protective, key, person, memories: [memory]}
      end
    end)
  end

  # Ask the person the news is about.
  defp trigger(:curious, state, %Character{id: id} = character, people, params) do
    params.heard
    |> Map.get(id, [])
    |> Enum.find_value(fn memory ->
      key = "proactive:#{id}:curious:#{memory.topic}"

      with person when not is_nil(person) <- Enum.find(people, &Memory.involves?(memory, &1)),
           true <-
             Character.trait?(character, :playful) or
               State.get_relationship(state, id, person).affinity >= params.curious_affinity,
           true <- State.cooldown_ready?(state, key, :once) do
        {:curious, key, person, memories: [memory]}
      else
        _ -> nil
      end
    end)
  end

  # A curiosity key only matters while its heard memory is unfaded, and faded
  # memories never come back, so on each tick keys for anything else are
  # dropped; otherwise they would pile up in long-running worlds.
  defp prune_curiosity(%Transition{event: %{type: :time_tick}, state: state} = transition, heard) do
    live =
      for {id, memories} <- heard, memory <- memories, into: MapSet.new() do
        "proactive:#{id}:curious:#{memory.topic}"
      end

    cooldowns =
      Map.filter(state.cooldowns, fn {key, _at} ->
        not String.contains?(key, ":curious:") or MapSet.member?(live, key)
      end)

    if map_size(cooldowns) == map_size(state.cooldowns),
      do: transition,
      else: Transition.put_state(transition, %{state | cooldowns: cooldowns})
  end

  defp prune_curiosity(transition, _heard), do: transition

  # Unfaded secondhand memories involving someone who is not a character, by
  # character, newest first: what they heard, and hostile messages from a
  # person that they witnessed. One pass over the memories.
  defp secondhand_about_people(state) do
    # Built newest last, then reversed once.
    add = fn acc, memory -> Map.update(acc, memory.character_id, [memory], &[memory | &1]) end

    for %Memory{kind: kind} = memory <- state.memories,
        kind in [:heard, :observed],
        not Memory.faded?(memory),
        reduce: {%{}, %{}} do
      {heard, witnessed} ->
        cond do
          kind == :heard and
              Enum.any?(memory.related_characters, &(not State.character?(state, &1))) ->
            {add.(heard, memory), witnessed}

          kind == :observed and hostile_from_person?(state, memory) ->
            {heard, add.(witnessed, memory)}

          true ->
            {heard, witnessed}
        end
    end
    |> then(fn {heard, witnessed} ->
      reverse = &Map.new(&1, fn {id, list} -> {id, Enum.reverse(list)} end)
      {reverse.(heard), reverse.(witnessed)}
    end)
  end

  defp hostile_from_person?(state, %Memory{data: data}) do
    match?(%{"event" => "message_sent", "tone" => "hostile", "from" => _, "to" => _}, data) and
      not State.character?(state, data["from"])
  end

  defp send_message(transition, character, reason, key, recipient, opts) do
    request =
      Expression.build_request(
        transition.state,
        :proactive_message,
        character.id,
        recipient,
        Keyword.put(opts, :reason, reason)
      )

    output =
      Output.proactive_message(character.id, recipient, reason, request.fallback_text,
        memory_refs: Enum.map(request.memories, & &1.id),
        context: request
      )

    transition
    |> Transition.put_cooldown(key)
    |> Transition.put_cooldown(gap_key(character.id))
    |> Transition.emit(output)
    |> Transition.log("[Output] #{character.name} -> #{recipient}: \"#{output.text}\"")
  end
end
