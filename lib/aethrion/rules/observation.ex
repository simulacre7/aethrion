defmodule Aethrion.Rules.Observation do
  @moduledoc """
  Characters who see a gift remember it (inactive or blocked characters see
  nothing). Observers who care about the giver
  (affinity >= 30) also become jealous and tense toward the receiver.

  Trait modifiers: `:sensitive` +5 jealousy, `:calm` -5 jealousy.
  """

  use Aethrion.Rule,
    id: :observation,
    description:
      "Observers remember the gift; those who care about the giver get jealous (+10, sensitive +5, calm -5) and tense toward the receiver (+8).",
    params: [
      care_threshold: 30,
      jealousy_delta: 10,
      sensitive_bonus: 5,
      calm_reduction: 5,
      tension_delta: 8,
      importance: 60
    ]

  alias Aethrion.{Character, Memory, State, Transition}
  alias Aethrion.Rules.Gift

  @impl true
  def apply(%Transition{event: event} = transition) do
    event
    |> Map.get(:observed_by, [])
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [event.from, event.to]))
    |> Enum.filter(&(transition.state |> State.character(&1) |> Character.can_act?()))
    |> Enum.reduce(transition, &observe(&2, &1))
  end

  defp observe(%Transition{event: event, state: state} = transition, observer_id) do
    observer = State.character(state, observer_id)

    cares? =
      State.get_relationship(state, observer_id, event.from).affinity >=
        Transition.param(transition, :care_threshold)

    transition
    |> Transition.note(
      "#{observer.name} noticed the gift to #{Transition.name(transition, event.to)}",
      subject: observer_id
    )
    |> then(fn transition ->
      if cares? do
        transition
        |> Transition.adjust_character(
          observer_id,
          :jealousy,
          jealousy_delta(transition, observer)
        )
        |> Transition.adjust_relationship(
          observer_id,
          event.to,
          :tension,
          Transition.param(transition, :tension_delta)
        )
      else
        transition
      end
    end)
    |> Transition.remember(
      Memory.new(
        id: "memory:#{observer_id}:observed:#{event.id}",
        character_id: observer_id,
        content: "#{observer_id} saw #{event.from} give #{event.to} a #{event.item}.",
        importance: Transition.param(transition, :importance),
        created_at: event.at,
        related_characters: [event.from, event.to],
        kind: :observed,
        topic: Gift.topic(event),
        data: Gift.data(event)
      )
    )
  end

  defp jealousy_delta(transition, %Character{} = observer) do
    bonus =
      if Character.trait?(observer, :sensitive),
        do: Transition.param(transition, :sensitive_bonus),
        else: 0

    reduction =
      if Character.trait?(observer, :calm),
        do: Transition.param(transition, :calm_reduction),
        else: 0

    Transition.param(transition, :jealousy_delta) + bonus - reduction
  end
end
