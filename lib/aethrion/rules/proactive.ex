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
  (tension >= 5); they turn to friends instead.

  | reason     | condition                                                  | cooldown |
  | ---------- | ---------------------------------------------------------- | -------- |
  | `:jealous` | jealousy >= 15 and jealousy + loneliness >= 45             | 24h      |
  | `:lonely`  | loneliness >= 60, jealousy < 15, affinity >= 25 toward the person, no company for 6h, and not heading out with a friend this hour | 24h, or 72h after a lonely message that got no reply |
  | `:protective` | saw a person be hostile to a character they care about (affinity >= 30), and has not seen or heard them apologize since | once per incident, and 24h per person and friend |
  | `:curious` | heard secondhand news about a person and is `:playful` or has affinity >= 30 toward them; not about harsh words from someone they saw be hostile themselves | once per topic |

  Reasons are tried in the order of the table.
  """

  use Aethrion.Rule,
    id: :proactive,
    description:
      "Jealous (pressure>=45), protective (saw hostility to a friend), lonely (>=60, affinity>=25), or curious (heard news about someone) characters message that person; one message an hour at most, each reason at most once a day, lonely messages every 3 days when unanswered.",
    params: [
      jealousy_floor: 15,
      pressure_threshold: 45,
      loneliness_threshold: 60,
      lonely_affinity: 25,
      cooldown_hours: 24,
      unanswered_hours: 72,
      alone_hours: 6,
      curious_affinity: 30,
      protective_affinity: 30,
      avoid_tension: 5,
      min_gap_hours: 1
    ]

  alias Aethrion.{Character, Expression, Memories, Memory, Output, State, Transition}
  alias Aethrion.Rules.TimePassage

  @default_recipient "user"

  @impl true
  def apply(%Transition{} = transition) do
    state = transition.state
    params = Map.new(params(), fn {key, _default} -> {key, Transition.param(transition, key)} end)

    # Checked on every event: curiosity can become possible after any change
    # (affinity rising, tension easing, a character being unblocked).
    {heard, witnessed} = secondhand_about_people(state)

    params =
      params
      |> Map.put(:heard, heard)
      |> Map.put(:witnessed, witnessed)
      |> Map.put(:heading_out, heading_out(transition))

    outgoing = State.relationships_by_from(state)

    transition = prune_once_keys(transition, heard, witnessed)
    state = transition.state

    state
    |> State.sorted_characters()
    |> Enum.filter(
      &(Character.can_act?(&1) and could_reach_out?(&1, params) and
          State.cooldown_ready?(state, gap_key(&1.id), params.min_gap_hours))
    )
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

  # Reach out to the closest person, unless going out with a friend this hour
  # anyway. After a lonely message that got no reply, wait longer.
  defp trigger(:lonely, state, %Character{id: id, state: cs}, [closest | _], params) do
    key = "proactive:#{id}:lonely"

    if cs.loneliness >= params.loneliness_threshold and cs.jealousy < params.jealousy_floor and
         not MapSet.member?(params.heading_out, id) and
         State.cooldown_ready?(state, TimePassage.company_key(id), params.alone_hours) and
         State.get_relationship(state, id, closest).affinity >= params.lonely_affinity and
         State.cooldown_ready?(state, key, lonely_cooldown(state, id, key, closest, params)) do
      {:lonely, key, closest, []}
    end
  end

  # Speak up to the person who was hostile to someone this character cares about.
  defp trigger(:protective, state, %Character{id: id}, people, params) do
    witnessed = Map.get(params.witnessed, id, [])

    # Apologies this character knows of, to set against what they saw.
    apologies =
      if witnessed == [],
        do: [],
        else:
          state
          |> Memories.for_character(id)
          |> Enum.filter(&match?(%Memory{data: %{"event" => "apology_offered"}}, &1))

    witnessed
    |> Enum.reject(&made_amends?(&1, apologies))
    |> Enum.find_value(fn %Memory{data: %{"from" => person, "to" => friend}} = memory ->
      # One protest per incident, and one per person and friend a day however
      # many hostile messages were witnessed.
      incident = "proactive:#{id}:protested:#{memory.topic}"
      pair = "proactive:#{id}:protective:#{person}:#{friend}"

      if person in people and friend != id and
           State.get_relationship(state, id, friend).affinity >= params.protective_affinity and
           State.cooldown_ready?(state, incident, :once) and
           State.cooldown_ready?(state, pair, params.cooldown_hours) do
        {:protective, [incident, pair], person, memories: [memory]}
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
           false <- saw_it_firsthand?(memory, Map.get(params.witnessed, id, [])),
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

  defp lonely_cooldown(state, id, key, person, params) do
    case Map.fetch(state.cooldowns, key) do
      {:ok, sent} ->
        replied? =
          case Map.fetch(state.cooldowns, Aethrion.Rules.Reply.contact_key(id, person)) do
            {:ok, contact} -> contact >= sent
            :error -> false
          end

        if replied?, do: params.cooldown_hours, else: params.unanswered_hours

      :error ->
        params.cooldown_hours
    end
  end

  # Characters about to spend time together this tick (enqueued by
  # `Aethrion.Rules.Companionship`).
  defp heading_out(%Transition{follow_ups: follow_ups}) do
    for %{type: :time_spent_together, from: from, to: to} <- follow_ups,
        id <- [from, to],
        into: MapSet.new(),
        do: id
  end

  # Hearing about harsh words from someone they saw be hostile themselves is
  # not news worth asking about.
  defp saw_it_firsthand?(
         %Memory{data: %{"event" => "message_sent", "tone" => tone, "from" => person}},
         witnessed
       )
       when tone in ["hostile", "cold"],
       do: Enum.any?(witnessed, &(&1.data["from"] == person))

  defp saw_it_firsthand?(_memory, _witnessed), do: false

  # The person apologized to the friend after the hostility (event ids count up).
  defp made_amends?(%Memory{data: %{"from" => person, "to" => friend}} = hostile, apologies) do
    Enum.any?(apologies, fn apology ->
      apology.data["from"] == person and apology.data["to"] == friend and
        event_number(apology) >= event_number(hostile)
    end)
  end

  defp event_number(%Memory{topic: topic}) do
    case Regex.run(~r/:e(\d+)$/, topic || "") do
      [_, digits] -> String.to_integer(digits)
      nil -> 0
    end
  end

  # A once-per-topic key (curiosity, a protest) only matters while its memory
  # is unfaded, and faded memories never come back, so on each tick keys for
  # anything else are dropped; otherwise they would pile up in long-running
  # worlds.
  defp prune_once_keys(
         %Transition{event: %{type: :time_tick}, state: state} = transition,
         heard,
         witnessed
       ) do
    live =
      MapSet.new(
        for(
          {id, memories} <- heard,
          memory <- memories,
          do: "proactive:#{id}:curious:#{memory.topic}"
        ) ++
          for(
            {id, memories} <- witnessed,
            memory <- memories,
            do: "proactive:#{id}:protested:#{memory.topic}"
          )
      )

    prefixes =
      for id <- Map.keys(state.characters),
          kind <- ["curious", "protested"],
          do: "proactive:#{id}:#{kind}:"

    cooldowns =
      Map.filter(state.cooldowns, fn {key, _at} ->
        not String.starts_with?(key, prefixes) or MapSet.member?(live, key)
      end)

    if map_size(cooldowns) == map_size(state.cooldowns),
      do: transition,
      else: Transition.put_state(transition, %{state | cooldowns: cooldowns})
  end

  defp prune_once_keys(transition, _heard, _witnessed), do: transition

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
    state = transition.state

    since_contact =
      case Map.fetch(state.cooldowns, Aethrion.Rules.Reply.contact_key(character.id, recipient)) do
        {:ok, at} -> max(state.clock - at, 0)
        :error -> nil
      end

    request =
      Expression.build_request(
        state,
        :proactive_message,
        character.id,
        recipient,
        opts |> Keyword.put(:reason, reason) |> Keyword.put(:since_contact, since_contact)
      )

    output =
      Output.proactive_message(character.id, recipient, reason, request.fallback_text,
        memory_refs: Enum.map(request.memories, & &1.id),
        context: request
      )

    transition
    |> then(fn transition ->
      key |> List.wrap() |> Enum.reduce(transition, &Transition.put_cooldown(&2, &1))
    end)
    |> Transition.put_cooldown(gap_key(character.id))
    |> Transition.emit(output)
    |> Transition.log("[Output] #{character.name} -> #{recipient}: \"#{output.text}\"")
  end
end
