defmodule Aethrion.Rules.TimePassage do
  @moduledoc """
  Advances the simulated clock. Active characters grow lonelier, and joy and
  stress settle back toward zero. Jealousy does not fade with time alone; it
  takes a social action such as an apology or comfort.
  """

  use Aethrion.Rule,
    id: :time_passage,
    description:
      "Advances the clock; per hour for active characters: loneliness +4, joy -2, stress -2."

  alias Aethrion.{State, Transition}

  @loneliness_per_hour 4
  @joy_per_hour -2
  @stress_per_hour -2

  @impl true
  def apply(%Transition{event: %{hours: hours, now: now}} = transition) do
    state = transition.state
    transition = Transition.put_state(transition, %{state | clock: state.clock + hours})
    loneliness = hours * @loneliness_per_hour

    transition =
      transition.state
      |> State.sorted_characters()
      |> Enum.filter(& &1.state.active?)
      |> Enum.reduce(transition, fn character, transition ->
        transition
        |> Transition.adjust_character(character.id, :loneliness, loneliness, log: false)
        |> Transition.adjust_character(character.id, :joy, hours * @joy_per_hour, log: false)
        |> Transition.adjust_character(character.id, :stress, hours * @stress_per_hour,
          log: false
        )
        |> Transition.set_character(character.id, :last_active_at, now)
      end)

    Transition.note(
      transition,
      "time_tick increased loneliness +#{loneliness} for active characters " <>
        "(clock #{transition.state.clock}h)"
    )
  end
end
