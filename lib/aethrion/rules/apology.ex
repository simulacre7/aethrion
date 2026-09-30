defmodule Aethrion.Rules.Apology do
  @moduledoc """
  An apology eases jealousy, loneliness, and stress, and builds trust.

  Apologies wear thin: for each earlier apology from the same person the
  receiver still remembers (about a week), the trust gained and the tension
  eased are halved, so a cycle of insults and apologies does not keep
  building trust.
  """

  use Aethrion.Rule,
    id: :apology,
    description:
      "Receiver: jealousy -15, loneliness -6, stress -10, trust +8 and tension -10 toward the apologizer (halved per remembered earlier apology), remembers the apology.",
    params: [
      trust_delta: 8,
      jealousy_delta: -15,
      loneliness_delta: -6,
      stress_delta: -10,
      tension_delta: -10,
      importance: 70
    ]

  alias Aethrion.{Memories, Memory, Transition}

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

    earlier = earlier_apologies(transition.state, event)
    halve = &div(&1, Integer.pow(2, earlier))

    note =
      case earlier do
        0 ->
          "#{receiver_name} accepted an apology from #{event.from}"

        n ->
          "#{receiver_name} accepted an apology from #{event.from}, " <>
            "but has heard #{n} before and trusts it less"
      end

    transition
    |> Transition.note(note, subject: event.to)
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
      halve.(Transition.param(transition, :trust_delta))
    )
    |> ease_tension(event.to, event.from, halve.(Transition.param(transition, :tension_delta)))
    |> Transition.remember(memory)
  end

  @doc false
  # Unfaded apologies the receiver remembers from the same person.
  def earlier_apologies(state, %{from: from, to: to}) do
    state
    |> Memories.for_character(to)
    |> Enum.count(
      &match?(
        %Memory{kind: :experienced, data: %{"event" => "apology_offered", "from" => ^from}},
        &1
      )
    )
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
