defmodule Aethrion.Rules.Comfort do
  @moduledoc """
  Being comforted eases loneliness, jealousy, and stress and strengthens the
  bond with the comforter.
  """

  use Aethrion.Rule,
    id: :comfort,
    description:
      "Receiver: loneliness -12, jealousy -5, stress -10, trust +5 and affinity +3 toward the comforter, remembers it."

  alias Aethrion.{Expression, Memory, Output, State, Transition}

  @importance 55

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    transition =
      transition
      |> Transition.put_cooldown(cooldown_key(event.from, event.to))
      |> Transition.adjust_character(event.to, :loneliness, -12)
      |> Transition.adjust_character(event.to, :jealousy, -5)
      |> Transition.adjust_character(event.to, :stress, -10)
      |> Transition.adjust_relationship(event.to, event.from, :trust, 5)
      |> Transition.adjust_relationship(event.to, event.from, :affinity, 3)
      |> Transition.remember(
        Memory.new(
          id: "memory:#{event.to}:comfort:#{event.id}",
          character_id: event.to,
          content: "#{event.from} comforted #{event.to}.",
          importance: @importance,
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
end
