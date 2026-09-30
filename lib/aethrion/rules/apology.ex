defmodule Aethrion.Rules.Apology do
  @moduledoc """
  An apology eases jealousy, loneliness, and stress, and builds trust.
  """

  use Aethrion.Rule,
    id: :apology,
    description:
      "Receiver: jealousy -15, loneliness -6, stress -10, trust toward apologizer +8, remembers the apology.",
    params: [
      trust_delta: 8,
      jealousy_delta: -15,
      loneliness_delta: -6,
      stress_delta: -10,
      importance: 70
    ]

  alias Aethrion.{Memory, Transition}

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
        topic: "apology:#{event.id}",
        data: %{
          "event" => "apology_offered",
          "from" => event.from,
          "to" => event.to,
          "reason" => event.reason
        }
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
    |> Transition.remember(memory)
  end
end
