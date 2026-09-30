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

  The confidence is enqueued as a `:gossip_shared` event, so it goes through
  validation and the gossip rules like any other event.
  """

  use Aethrion.Rule,
    id: :autonomy,
    description:
      "Struggling or talkative characters confide a notable memory to their most trusted friend; talkative ones retell rumors."

  alias Aethrion.{Character, CharacterState, Event, Memories, Memory, State, Transition}
  alias Aethrion.Rules.Mood

  @notable_importance 60
  @retell_importance 30
  @trust_threshold 30

  @impl true
  def apply(%Transition{} = transition) do
    transition.state
    |> State.sorted_characters()
    |> Enum.filter(&wants_to_confide?/1)
    |> Enum.reduce(transition, &confide(&2, &1))
  end

  defp wants_to_confide?(%Character{} = character) do
    Character.can_act?(character) and
      (CharacterState.distressed?(Mood.derive(character.state)) or
         Character.trait?(character, :talkative))
  end

  defp confide(%Transition{state: state} = transition, %Character{} = teller) do
    confidants = confidants(state, teller.id)

    candidate =
      state
      |> Memories.for_character(teller.id)
      |> Enum.filter(&notable?(&1, teller))
      |> Enum.find_value(fn memory ->
        case Enum.find(confidants, &(not Memories.knows_topic?(state, &1, memory.topic))) do
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

  defp notable?(%Memory{topic: topic}, _teller) when not is_binary(topic), do: false

  defp notable?(%Memory{kind: :heard} = memory, teller) do
    Character.trait?(teller, :talkative) and memory.importance >= @retell_importance
  end

  defp notable?(%Memory{} = memory, _teller), do: memory.importance >= @notable_importance

  # Most trusted first; ties broken by id.
  defp confidants(state, teller_id) do
    state
    |> State.sorted_characters()
    |> Enum.filter(&(&1.id != teller_id and Character.can_act?(&1)))
    |> Enum.map(&{State.get_relationship(state, teller_id, &1.id).trust, &1.id})
    |> Enum.filter(fn {trust, _id} -> trust >= @trust_threshold end)
    |> Enum.sort_by(fn {trust, id} -> {-trust, id} end)
    |> Enum.map(&elem(&1, 1))
  end
end
