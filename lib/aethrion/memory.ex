defmodule Aethrion.Memory do
  @moduledoc """
  A deterministic memory record created by runtime rules.

  - `importance` is fixed at creation and describes how significant the memory is.
  - `strength` starts at `importance` and decays over simulated time. Memories
    whose strength drops below `faded_threshold/0` are kept for inspection but
    excluded from context selection by default.
  - `kind` explains how the character learned about it: `:experienced` (it
    happened to them), `:observed` (they saw it), `:heard` (someone told them),
    or `:impression` (a summary of many faded experiences, see
    `Aethrion.Rules.Consolidation`).
  - `topic` links memories about the same underlying event across characters.
  - `source` is the character who told them, for `:heard` memories.
  - `data` holds structured facts (string keys) that expression adapters may
    reference without parsing `content`.
  """

  @type kind :: :experienced | :observed | :heard | :impression

  @type t :: %__MODULE__{
          id: String.t(),
          character_id: String.t(),
          content: String.t(),
          importance: 0..100,
          strength: 0..100,
          created_at: String.t(),
          created_tick: non_neg_integer(),
          related_characters: [String.t()],
          kind: kind(),
          topic: String.t() | nil,
          source: String.t() | nil,
          data: %{optional(String.t()) => term()},
          shared_with: [String.t()],
          consolidated_into: String.t() | nil
        }

  @kinds [:experienced, :observed, :heard, :impression]
  @faded_threshold 20

  @enforce_keys [:id, :character_id, :content, :importance, :created_at]
  defstruct [
    :id,
    :character_id,
    :content,
    :importance,
    :created_at,
    strength: nil,
    created_tick: 0,
    related_characters: [],
    kind: :experienced,
    topic: nil,
    source: nil,
    data: %{},
    shared_with: [],
    consolidated_into: nil
  ]

  @doc """
  Builds a memory, defaulting `strength` to `importance`.
  """
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    memory = struct!(__MODULE__, attrs)
    importance = clamp(memory.importance)
    %{memory | importance: importance, strength: clamp(memory.strength || importance)}
  end

  # Tuned parameters can push importance outside 0..100; memories never leave it.
  defp clamp(value) when is_integer(value), do: value |> max(0) |> min(100)
  defp clamp(value), do: value

  @doc "Memory kinds the runtime understands."
  def kinds, do: @kinds

  @doc "Strength below which a memory counts as faded."
  def faded_threshold, do: @faded_threshold

  @doc "Returns true when the memory has decayed below the faded threshold."
  def faded?(%__MODULE__{strength: strength}), do: strength < @faded_threshold

  @doc "Returns true when the memory involves `character_id`."
  def involves?(%__MODULE__{} = memory, character_id) do
    character_id in memory.related_characters
  end
end
