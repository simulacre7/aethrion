defmodule Aethrion.Rules.LonelinessRules do
  @moduledoc """
  Deterministic time-passing rules.
  """

  alias Aethrion.State

  @loneliness_per_hour 4

  def apply(%State{} = state, %{type: :time_tick, hours: hours, now: now}) do
    delta = hours * @loneliness_per_hour

    state =
      Enum.reduce(state.characters, state, fn {character_id, _character}, state ->
        State.update_character_state(state, character_id, fn character_state ->
          %{
            character_state
            | loneliness: min(character_state.loneliness + delta, 100),
              last_active_at: now
          }
        end)
      end)

    log = ["[Rule] time_tick increased loneliness +#{delta} for active characters"]

    {state, [], log}
  end
end
