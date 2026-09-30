defmodule Aethrion.Rules.Mood do
  @moduledoc """
  Derives each character's mood from their numeric state after every event.

  Priority: `:upset` (stress >= 40), `:jealous` (jealousy >= 15),
  `:lonely` (loneliness >= 50), `:happy` (joy >= 20), otherwise `:neutral`.
  """

  use Aethrion.Rule,
    id: :mood,
    description:
      "Derives mood: upset (stress>=40) > jealous (jealousy>=15) > lonely (loneliness>=50) > happy (joy>=20) > neutral."

  alias Aethrion.{CharacterState, Output, State, Transition}

  @impl true
  def apply(%Transition{} = transition) do
    transition.state
    |> State.sorted_characters()
    |> Enum.reduce(transition, fn character, transition ->
      mood = derive(character.state)

      if mood == character.state.mood do
        transition
      else
        transition
        |> Transition.set_character(character.id, :mood, mood)
        |> Transition.emit(Output.mood_changed(character.id, character.state.mood, mood))
        |> Transition.log("[Mood] #{character.name} #{character.state.mood} -> #{mood}")
      end
    end)
  end

  @doc "Pure mood derivation from numeric state."
  def derive(%CharacterState{} = state) do
    cond do
      state.stress >= 40 -> :upset
      state.jealousy >= 15 -> :jealous
      state.loneliness >= 50 -> :lonely
      state.joy >= 20 -> :happy
      true -> :neutral
    end
  end
end
