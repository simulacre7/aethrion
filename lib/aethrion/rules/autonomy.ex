defmodule Aethrion.Rules.Autonomy do
  @moduledoc """
  Characters act on their own as time passes.

  A character who is struggling (jealous, lonely, or upset) or who has the
  `:talkative` trait confides a notable firsthand memory (importance >= 60) to
  their most trusted friend (trust >= 30) who has not heard about it yet.
  Talkative characters also pass on secondhand news (`:heard` memories with
  importance >= 30). Because each retelling loses importance (see
  `Aethrion.Rules.Gossip`), rumors die out after a few hops. At most one
  confidence per character per tick.

  Harsh words the teller knows were apologized for are not passed on.

  The confidence is enqueued as a `:gossip_shared` event, so it goes through
  validation and the gossip rules like any other event.
  """

  use Aethrion.Rule,
    id: :autonomy,
    description:
      "Struggling or talkative characters confide a notable memory to their most trusted friend; talkative ones retell rumors.",
    params: [notable_importance: 60, retell_importance: 30, trust_threshold: 30]

  alias Aethrion.{Character, CharacterState, Event, Memories, Memory, State, Transition}
  alias Aethrion.Rules.Mood

  @impl true
  def apply(%Transition{} = transition) do
    # Index memories once: autonomy only enqueues events, so the state it reads
    # does not change while it runs.
    memories = Enum.group_by(transition.state.memories, & &1.character_id)

    known =
      Map.new(memories, fn {id, list} ->
        {id, MapSet.new(Enum.flat_map(list, &Memories.topics/1))}
      end)

    outgoing = State.relationships_by_from(transition.state)

    transition.state
    |> State.sorted_characters()
    |> Enum.filter(&wants_to_confide?(transition.state, &1))
    |> Enum.reduce(transition, &confide(&2, &1, memories, known, outgoing))
  end

  defp wants_to_confide?(state, %Character{} = character) do
    Character.can_act?(character) and
      (CharacterState.distressed?(Mood.derive(character.state, state)) or
         Character.trait?(character, :talkative))
  end

  defp confide(
         %Transition{state: state} = transition,
         %Character{} = teller,
         memories,
         known,
         outgoing
       ) do
    threshold = Transition.param(transition, :trust_threshold)

    confidants =
      confidants(state, candidates(state, teller.id, outgoing, threshold), threshold)

    thresholds =
      {Transition.param(transition, :notable_importance),
       Transition.param(transition, :retell_importance)}

    knows? = fn id, topic -> known |> Map.get(id, MapSet.new()) |> MapSet.member?(topic) end

    mine = Map.get(memories, teller.id, [])

    candidate =
      mine
      # Harsh words the teller knows were apologized for are not passed on.
      |> Enum.reject(&(Memory.faded?(&1) or Memories.made_amends?(&1, mine)))
      |> Enum.filter(&notable?(&1, teller, thresholds))
      |> Enum.find_value(fn memory ->
        case Enum.find(confidants, &(not knows?.(&1, memory.topic))) do
          nil -> nil
          confidant -> {memory, confidant}
        end
      end)

    case candidate do
      {memory, confidant} ->
        Transition.enqueue(
          transition,
          Event.gossip_shared(teller.id, confidant, memory.id, at: transition.event.now)
        )

      nil ->
        transition
    end
  end

  defp notable?(%Memory{topic: topic}, _teller, _thresholds) when not is_binary(topic),
    do: false

  # Impressions are private summaries, not news.
  defp notable?(%Memory{kind: :impression}, _teller, _thresholds), do: false

  defp notable?(%Memory{kind: :heard} = memory, teller, {_notable, retell}) do
    Character.trait?(teller, :talkative) and memory.importance >= retell
  end

  defp notable?(%Memory{} = memory, _teller, {notable, _retell}),
    do: memory.importance >= notable

  # Most trusted first; ties broken by id.
  # With a positive threshold only existing relationships can clear it (missing
  # ones count as 0), so the teller's outgoing relationships are enough. A
  # threshold of 0 or less also admits characters with no relationship at all.
  defp candidates(state, id, _outgoing, threshold) when threshold <= 0 do
    state
    |> State.sorted_characters()
    |> Enum.map(&State.get_relationship(state, id, &1.id))
  end

  defp candidates(_state, id, outgoing, _threshold), do: Map.get(outgoing, id, [])

  defp confidants(state, relationships, trust_threshold) do
    relationships
    |> Enum.filter(fn relationship ->
      relationship.trust >= trust_threshold and relationship.to != relationship.from and
        available?(state, relationship.to)
    end)
    |> Enum.sort_by(&{-&1.trust, &1.to})
    |> Enum.map(& &1.to)
  end

  defp available?(state, id) do
    case State.character(state, id) do
      %Character{} = character -> Character.can_act?(character)
      nil -> false
    end
  end
end
