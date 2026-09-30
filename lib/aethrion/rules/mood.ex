defmodule Aethrion.Rules.Mood do
  @moduledoc """
  Derives each character's mood from their numeric state after every event.

  Priority: `:upset` (stress >= 40), `:jealous` (jealousy >= 15),
  `:lonely` (loneliness >= 50), `:happy` (joy >= 20), otherwise `:neutral`.
  """

  use Aethrion.Rule,
    id: :mood,
    description:
      "Derives mood: upset (stress>=40) > jealous (jealousy>=15) > lonely (loneliness>=50) > happy (joy>=20) > neutral.",
    params: [upset_stress: 40, jealous_jealousy: 15, lonely_loneliness: 50, happy_joy: 20]

  alias Aethrion.{CharacterState, Output, State, Transition}

  @impl true
  def apply(%Transition{} = transition) do
    transition.state
    |> State.sorted_characters()
    |> Enum.reduce(transition, fn character, transition ->
      mood = derive(character.state, transition.state)

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

  @doc """
  Pure mood derivation from numeric state. Pass the world state to honor its
  `Aethrion.Tuning` overrides; without it the defaults are used.
  """
  def derive(%CharacterState{} = cs, world \\ nil) do
    threshold = fn key ->
      case world do
        %State{} -> Aethrion.Tuning.get(world, __MODULE__, key)
        nil -> Keyword.fetch!(params(), key)
      end
    end

    cond do
      cs.stress >= threshold.(:upset_stress) -> :upset
      cs.jealousy >= threshold.(:jealous_jealousy) -> :jealous
      cs.loneliness >= threshold.(:lonely_loneliness) -> :lonely
      cs.joy >= threshold.(:happy_joy) -> :happy
      true -> :neutral
    end
  end
end
