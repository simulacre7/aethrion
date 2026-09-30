defmodule Aethrion.Rules.Apology do
  @moduledoc """
  An apology eases jealousy, loneliness, and stress, and builds trust.
  """

  use Aethrion.Rule,
    id: :apology,
    description:
      "Receiver: jealousy -15, loneliness -6, stress -10, trust +8 and tension -10 toward the apologizer, remembers the apology.",
    params: [
      trust_delta: 8,
      jealousy_delta: -15,
      loneliness_delta: -6,
      stress_delta: -10,
      tension_delta: -10,
      importance: 70
    ]

  alias Aethrion.{Memory, Transition}

  @doc false
  # Eases existing tension without pushing it below zero.
  def ease_tension(transition, from, to, delta) do
    current = Aethrion.State.get_relationship(transition.state, from, to).tension

    if current > 0,
      do: Transition.adjust_relationship(transition, from, to, :tension, max(delta, -current)),
      else: transition
  end

  @impl true
  def apply(%Transition{event: event} = transition) do
    receiver_name = Transition.name(transition, event.to)

    memory =
      Memory.new(
        id: "memory:#{event.to}:apology:#{event.id}",
        character_id: event.to,
        content: "#{event.from} apologized to #{event.to}: #{event.reason}",
        importance: Transition.param(transition, :importance),
        created_at: event.at,
        related_characters: [event.from],
        kind: :experienced,
        topic: topic(event),
        data: data(event)
      )

    transition
    |> Transition.note("#{receiver_name} accepted an apology from #{event.from}",
      subject: event.to
    )
    |> Transition.adjust_character(
      event.to,
      :jealousy,
      Transition.param(transition, :jealousy_delta)
    )
    |> Transition.adjust_character(
      event.to,
      :loneliness,
      Transition.param(transition, :loneliness_delta)
    )
    |> Transition.adjust_character(event.to, :stress, Transition.param(transition, :stress_delta))
    |> Transition.adjust_relationship(
      event.to,
      event.from,
      :trust,
      Transition.param(transition, :trust_delta)
    )
    |> ease_tension(event.to, event.from, Transition.param(transition, :tension_delta))
    |> Transition.remember(memory)
  end

  @doc false
  def topic(event), do: "apology:#{event.id}"

  @doc false
  def data(event) do
    %{
      "event" => "apology_offered",
      "from" => event.from,
      "to" => event.to,
      "reason" => event.reason
    }
  end
end
