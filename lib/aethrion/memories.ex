defmodule Aethrion.Memories do
  @moduledoc """
  Deterministic memory queries.

  Retrieval is intentionally simple and explainable: no embeddings, no vector
  search. Every query returns memories in a stable order so the same state
  always yields the same context.

  Faded memories (see `Aethrion.Memory.faded?/1`) are excluded unless
  `include_faded: true` is passed.
  """

  alias Aethrion.{Memory, State}

  @focus_bonus 25
  @recency_bonus 10
  @recency_step 2

  @doc "A character's memories, newest first."
  @spec for_character(State.t(), String.t(), keyword()) :: [Memory.t()]
  def for_character(%State{} = state, character_id, opts \\ []) do
    include_faded? = Keyword.get(opts, :include_faded, false)

    Enum.filter(state.memories, fn memory ->
      memory.character_id == character_id and (include_faded? or not Memory.faded?(memory))
    end)
  end

  @doc "The `limit` most recent memories."
  @spec recent(State.t(), String.t(), non_neg_integer(), keyword()) :: [Memory.t()]
  def recent(%State{} = state, character_id, limit \\ 5, opts \\ []) do
    state |> for_character(character_id, opts) |> Enum.take(limit)
  end

  @doc "The `limit` most important memories; ties go to the newer memory."
  @spec important(State.t(), String.t(), non_neg_integer(), keyword()) :: [Memory.t()]
  def important(%State{} = state, character_id, limit \\ 5, opts \\ []) do
    state
    |> for_character(character_id, opts)
    |> Enum.with_index()
    |> Enum.sort_by(fn {memory, index} -> {-memory.importance, index} end)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Memories involving `other_id`, newest first."
  @spec about(State.t(), String.t(), String.t(), keyword()) :: [Memory.t()]
  def about(%State{} = state, character_id, other_id, opts \\ []) do
    state
    |> for_character(character_id, opts)
    |> Enum.filter(&Memory.involves?(&1, other_id))
  end

  @doc """
  Returns true when the character holds any memory, even faded, of `topic`,
  or an impression that folded in a memory of it (so a story the character
  has forgotten the details of is still not news to them).
  """
  @spec knows_topic?(State.t(), String.t(), String.t() | nil) :: boolean()
  def knows_topic?(_state, _character_id, nil), do: false

  def knows_topic?(%State{} = state, character_id, topic) do
    Enum.any?(state.memories, &(&1.character_id == character_id and topic in topics(&1)))
  end

  @doc """
  The topics a memory stands for: its own, plus for an impression every topic
  folded into it.
  """
  @spec topics(Memory.t()) :: [String.t()]
  def topics(%Memory{kind: :impression, topic: topic, data: %{"topics" => [_ | _] = folded}}),
    do: [topic | folded]

  def topics(%Memory{topic: nil}), do: []
  def topics(%Memory{topic: topic}), do: [topic]

  @doc """
  Selects the memories most relevant to a situation.

  Score = `strength` + #{@focus_bonus} when the memory involves any `:focus`
  character + a recency bonus (#{@recency_bonus} for the newest memory,
  decreasing by #{@recency_step} per older memory). Ties go to the newer memory.

  Options: `:focus` (character ids), `:limit` (default 3), `:include_faded`.
  """
  @spec relevant(State.t(), String.t(), keyword()) :: [Memory.t()]
  def relevant(%State{} = state, character_id, opts \\ []) do
    focus = Keyword.get(opts, :focus, [])
    limit = Keyword.get(opts, :limit, 3)

    state
    |> for_character(character_id, opts)
    |> Enum.with_index()
    |> Enum.map(fn {memory, index} -> {score(memory, index, focus), index, memory} end)
    |> Enum.sort_by(fn {score, index, _memory} -> {-score, index} end)
    |> Enum.take(limit)
    |> Enum.map(&elem(&1, 2))
  end

  @doc """
  The number of the event a memory is about, from its topic
  (`"message:e12"` is 12), or `nil`. Event ids count up, and every memory of
  one event shares its topic, so this orders what happened even when one of
  the memories was only heard later. Takes a memory, a memory-like map, or a
  topic.
  """
  @spec event_number(Memory.t() | map() | String.t() | nil) :: non_neg_integer() | nil
  def event_number(%{topic: topic}), do: event_number(topic)

  def event_number(topic) when is_binary(topic) do
    case Regex.run(~r/:e(\d+)$/, topic) do
      [_, digits] -> String.to_integer(digits)
      nil -> nil
    end
  end

  def event_number(_none), do: nil

  @doc """
  Whether `memories` hold an apology from the author of harsh words (a cold
  or hostile message) to its target, made after them.
  """
  @spec made_amends?(Memory.t(), [Memory.t()]) :: boolean()
  def made_amends?(
        %Memory{data: %{"event" => "message_sent", "tone" => tone, "from" => from, "to" => to}} =
          harsh,
        memories
      )
      when tone in ["cold", "hostile"] do
    said = event_number(harsh) || 0

    Enum.any?(memories, fn
      %Memory{data: %{"event" => "apology_offered", "from" => ^from, "to" => ^to}} = apology ->
        (event_number(apology) || 0) > said

      _other ->
        false
    end)
  end

  def made_amends?(%Memory{}, _memories), do: false

  @doc false
  def score(%Memory{} = memory, index, focus) do
    focus_bonus = if Enum.any?(focus, &Memory.involves?(memory, &1)), do: @focus_bonus, else: 0
    memory.strength + focus_bonus + max(@recency_bonus - index * @recency_step, 0)
  end
end
