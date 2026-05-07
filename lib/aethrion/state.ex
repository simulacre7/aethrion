defmodule Aethrion.State do
  @moduledoc """
  In-memory state container for the v0 runtime.
  """

  alias Aethrion.{Character, CharacterState, Relationship}

  defstruct characters: %{}, relationships: %{}, memories: [], emitted_proactive: MapSet.new()

  def demo do
    characters = [
      %Character{
        id: "mina",
        name: "Mina",
        profile: "Warm, expressive, and easily moved by small gestures.",
        traits: [:warm, :romantic],
        state: %CharacterState{mood: :neutral, loneliness: 12}
      },
      %Character{
        id: "yuna",
        name: "Yuna",
        profile: "Sensitive, observant, and afraid of being forgotten.",
        traits: [:observant, :sensitive],
        state: %CharacterState{mood: :neutral, loneliness: 26}
      },
      %Character{
        id: "haru",
        name: "Haru",
        profile: "Calm, playful, and usually outside the immediate drama.",
        traits: [:calm, :playful],
        state: %CharacterState{mood: :neutral, loneliness: 8}
      }
    ]

    %__MODULE__{
      characters: Map.new(characters, &{&1.id, &1}),
      relationships: %{
        {"mina", "user"} => %Relationship{from: "mina", to: "user", affinity: 40, trust: 25},
        {"yuna", "user"} => %Relationship{from: "yuna", to: "user", affinity: 38, trust: 20},
        {"yuna", "mina"} => %Relationship{from: "yuna", to: "mina", affinity: 10, trust: 10}
      }
    }
  end

  def get_relationship(%__MODULE__{} = state, from, to) do
    Map.get(state.relationships, {from, to}, %Relationship{from: from, to: to})
  end

  def update_relationship(%__MODULE__{} = state, from, to, fun) do
    relationship = state |> get_relationship(from, to) |> fun.() |> Relationship.clamp()
    put_in(state.relationships[{from, to}], relationship)
  end

  def update_character_state(%__MODULE__{} = state, character_id, fun) do
    update_in(state.characters[character_id].state, fun)
  end

  def add_memory(%__MODULE__{} = state, memory) do
    %{state | memories: [memory | state.memories]}
  end

  def mark_proactive_emitted(%__MODULE__{} = state, character_id, reason) do
    %{state | emitted_proactive: MapSet.put(state.emitted_proactive, {character_id, reason})}
  end

  def proactive_emitted?(%__MODULE__{} = state, character_id, reason) do
    MapSet.member?(state.emitted_proactive, {character_id, reason})
  end
end
