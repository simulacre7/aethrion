defmodule Aethrion.Rules.Companionship do
  @moduledoc """
  Lonely characters seek out a friend.

  On each tick, a character whose mood is `:lonely` invites the friend they
  like most (affinity >= 30) who can act, at most once per 12 simulated hours
  per pair. Each character joins at most one outing per tick. The outing is
  enqueued as a `:time_spent_together` event.
  """

  use Aethrion.Rule,
    id: :companionship,
    description:
      "Lonely characters invite their closest friend (affinity >= 30) to spend time together, once per 12h per pair.",
    params: [affinity_threshold: 30, cooldown_hours: 12]

  alias Aethrion.{Character, Event, State, Transition}
  alias Aethrion.Rules.{Mood, Together}

  @impl true
  def apply(%Transition{state: state} = transition) do
    threshold = Transition.param(transition, :affinity_threshold)
    cooldown = Transition.param(transition, :cooldown_hours)

    state
    |> State.sorted_characters()
    |> Enum.filter(&(Character.can_act?(&1) and Mood.derive(&1.state, state) == :lonely))
    |> Enum.reduce({transition, MapSet.new()}, fn character, {transition, busy} ->
      friend =
        if MapSet.member?(busy, character.id),
          do: nil,
          else: closest_friend(state, character.id, threshold, busy, cooldown)

      case friend do
        nil ->
          {transition, busy}

        friend ->
          event = Event.time_spent_together(character.id, friend, at: transition.event.now)

          {Transition.enqueue(transition, event),
           busy |> MapSet.put(character.id) |> MapSet.put(friend)}
      end
    end)
    |> elem(0)
  end

  # Highest affinity first; ties broken by id.
  defp closest_friend(state, id, threshold, busy, cooldown) do
    state
    |> State.sorted_characters()
    |> Enum.filter(&(&1.id != id and Character.can_act?(&1) and not MapSet.member?(busy, &1.id)))
    |> Enum.map(&{State.get_relationship(state, id, &1.id).affinity, &1.id})
    |> Enum.filter(fn {affinity, friend} ->
      affinity >= threshold and
        State.cooldown_ready?(state, Together.cooldown_key(id, friend), cooldown)
    end)
    |> Enum.sort_by(fn {affinity, friend} -> {-affinity, friend} end)
    |> Enum.map(&elem(&1, 1))
    |> List.first()
  end
end
