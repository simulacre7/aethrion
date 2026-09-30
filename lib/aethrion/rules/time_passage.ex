defmodule Aethrion.Rules.TimePassage do
  @moduledoc """
  Advances the simulated clock. Active characters grow lonelier, and joy and
  stress settle back toward zero. Jealousy does not fade with time alone; it
  takes a social action such as an apology or comfort.
  """

  use Aethrion.Rule,
    id: :time_passage,
    description:
      "Advances the clock; per hour for active characters: loneliness +4, joy -2, stress -2; tension eases 2 per day.",
    params: [loneliness_per_hour: 4, joy_per_hour: -2, stress_per_hour: -2, tension_per_day: -2]

  alias Aethrion.{State, Transition}

  @impl true
  def apply(%Transition{event: %{hours: hours, now: now}} = transition) do
    state = transition.state
    transition = Transition.put_state(transition, %{state | clock: state.clock + hours})
    loneliness = hours * Transition.param(transition, :loneliness_per_hour)
    joy = hours * Transition.param(transition, :joy_per_hour)
    stress = hours * Transition.param(transition, :stress_per_hour)

    transition =
      transition.state
      |> State.sorted_characters()
      |> Enum.filter(& &1.state.active?)
      |> Enum.reduce(transition, fn character, transition ->
        transition
        |> Transition.adjust_character(character.id, :loneliness, loneliness, log: false)
        |> Transition.adjust_character(character.id, :joy, joy, log: false)
        |> Transition.adjust_character(character.id, :stress, stress, log: false)
        |> Transition.set_character(character.id, :last_active_at, now)
      end)

    transition
    |> Transition.note(
      "time_tick increased loneliness +#{loneliness} for active characters " <>
        "(clock #{transition.state.clock}h)"
    )
    |> ease_tension(state.clock, transition.state.clock)
  end

  # Tension eases once per simulated day boundary crossed, so the result does
  # not depend on how time was split into ticks.
  defp ease_tension(transition, from_clock, to_clock) do
    days = div(to_clock, 24) - div(from_clock, 24)
    delta = days * Transition.param(transition, :tension_per_day)

    if delta == 0 do
      transition
    else
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
end
