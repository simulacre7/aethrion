defmodule Aethrion.Rules.Consolidation do
  @moduledoc """
  Turns many faded experiences into one lasting impression.

  Individual memories fade (see `Aethrion.Rules.MemoryDecay`), but a pattern
  should not: someone who was kind twenty times should be remembered as kind
  even after every single conversation has faded. When a character holds at
  least `min_group` faded, unconsolidated firsthand memories of the same kind
  of interaction with the same actor, they are folded into an `:impression`
  memory such as `"user has been warm to mina 3 times."`.

  Covered interactions: gifts received, warm/cold/hostile messages, apologies,
  comfort, and time together. The impression's importance grows with the count
  (`base_importance + per_occurrence * count`, capped at `max_importance`),
  and later faded memories of the same pattern update it in place. Original
  memories are kept, marked with `consolidated_into`, until they are forgotten
  (see `Aethrion.Rules.MemoryDecay`); impressions themselves are never
  forgotten.

  An impression dates from when its latest memory faded, and decays more
  slowly than ordinary memories (see `Aethrion.Rules.MemoryDecay`).

  Consolidation is deterministic and purely structural; no summarization
  model is involved.
  """

  use Aethrion.Rule,
    id: :consolidation,
    description:
      "Folds 2+ faded memories of the same interaction with the same actor into one lasting impression.",
    params: [min_group: 2, base_importance: 40, per_occurrence: 10, max_importance: 90]

  alias Aethrion.{Memory, State, Transition}
  alias Aethrion.Rules.MemoryDecay

  @impl true
  def apply(%Transition{} = transition) do
    min_group = Transition.param(transition, :min_group)
    state = transition.state

    groups =
      state.memories
      |> Enum.filter(&candidate?/1)
      |> Enum.group_by(&key/1)
      |> Enum.sort_by(fn {key, _memories} -> key end)
      |> Enum.map(fn {key, memories} ->
        {key, memories, State.memory(state, impression_id(key))}
      end)
      |> Enum.filter(fn {_key, memories, existing} ->
        existing || length(memories) >= min_group
      end)

    # Mark every consolidated memory in one pass over the memory list.
    assignments =
      for {key, memories, _existing} <- groups,
          memory <- memories,
          into: %{},
          do: {memory.id, impression_id(key)}

    transition =
      Transition.map_memories(transition, :consolidated_into, fn memory ->
        case Map.fetch(assignments, memory.id) do
          {:ok, id} -> %{memory | consolidated_into: id}
          :error -> memory
        end
      end)

    Enum.reduce(groups, transition, fn {key, memories, existing}, transition ->
      consolidate(transition, key, memories, existing)
    end)
  end

  @doc """
  Returns true when `memory` can become part of an impression: a firsthand
  memory of one of the covered interactions.
  """
  def consolidatable?(%Memory{} = memory) do
    memory.kind == :experienced and not is_nil(pattern(memory))
  end

  defp candidate?(%Memory{} = memory) do
    memory.kind == :experienced and Memory.faded?(memory) and is_nil(memory.consolidated_into) and
      not is_nil(pattern(memory))
  end

  defp key(%Memory{} = memory) do
    {pattern, actor} = pattern(memory)
    {memory.character_id, pattern, actor}
  end

  defp pattern(%Memory{character_id: me, data: data}) do
    case data do
      %{"event" => "gift_received", "from" => actor, "to" => ^me} ->
        {"gift", actor}

      %{"event" => "message_sent", "tone" => tone, "from" => actor, "to" => ^me}
      when tone in ["warm", "cold", "hostile"] ->
        {tone, actor}

      %{"event" => "apology_offered", "from" => actor, "to" => ^me} ->
        {"apology", actor}

      %{"event" => "comfort_offered", "from" => actor, "to" => ^me} ->
        {"comfort", actor}

      %{"event" => "time_spent_together", "from" => actor, "to" => ^me} ->
        {"together", actor}

      _ ->
        nil
    end
  end

  defp consolidate(transition, {character, pattern, actor} = key, memories, existing) do
    id = impression_id(key)
    previous = if existing, do: existing.data["count"], else: 0
    count = previous + length(memories)
    importance = importance(transition, count)
    {unit, impression_unit} = MemoryDecay.units(transition)

    # An impression dates from when its latest memory actually faded, not from
    # the tick that noticed, so the result does not depend on tick size.
    formed_at =
      memories
      |> Enum.map(&(MemoryDecay.fade_tick(&1, unit) || transition.state.clock))
      |> Enum.max()
      |> max(if(existing, do: existing.created_tick, else: 0))
      |> min(transition.state.clock)

    content = content(pattern, actor, character, count)

    data = %{
      "event" => "impression",
      "pattern" => pattern,
      "from" => actor,
      "to" => character,
      "count" => count
    }

    impression =
      Memory.new(
        id: id,
        character_id: character,
        content: content,
        importance: importance,
        created_at: "consolidated",
        created_tick: formed_at,
        related_characters: [actor],
        kind: :impression,
        topic: "impression:#{character}:#{pattern}:#{actor}",
        data: data
      )

    impression = %{
      impression
      | strength: MemoryDecay.strength_at(impression, transition.state.clock, impression_unit)
    }

    if existing do
      transition
      |> Transition.update_memory(
        id,
        &%{
          &1
          | content: content,
            importance: impression.importance,
            strength: impression.strength,
            created_tick: formed_at,
            data: data
        },
        field: :content
      )
      |> Transition.log(
        "[Memory] #{Transition.name(transition, character)}'s impression deepens: \"#{content}\""
      )
    else
      Transition.remember(transition, impression, created_tick: formed_at)
    end
  end

  defp importance(transition, count) do
    min(
      Transition.param(transition, :base_importance) +
        Transition.param(transition, :per_occurrence) * count,
      Transition.param(transition, :max_importance)
    )
  end

  @doc """
  How many times `character` has consolidated `pattern` (for example
  `"warm"`, `"gift"`, `"hostile"`) from `actor`. Zero without an impression,
  or when the impression itself has faded.
  """
  def impression_count(%State{} = state, character, pattern, actor) do
    case State.memory(state, impression_id({character, pattern, actor})) do
      %Memory{data: %{"count" => count}} = memory when is_integer(count) ->
        # A faded impression is a forgotten pattern.
        if Memory.faded?(memory), do: 0, else: count

      _ ->
        0
    end
  end

  defp impression_id({character, pattern, actor}),
    do: "memory:#{character}:impression:#{pattern}:#{actor}"

  defp content("gift", actor, character, count),
    do: "#{actor} has given #{character} #{count} gifts."

  defp content("apology", actor, character, count),
    do: "#{actor} has apologized to #{character} #{count} times."

  defp content("together", actor, character, count),
    do: "#{character} has spent time with #{actor} #{count} times."

  defp content("comfort", actor, character, count),
    do: "#{actor} has comforted #{character} #{count} times."

  defp content(tone, actor, character, count),
    do: "#{actor} has been #{tone} to #{character} #{count} times."
end
