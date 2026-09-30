defmodule Aethrion.Rules.Gift do
  @moduledoc """
  The receiver of a gift grows fonder of the giver, feels happier, less
  lonely, and less jealous (someone thought of them), and remembers the gift.
  """

  use Aethrion.Rule,
    id: :gift,
    description:
      "Receiver: affinity toward giver +10, joy +20, loneliness -10, jealousy -10, remembers the gift.",
    params: [
      affinity_delta: 10,
      joy_delta: 20,
      loneliness_delta: -10,
      jealousy_delta: -10,
      importance: 60
    ]

  alias Aethrion.{Memory, Transition}

  @impl true
  def apply(%Transition{event: event} = transition) do
    memory =
      Memory.new(
        id: "memory:#{event.to}:gift:#{event.id}",
        character_id: event.to,
        content: "#{event.from} gave #{event.to} a #{event.item}.",
        importance: Transition.param(transition, :importance),
        created_at: event.at,
        related_characters: [event.from],
        kind: :experienced,
        topic: topic(event),
        data: data(event)
      )

    transition
    |> Transition.adjust_relationship(
      event.to,
      event.from,
      :affinity,
      Transition.param(transition, :affinity_delta)
    )
    |> Transition.adjust_character(event.to, :joy, Transition.param(transition, :joy_delta))
    |> Transition.adjust_character(
      event.to,
      :loneliness,
      Transition.param(transition, :loneliness_delta)
    )
    |> Transition.adjust_character(
      event.to,
      :jealousy,
      Transition.param(transition, :jealousy_delta)
    )
    |> Transition.remember(memory)
  end

  @doc false
  def topic(event), do: "gift:#{event.id}"

  @doc false
  def data(event) do
    %{"event" => "gift_received", "from" => event.from, "to" => event.to, "item" => event.item}
  end
end
