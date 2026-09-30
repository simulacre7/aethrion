defmodule Aethrion.Rules.Together do
  @moduledoc """
  Two characters spend time together. Both feel less lonely and a little
  happier, grow fonder of each other, and remember it.
  """

  use Aethrion.Rule,
    id: :together,
    description:
      "Both: loneliness -25, joy +6, affinity toward each other +2 (up to 60); both remember the time together.",
    params: [
      loneliness_delta: -25,
      joy_delta: 6,
      affinity_delta: 2,
      affinity_cap: 60,
      importance: 40
    ]

  alias Aethrion.{Expression, Memory, Output, Transition}

  # Time together deepens a friendship up to a point; past `affinity_cap`,
  # afternoons are comfortable rather than ever closer.
  defp grow_fonder(transition, me, other) do
    room =
      Transition.param(transition, :affinity_cap) -
        Aethrion.State.get_relationship(transition.state, me, other).affinity

    case min(Transition.param(transition, :affinity_delta), room) do
      delta when delta > 0 ->
        Transition.adjust_relationship(transition, me, other, :affinity, delta)

      _none ->
        transition
    end
  end

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    pair = [{event.from, event.to}, {event.to, event.from}]

    request =
      Expression.build_request(state, :character_interaction, event.from, event.to,
        reason: :together,
        memories: []
      )

    transition =
      transition
      |> Transition.put_cooldown(cooldown_key(event.from, event.to))

    pair
    |> Enum.reduce(transition, fn {me, other}, transition ->
      transition
      |> Transition.adjust_character(
        me,
        :loneliness,
        Transition.param(transition, :loneliness_delta)
      )
      |> Transition.adjust_character(me, :joy, Transition.param(transition, :joy_delta))
      |> grow_fonder(me, other)
      |> Transition.remember(
        Memory.new(
          id: "memory:#{me}:together:#{event.id}",
          character_id: me,
          content: "#{me} spent time with #{other}.",
          importance: Transition.param(transition, :importance),
          created_at: event.at,
          related_characters: [other],
          kind: :experienced,
          topic: "together:#{event.id}",
          data: %{"event" => "time_spent_together", "from" => other, "to" => me}
        )
      )
    end)
    |> Transition.emit(
      Output.character_interaction(:together, event.from, event.to, request.fallback_text,
        context: request
      )
    )
    |> Transition.log("[Scene] #{request.fallback_text}")
  end

  @doc false
  def cooldown_key(a, b) do
    [first, second] = Enum.sort([a, b])
    "together:#{first}:#{second}"
  end
end
