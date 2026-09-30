defmodule Aethrion.Rules.Proactive do
  @moduledoc """
  Characters reach out to people (actors who are not characters, such as
  `"user"`) on their own when social pressure crosses a threshold. At most one
  proactive message per character per event.

  Who they reach out to: jealousy goes to whoever gave the gift they saw,
  loneliness to the person they feel closest to, and curiosity to the person
  the news is about. A world with no relationships to people addresses
  `"user"`.

  Characters do not reach out to someone they currently feel tense toward
  (tension >= 10); they turn to friends instead.

  | reason     | condition                                                  | cooldown |
  | ---------- | ---------------------------------------------------------- | -------- |
  | `:jealous` | jealousy >= 15 and jealousy + loneliness >= 45             | 24h      |
  | `:lonely`  | loneliness >= 60 and jealousy < 15                         | 24h      |
  | `:curious` | heard secondhand news about a person and is `:playful` or has affinity >= 30 toward them | once per topic |
  """

  use Aethrion.Rule,
    id: :proactive,
    description:
      "Jealous (pressure>=45), lonely (>=60), or curious (heard news about the user) characters message the user.",
    params: [
      jealousy_floor: 15,
      pressure_threshold: 45,
      loneliness_threshold: 60,
      cooldown_hours: 24,
      curious_affinity: 30,
      avoid_tension: 10
    ]

  alias Aethrion.{Character, Expression, Memories, Memory, Output, State, Transition}

  @default_recipient "user"

  @impl true
  def apply(%Transition{} = transition) do
    state = transition.state
    params = Map.new(params(), fn {key, _default} -> {key, Transition.param(transition, key)} end)

    # Checked on every event: curiosity can become possible after any change
    # (affinity rising, tension easing, a character being unblocked).
    heard = heard_about_people(state)

    params = Map.put(params, :heard, heard)
    outgoing = State.relationships_by_from(state)

    state
    |> State.sorted_characters()
    |> Enum.filter(&(Character.can_act?(&1) and could_reach_out?(&1, params)))
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

  # Cheap numeric pre-check so people are only computed for characters who
  # might actually reach out.
  defp could_reach_out?(%Character{id: id, state: cs}, params) do
    (cs.jealousy >= params.jealousy_floor and
       cs.jealousy + cs.loneliness >= params.pressure_threshold) or
      cs.loneliness >= params.loneliness_threshold or Map.has_key?(params.heard, id)
  end

  defp first_trigger(_state, _character, [], _params), do: nil

  defp first_trigger(state, character, people, params) do
    Enum.find_value([:jealous, :lonely, :curious], &trigger(&1, state, character, people, params))
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

  # Unfaded secondhand memories involving someone who is not a character, by
  # character, newest first.
  defp heard_about_people(state) do
    for %Memory{kind: :heard} = memory <- state.memories,
        not Memory.faded?(memory),
        Enum.any?(memory.related_characters, &(not State.character?(state, &1))),
        reduce: %{} do
      acc -> Map.update(acc, memory.character_id, [memory], &(&1 ++ [memory]))
    end
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
    |> Transition.emit(output)
    |> Transition.log("[Output] #{character.name} -> #{recipient}: \"#{output.text}\"")
  end
end
