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
    thresholds = thresholds(transition.state)

    transition.state
    |> State.sorted_characters()
    |> Enum.reduce(transition, fn character, transition ->
      mood = derive(character.state, thresholds)

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
  @spec derive(CharacterState.t(), State.t() | map() | nil) :: CharacterState.mood()
  def derive(cs, world_or_thresholds \\ nil)

  def derive(%CharacterState{} = cs, %State{} = world), do: derive(cs, thresholds(world))
  def derive(%CharacterState{} = cs, nil), do: derive(cs, Map.new(params()))

  def derive(%CharacterState{} = cs, %{} = t) do
    cond do
      cs.stress >= t.upset_stress -> :upset
      cs.jealousy >= t.jealous_jealousy -> :jealous
      cs.loneliness >= t.lonely_loneliness -> :lonely
      cs.joy >= t.happy_joy -> :happy
      true -> :neutral
    end
  end

  @doc "The world's mood thresholds, honoring tuning."
  @spec thresholds(State.t()) :: %{atom() => integer()}
  def thresholds(%State{} = world) do
    Map.new(params(), fn {key, _default} -> {key, Aethrion.Tuning.get(world, __MODULE__, key)} end)
  end
end
