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

  History changes how a message lands. Impressions are built by
  `Aethrion.Rules.Consolidation` from faded memories:

  - **Goodwill.** If the receiver holds impressions of at least 3 kind acts
    (warm messages, gifts, comfort) from the sender, cold and hostile effects
    are halved: the receiver gives the sender the benefit of the doubt.
  - **Wariness.** If the receiver holds an impression of at least 2 hostile
    messages from the sender, warm effects are halved.
  """

  use Aethrion.Rule,
    id: :message,
    description:
      "Tone-driven effects on the receiver: warm comforts, cold cools, hostile hurts; notable messages are remembered.",
    params: [
      warm_importance: 45,
      cold_importance: 35,
      hostile_importance: 65,
      goodwill_count: 3,
      goodwill_percent: 50,
      wariness_count: 2,
      wariness_percent: 50
    ]

  alias Aethrion.{Memory, Transition}
  alias Aethrion.Rules.Consolidation

  @effects %{
    warm: [relationship: [affinity: 4, trust: 2], character: [loneliness: -8, joy: 8]],
    neutral: [relationship: [], character: [loneliness: -4]],
    cold: [relationship: [affinity: -3, tension: 4], character: [joy: -5]],
    hostile: [
      relationship: [affinity: -8, trust: -6, tension: 10],
      character: [stress: 20, joy: -10]
    ]
  }

  @impl true
  def apply(%Transition{event: event} = transition) do
    effects = Map.fetch!(@effects, event.tone)
    {transition, percent} = history_modifier(transition)
    scale = fn delta -> div(delta * percent, 100) end

    transition =
      Enum.reduce(effects[:relationship], transition, fn {field, delta}, transition ->
        Transition.adjust_relationship(transition, event.to, event.from, field, scale.(delta))
      end)

    transition =
      Enum.reduce(effects[:character], transition, fn {field, delta}, transition ->
        Transition.adjust_character(transition, event.to, field, scale.(delta))
      end)

    case event.tone do
      :neutral ->
        transition

      tone ->
        importance = Transition.param(transition, :"#{tone}_importance")
        Transition.remember(transition, memory(event, importance))
    end
  end

  # Returns the percentage of the tone's normal effect that applies, noting why
  # when history changes it.
  defp history_modifier(%Transition{event: event, state: state} = transition) do
    count = &Consolidation.impression_count(state, event.to, &1, event.from)
    receiver = Transition.name(transition, event.to)
    sender = Transition.name(transition, event.from)

    cond do
      event.tone in [:cold, :hostile] and
          count.("warm") + count.("gift") + count.("comfort") >=
            Transition.param(transition, :goodwill_count) ->
        {Transition.note(
           transition,
           "#{receiver} gives #{sender} the benefit of the doubt after a long record of kindness",
           subject: event.to
         ), Transition.param(transition, :goodwill_percent)}

      event.tone == :warm and count.("hostile") >= Transition.param(transition, :wariness_count) ->
        {Transition.note(
           transition,
           "#{receiver} is wary of kindness from #{sender} after repeated hostility",
           subject: event.to
         ), Transition.param(transition, :wariness_percent)}

      true ->
        {transition, 100}
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
