defmodule Aethrion.State do
  @moduledoc """
  In-memory state container for the v0 runtime.
  """

  alias Aethrion.{Character, CharacterState, Relationship}

  @type t :: %__MODULE__{}

  defstruct characters: %{}, relationships: %{}, memories: [], emitted_proactive: MapSet.new()

  @doc """
  Builds a runtime state from explicit characters and relationships.
  """
  def new(opts \\ []) do
    characters = Keyword.get(opts, :characters, [])
    relationships = Keyword.get(opts, :relationships, [])
    memories = Keyword.get(opts, :memories, [])
    emitted_proactive = Keyword.get(opts, :emitted_proactive, MapSet.new())

    %__MODULE__{
      characters: Map.new(characters, &{&1.id, &1}),
      relationships: Map.new(relationships, &{{&1.from, &1.to}, &1}),
      memories: memories,
      emitted_proactive: MapSet.new(emitted_proactive)
    }
  end

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

    new(
      characters: characters,
      relationships: [
        %Relationship{from: "mina", to: "user", affinity: 40, trust: 25},
        %Relationship{from: "yuna", to: "user", affinity: 38, trust: 20},
        %Relationship{from: "yuna", to: "mina", affinity: 10, trust: 10}
      ]
    )
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

  def to_data(%__MODULE__{} = state) do
    %{
      "characters" =>
        Enum.map(state.characters, fn {_id, character} -> character_to_data(character) end),
      "relationships" =>
        Enum.map(state.relationships, fn {_key, relationship} ->
          relationship_to_data(relationship)
        end),
      "memories" => Enum.map(state.memories, &memory_to_data/1),
      "emitted_proactive" =>
        Enum.map(state.emitted_proactive, fn {character_id, reason} ->
          %{"character_id" => character_id, "reason" => Atom.to_string(reason)}
        end)
    }
  end

  def from_data(data) when is_map(data) do
    new(
      characters: Enum.map(Map.get(data, "characters", []), &character_from_data/1),
      relationships: Enum.map(Map.get(data, "relationships", []), &relationship_from_data/1),
      memories: Enum.map(Map.get(data, "memories", []), &memory_from_data/1),
      emitted_proactive:
        Enum.map(Map.get(data, "emitted_proactive", []), fn item ->
          {Map.fetch!(item, "character_id"), item |> Map.fetch!("reason") |> String.to_atom()}
        end)
    )
  end

  defp character_to_data(character) do
    %{
      "id" => character.id,
      "name" => character.name,
      "profile" => character.profile,
      "traits" => Enum.map(character.traits, &atom_to_string/1),
      "state" => character_state_to_data(character.state)
    }
  end

  defp character_from_data(data) do
    %Character{
      id: Map.fetch!(data, "id"),
      name: Map.fetch!(data, "name"),
      profile: Map.get(data, "profile", ""),
      traits: data |> Map.get("traits", []) |> Enum.map(&String.to_atom/1),
      state: data |> Map.get("state", %{}) |> character_state_from_data()
    }
  end

  defp character_state_to_data(character_state) do
    %{
      "mood" => Atom.to_string(character_state.mood),
      "energy" => character_state.energy,
      "loneliness" => character_state.loneliness,
      "jealousy" => character_state.jealousy,
      "active" => character_state.active?,
      "blocked" => character_state.blocked?,
      "last_active_at" => character_state.last_active_at
    }
  end

  defp character_state_from_data(data) do
    %CharacterState{
      mood: data |> Map.get("mood", "neutral") |> String.to_atom(),
      energy: Map.get(data, "energy", 100),
      loneliness: Map.get(data, "loneliness", 0),
      jealousy: Map.get(data, "jealousy", 0),
      active?: Map.get(data, "active", true),
      blocked?: Map.get(data, "blocked", false),
      last_active_at: Map.get(data, "last_active_at")
    }
  end

  defp relationship_to_data(relationship) do
    %{
      "from" => relationship.from,
      "to" => relationship.to,
      "affinity" => relationship.affinity,
      "trust" => relationship.trust,
      "tension" => relationship.tension,
      "tags" => Enum.map(relationship.tags, &atom_to_string/1)
    }
  end

  defp relationship_from_data(data) do
    %Relationship{
      from: Map.fetch!(data, "from"),
      to: Map.fetch!(data, "to"),
      affinity: Map.get(data, "affinity", 0),
      trust: Map.get(data, "trust", 0),
      tension: Map.get(data, "tension", 0),
      tags: data |> Map.get("tags", []) |> Enum.map(&String.to_atom/1)
    }
  end

  defp memory_to_data(memory) do
    %{
      "id" => memory.id,
      "character_id" => memory.character_id,
      "content" => memory.content,
      "importance" => memory.importance,
      "created_at" => memory.created_at,
      "related_characters" => memory.related_characters
    }
  end

  defp memory_from_data(data) do
    %Aethrion.Memory{
      id: Map.fetch!(data, "id"),
      character_id: Map.fetch!(data, "character_id"),
      content: Map.fetch!(data, "content"),
      importance: Map.fetch!(data, "importance"),
      created_at: Map.fetch!(data, "created_at"),
      related_characters: Map.get(data, "related_characters", [])
    }
  end

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: value
end
