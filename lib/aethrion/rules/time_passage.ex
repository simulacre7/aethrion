defmodule Aethrion.Rules.TimePassage do
  @moduledoc """
  Advances the simulated clock. Joy and stress settle back toward zero, and
  jealousy and tension fade a little each day.

  Active characters grow lonely only after a quiet stretch: loneliness rises
  for each hour more than `quiet_hours` (16) after the character last had
  company. Anything that eases a character's loneliness (a kind or plain
  message, a gift, an apology, comfort, gossip, time together) counts as
  company. A character who has never had company in this world grows lonely
  from the start. Hours are counted the same however time is split into
  ticks.
  """

  use Aethrion.Rule,
    id: :time_passage,
    description:
      "Advances the clock; per hour for active characters: loneliness +2 after 16 quiet hours, joy -2, stress -2; per day: jealousy -5, tension -2.",
    params: [
      loneliness_per_hour: 2,
      quiet_hours: 16,
      joy_per_hour: -2,
      stress_per_hour: -2,
      jealousy_per_day: -5,
      tension_per_day: -2
    ]

  alias Aethrion.{State, Transition}

  @doc false
  # When a character last had company, as a cooldown key.
  @spec company_key(String.t()) :: String.t()
  def company_key(character_id), do: "company:#{character_id}"

  @impl true
  def apply(%Transition{event: %{hours: hours, now: now}} = transition) do
    state = transition.state
    transition = Transition.put_state(transition, %{state | clock: state.clock + hours})
    per_hour = Transition.param(transition, :loneliness_per_hour)
    quiet = Transition.param(transition, :quiet_hours)
    joy = hours * Transition.param(transition, :joy_per_hour)
    stress = hours * Transition.param(transition, :stress_per_hour)
    to_clock = state.clock + hours

    transition =
      transition.state
      |> State.sorted_characters()
      |> Enum.filter(& &1.state.active?)
      |> Enum.reduce(transition, fn character, transition ->
        lonely_hours = quiet_hours_between(state, character.id, quiet, state.clock, to_clock)

        transition
        |> Transition.adjust_character(character.id, :loneliness, lonely_hours * per_hour,
          log: false
        )
        |> Transition.adjust_character(character.id, :joy, joy, log: false)
        |> Transition.adjust_character(character.id, :stress, stress, log: false)
        |> Transition.set_character(character.id, :last_active_at, now)
      end)

    transition
    |> Transition.note(
      "#{hours}h passed: loneliness +#{per_hour} an hour for characters " <>
        "#{quiet}h or more without company (clock #{to_clock}h)"
    )
    |> ease_daily(state.clock, to_clock)
  end

  # Hours in [from, to) at least `quiet` hours after the character's last company.
  defp quiet_hours_between(state, id, quiet, from, to) do
    case Map.fetch(state.cooldowns, company_key(id)) do
      {:ok, at} -> max(to - max(from, at + quiet), 0)
      :error -> to - from
    end
  end

  # Jealousy and tension ease once per simulated day boundary crossed, so the
  # result does not depend on how time was split into ticks.
  defp ease_daily(transition, from_clock, to_clock) do
    case div(to_clock, 24) - div(from_clock, 24) do
      0 ->
        transition

      days ->
        transition
        |> ease_jealousy(days * Transition.param(transition, :jealousy_per_day))
        |> ease_tension(days * Transition.param(transition, :tension_per_day))
    end
  end

  defp ease_jealousy(transition, 0), do: transition

  defp ease_jealousy(transition, delta) do
    transition.state
    |> State.sorted_characters()
    |> Enum.filter(&(&1.state.jealousy > 0))
    |> Enum.reduce(transition, fn character, transition ->
      Transition.adjust_character(transition, character.id, :jealousy, delta, log: false)
    end)
  end

  defp ease_tension(transition, 0), do: transition

  defp ease_tension(transition, delta) do
    transition.state.relationships
    |> Map.values()
    |> Enum.filter(&(&1.tension > 0))
    |> Enum.sort_by(&{&1.from, &1.to})
    |> Enum.reduce(transition, fn relationship, transition ->
      change = max(delta, -relationship.tension)

      Transition.adjust_relationship(
        transition,
        relationship.from,
        relationship.to,
        :tension,
        change,
        log: false,
        output: false
      )
    end)
  end
end
