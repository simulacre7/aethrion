defmodule Aethrion.State do
  @moduledoc """
  Plain-data world state advanced by the deterministic runtime.

  - `characters` - `%{id => Aethrion.Character}`
  - `relationships` - `%{{from, to} => Aethrion.Relationship}`
  - `memories` - newest first
  - `clock` - simulated hours elapsed, advanced by `time_tick` events
  - `seq` - number of events processed; used to assign stable event ids
  - `cooldowns` - `%{key => clock}` recording when a rate-limited behavior last fired
  - `tuning` - rule parameter overrides, see `Aethrion.Tuning`
  """

  alias Aethrion.{Character, CharacterState, Memory, Relationship}

  @type t :: %__MODULE__{
          characters: %{optional(String.t()) => Character.t()},
          relationships: %{optional({String.t(), String.t()}) => Relationship.t()},
          memories: [Memory.t()],
          clock: non_neg_integer(),
          seq: non_neg_integer(),
          cooldowns: %{optional(String.t()) => non_neg_integer()},
          tuning: Aethrion.Tuning.t()
        }

  @data_version 2

  defstruct characters: %{},
            relationships: %{},
            memories: [],
            clock: 0,
            seq: 0,
            cooldowns: %{},
            tuning: %{}

  @doc """
  Builds a runtime state from explicit characters and relationships.

  Options: `:characters`, `:relationships`, `:memories`, `:clock`, `:seq`,
  `:cooldowns`, `:tuning`.
  """
  def new(opts \\ []) do
    %__MODULE__{
      characters: Map.new(Keyword.get(opts, :characters, []), &{&1.id, &1}),
      relationships:
        Map.new(
          Keyword.get(opts, :relationships, []),
          &{{&1.from, &1.to}, Relationship.clamp(&1)}
        ),
      memories: Keyword.get(opts, :memories, []),
      clock: Keyword.get(opts, :clock, 0),
      seq: Keyword.get(opts, :seq, 0),
      cooldowns: Map.new(Keyword.get(opts, :cooldowns, %{})),
      tuning: Map.new(Keyword.get(opts, :tuning, %{}))
    }
  end

  @doc """
  The built-in Mina / Yuna / Haru scenario.
  """
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
        profile:
          "Calm, playful, and usually outside the immediate drama. Quietly looks out for Yuna.",
        traits: [:calm, :playful],
        state: %CharacterState{mood: :neutral, loneliness: 8}
      }
    ]

    new(
      characters: characters,
      relationships: [
        %Relationship{from: "mina", to: "user", affinity: 40, trust: 25},
        %Relationship{from: "mina", to: "yuna", affinity: 20, trust: 15},
        %Relationship{from: "yuna", to: "user", affinity: 38, trust: 20},
        %Relationship{from: "yuna", to: "mina", affinity: 10, trust: 10},
        %Relationship{from: "yuna", to: "haru", affinity: 25, trust: 40},
        %Relationship{from: "haru", to: "user", affinity: 20, trust: 15},
        %Relationship{from: "haru", to: "yuna", affinity: 30, trust: 35},
        %Relationship{from: "haru", to: "mina", affinity: 15, trust: 15}
      ]
    )
  end

  ## Characters

  @doc "Returns true when `id` names a character in this state."
  def character?(%__MODULE__{} = state, id),
    do: is_binary(id) and Map.has_key?(state.characters, id)

  @doc "Fetches a character or returns nil."
  def character(%__MODULE__{} = state, id), do: Map.get(state.characters, id)

  @doc "Characters sorted by id, for deterministic iteration."
  def sorted_characters(%__MODULE__{} = state) do
    state.characters |> Map.values() |> Enum.sort_by(& &1.id)
  end

  @doc "Display name for a character id, or the raw id for external actors such as `user`."
  def name(%__MODULE__{} = state, id) do
    case Map.get(state.characters, id) do
      %Character{name: name} -> name
      nil -> id
    end
  end

  def update_character_state(%__MODULE__{} = state, character_id, fun) do
    update_in(state.characters[character_id].state, fun)
  end

  ## Relationships

  def get_relationship(%__MODULE__{} = state, from, to) do
    Map.get(state.relationships, {from, to}, %Relationship{from: from, to: to})
  end

  def update_relationship(%__MODULE__{} = state, from, to, fun) do
    relationship = state |> get_relationship(from, to) |> fun.() |> Relationship.clamp()
    put_in(state.relationships[{from, to}], relationship)
  end

  ## Memories

  def add_memory(%__MODULE__{} = state, memory) do
    %{state | memories: [memory | state.memories]}
  end

  @doc "Fetches a memory by id or returns nil."
  def memory(%__MODULE__{} = state, memory_id) do
    Enum.find(state.memories, &(&1.id == memory_id))
  end

  @doc "Applies `fun` to the memory with `memory_id`."
  def update_memory(%__MODULE__{} = state, memory_id, fun) do
    memories =
      Enum.map(state.memories, fn
        %Memory{id: ^memory_id} = memory -> fun.(memory)
        memory -> memory
      end)

    %{state | memories: memories}
  end

  ## Cooldowns

  @doc """
  Returns true when `key` has never fired, or fired at least `hours` simulated
  hours ago. Pass `:once` to allow the behavior only one time.
  """
  def cooldown_ready?(%__MODULE__{} = state, key, :once),
    do: not Map.has_key?(state.cooldowns, key)

  def cooldown_ready?(%__MODULE__{} = state, key, hours) when is_integer(hours) do
    case Map.fetch(state.cooldowns, key) do
      {:ok, fired_at} -> state.clock - fired_at >= hours
      :error -> true
    end
  end

  @doc "Records that `key` fired at the current clock."
  def put_cooldown(%__MODULE__{} = state, key) do
    %{state | cooldowns: Map.put(state.cooldowns, key, state.clock)}
  end

  ## Serialization

  @doc "Current serialization format version."
  def data_version, do: @data_version

  @doc """
  Converts state into JSON-friendly data with string keys.
  """
  def to_data(%__MODULE__{} = state) do
    %{
      "version" => @data_version,
      "clock" => state.clock,
      "seq" => state.seq,
      "characters" => state |> sorted_characters() |> Enum.map(&character_to_data/1),
      "relationships" =>
        state.relationships
        |> Map.values()
        |> Enum.sort_by(&{&1.from, &1.to})
        |> Enum.map(&relationship_to_data/1),
      "memories" => Enum.map(state.memories, &memory_to_data/1),
      "cooldowns" => state.cooldowns,
      "tuning" => Aethrion.Tuning.to_data(state.tuning)
    }
  end

  @doc """
  Rebuilds state from `to_data/1` output. Version 1 data (v0.1 alpha) is migrated.
  """
  def from_data(data) when is_map(data) do
    new(
      characters: Enum.map(Map.get(data, "characters", []), &character_from_data/1),
      relationships: Enum.map(Map.get(data, "relationships", []), &relationship_from_data/1),
      memories: Enum.map(Map.get(data, "memories", []), &memory_from_data/1),
      clock: Map.get(data, "clock", 0),
      seq: Map.get(data, "seq", 0),
      cooldowns: cooldowns_from_data(data),
      tuning: tuning_from_data(data)
    )
  end

  # Unknown rules or parameters in saved data are dropped rather than failing
  # the load; scenarios validate tuning strictly instead.
  defp tuning_from_data(%{"tuning" => tuning}) when is_map(tuning) do
    Enum.reduce(tuning, %{}, fn {rule, params}, acc ->
      case Aethrion.Tuning.from_data(%{rule => params}) do
        {:ok, parsed} -> Map.merge(acc, parsed)
        {:error, _reason} -> acc
      end
    end)
  end

  defp tuning_from_data(_data), do: %{}

  defp cooldowns_from_data(%{"cooldowns" => cooldowns}) when is_map(cooldowns), do: cooldowns

  # v1 recorded one-shot proactive messages without a clock.
  defp cooldowns_from_data(%{"emitted_proactive" => emitted}) when is_list(emitted) do
    Map.new(emitted, fn item ->
      {"proactive:#{item["character_id"]}:#{item["reason"]}", 0}
    end)
  end

  defp cooldowns_from_data(_data), do: %{}

  defp character_to_data(character) do
    %{
      "id" => character.id,
      "name" => character.name,
      "profile" => character.profile,
      "traits" => Enum.map(character.traits, &atom_to_string/1),
      "state" => character_state_to_data(character.state)
    }
  end

  @doc false
  def character_from_data(data) do
    %Character{
      id: Map.fetch!(data, "id"),
      name: Map.fetch!(data, "name"),
      profile: Map.get(data, "profile", ""),
      traits: data |> Map.get("traits", []) |> Enum.map(&trait_from_data/1),
      state: data |> Map.get("state", %{}) |> character_state_from_data()
    }
  end

  defp character_state_to_data(character_state) do
    %{
      "mood" => Atom.to_string(character_state.mood),
      "energy" => character_state.energy,
      "loneliness" => character_state.loneliness,
      "jealousy" => character_state.jealousy,
      "joy" => character_state.joy,
      "stress" => character_state.stress,
      "active" => character_state.active?,
      "blocked" => character_state.blocked?,
      "last_active_at" => character_state.last_active_at
    }
  end

  defp character_state_from_data(data) do
    %CharacterState{
      mood: enum_from_data(Map.get(data, "mood", "neutral"), CharacterState.moods(), :neutral),
      energy: Map.get(data, "energy", 100),
      loneliness: Map.get(data, "loneliness", 0),
      jealousy: Map.get(data, "jealousy", 0),
      joy: Map.get(data, "joy", 0),
      stress: Map.get(data, "stress", 0),
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

  @doc false
  def relationship_from_data(data) do
    %Relationship{
      from: Map.fetch!(data, "from"),
      to: Map.fetch!(data, "to"),
      affinity: Map.get(data, "affinity", 0),
      trust: Map.get(data, "trust", 0),
      tension: Map.get(data, "tension", 0),
      tags: data |> Map.get("tags", []) |> Enum.map(&trait_from_data/1)
    }
  end

  @doc false
  def memory_to_data(memory) do
    %{
      "id" => memory.id,
      "character_id" => memory.character_id,
      "content" => memory.content,
      "importance" => memory.importance,
      "strength" => memory.strength,
      "created_at" => memory.created_at,
      "created_tick" => memory.created_tick,
      "related_characters" => memory.related_characters,
      "kind" => Atom.to_string(memory.kind),
      "topic" => memory.topic,
      "source" => memory.source,
      "data" => memory.data,
      "shared_with" => memory.shared_with
    }
  end

  @doc false
  def memory_from_data(data) do
    Memory.new(
      id: Map.fetch!(data, "id"),
      character_id: Map.fetch!(data, "character_id"),
      content: Map.fetch!(data, "content"),
      importance: Map.fetch!(data, "importance"),
      strength: Map.get(data, "strength"),
      created_at: Map.fetch!(data, "created_at"),
      created_tick: Map.get(data, "created_tick", 0),
      related_characters: Map.get(data, "related_characters", []),
      kind: enum_from_data(Map.get(data, "kind", "experienced"), Memory.kinds(), :experienced),
      topic: Map.get(data, "topic"),
      source: Map.get(data, "source"),
      data: Map.get(data, "data", %{}),
      shared_with: Map.get(data, "shared_with", [])
    )
  end

  # Enumerated values are converted through a whitelist so untrusted JSON cannot
  # create arbitrary atoms.
  defp enum_from_data(value, allowed, default) when is_binary(value) do
    Enum.find(allowed, default, &(Atom.to_string(&1) == value))
  end

  defp enum_from_data(_value, _allowed, default), do: default

  # Traits and tags are open-ended descriptive atoms authored by the host.
  defp trait_from_data(value) when is_binary(value), do: String.to_atom(value)
  defp trait_from_data(value) when is_atom(value), do: value

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(value), do: value
end
