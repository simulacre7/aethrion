defmodule Aethrion.Rules.Message do
  @moduledoc """
  A message changes how the receiver feels about the sender, according to its
  structured `tone`. Rules never parse the message text.

  | tone     | receiver effects                                                         |
  | -------- | ------------------------------------------------------------------------ |
  | warm     | affinity +4, trust +2, loneliness -8, joy +8, remembers it               |
  | neutral  | loneliness -4                                                            |
  | cold     | affinity -3, tension +4, joy -5, remembers it                            |
  | hostile  | affinity -8, trust -6, tension +10, stress +20, joy -10, remembers it    |
  """

  use Aethrion.Rule,
    id: :message,
    description:
      "Tone-driven effects on the receiver: warm comforts, cold cools, hostile hurts; notable messages are remembered."

  alias Aethrion.{Memory, Transition}

  @effects %{
    warm: [relationship: [affinity: 4, trust: 2], character: [loneliness: -8, joy: 8]],
    neutral: [relationship: [], character: [loneliness: -4]],
    cold: [relationship: [affinity: -3, tension: 4], character: [joy: -5]],
    hostile: [
      relationship: [affinity: -8, trust: -6, tension: 10],
      character: [stress: 20, joy: -10]
    ]
  }

  @importance %{warm: 45, cold: 35, hostile: 65}

  @impl true
  def apply(%Transition{event: event} = transition) do
    effects = Map.fetch!(@effects, event.tone)

    transition =
      Enum.reduce(effects[:relationship], transition, fn {field, delta}, transition ->
        Transition.adjust_relationship(transition, event.to, event.from, field, delta)
      end)

    transition =
      Enum.reduce(effects[:character], transition, fn {field, delta}, transition ->
        Transition.adjust_character(transition, event.to, field, delta)
      end)

    case Map.fetch(@importance, event.tone) do
      {:ok, importance} -> Transition.remember(transition, memory(event, importance))
      :error -> transition
    end
  end

  defp memory(event, importance) do
    Memory.new(
      id: "memory:#{event.to}:message:#{event.id}",
      character_id: event.to,
      content: "#{event.from} said to #{event.to} (#{event.tone}): \"#{event.text}\"",
      importance: importance,
      created_at: event.at,
      related_characters: [event.from],
      kind: :experienced,
      topic: "message:#{event.id}",
      data: %{
        "event" => "message_sent",
        "from" => event.from,
        "to" => event.to,
        "tone" => Atom.to_string(event.tone),
        "text" => event.text
      }
    )
  end
end
