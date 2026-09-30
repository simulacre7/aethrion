defmodule Aethrion.Rules.Comfort do
  @moduledoc """
  Being comforted eases loneliness, jealousy, and stress and strengthens the
  bond with the comforter.
  """

  use Aethrion.Rule,
    id: :comfort,
    description:
      "Receiver: loneliness -12, jealousy -5, stress -10, trust +5, affinity +3, and tension -5 toward the comforter, remembers it.",
    params: [
      loneliness_delta: -12,
      jealousy_delta: -5,
      stress_delta: -10,
      trust_delta: 5,
      affinity_delta: 3,
      tension_delta: -5,
      importance: 55
    ]

  alias Aethrion.{Expression, Memory, Output, State, Transition}

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    transition =
      transition
      |> Transition.put_cooldown(cooldown_key(event.from, event.to))
      |> Transition.adjust_character(event.to, :loneliness, param(transition, :loneliness_delta))
      |> Transition.adjust_character(event.to, :jealousy, param(transition, :jealousy_delta))
      |> Transition.adjust_character(event.to, :stress, param(transition, :stress_delta))
      |> Transition.adjust_relationship(
        event.to,
        event.from,
        :trust,
        param(transition, :trust_delta)
      )
      |> Transition.adjust_relationship(
        event.to,
        event.from,
        :affinity,
        param(transition, :affinity_delta)
      )
      |> Aethrion.Rules.Apology.ease_tension(
        event.to,
        event.from,
        param(transition, :tension_delta)
      )
      |> Transition.remember(
        Memory.new(
          id: "memory:#{event.to}:comfort:#{event.id}",
          character_id: event.to,
          content: "#{event.from} comforted #{event.to}.",
          importance: param(transition, :importance),
          created_at: event.at,
          related_characters: [event.from],
          kind: :experienced,
          topic: "comfort:#{event.id}",
          data: %{"event" => "comfort_offered", "from" => event.from, "to" => event.to}
        )
      )

    if State.character?(state, event.from) do
      request =
        Expression.build_request(state, :character_interaction, event.from, event.to,
          reason: :comfort,
          memories: []
        )

      transition
      |> Transition.emit(
        Output.character_interaction(:comfort, event.from, event.to, request.fallback_text,
          context: request
        )
      )
      |> Transition.log("[Scene] #{request.fallback_text}")
    else
      transition
    end
  end

  @doc false
  def cooldown_key(from, to), do: "comfort:#{from}:#{to}"

  defp param(transition, key), do: Transition.param(transition, key)
end
