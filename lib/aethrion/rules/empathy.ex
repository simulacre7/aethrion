defmodule Aethrion.Rules.Empathy do
  @moduledoc """
  A listener who cares about a struggling teller (affinity >= 25) and is not
  struggling themselves offers comfort, at most once per 12 simulated hours per
  pair. Comfort is enqueued as a `:comfort_offered` event.
  """

  use Aethrion.Rule,
    id: :empathy,
    description:
      "A caring listener (affinity >= 25) comforts a struggling teller, once per 12h per pair."

  alias Aethrion.{Character, CharacterState, Event, State, Transition}
  alias Aethrion.Rules.{Comfort, Mood}

  @affinity_threshold 25

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    listener = State.character(state, event.to)
    teller = State.character(state, event.from)

    if Character.can_act?(listener) and
         State.get_relationship(state, listener.id, teller.id).affinity >= @affinity_threshold and
         CharacterState.distressed?(Mood.derive(teller.state)) and
         not CharacterState.distressed?(Mood.derive(listener.state)) and
         Transition.cooldown_ready?(transition, Comfort.cooldown_key(listener.id, teller.id), 12) do
      Transition.enqueue(transition, Event.comfort_offered(listener.id, teller.id, at: event.at))
    else
      transition
    end
  end
end
