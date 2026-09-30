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
  and comfort. The impression's importance grows with the count
  (`base_importance + per_occurrence * count`, capped at `max_importance`),
  and later faded memories of the same pattern update it in place. Original
  memories are kept, marked with `consolidated_into`.

  Consolidation is deterministic and purely structural; no summarization
  model is involved.
  """

  use Aethrion.Rule,
    id: :consolidation,
    description:
      "Folds 2+ faded memories of the same interaction with the same actor into one lasting impression.",
    params: [min_group: 2, base_importance: 40, per_occurrence: 10, max_importance: 90]

  alias Aethrion.{Memory, State, Transition}

  @impl true
  def apply(%Transition{} = transition) do
    min_group = Transition.param(transition, :min_group)

    transition.state.memories
    |> Enum.filter(&candidate?/1)
    |> Enum.group_by(&key/1)
    |> Enum.sort_by(fn {key, _memories} -> key end)
    |> Enum.reduce(transition, fn {key, memories}, transition ->
      existing = State.memory(transition.state, impression_id(key))

      if existing || length(memories) >= min_group do
        consolidate(transition, key, Enum.sort_by(memories, &{&1.created_tick, &1.id}), existing)
      else
        transition
      end
    end)
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

      _ ->
        nil
    end
  end

  defp consolidate(transition, {character, pattern, actor} = key, memories, existing) do
    id = impression_id(key)
    previous = if existing, do: existing.data["count"], else: 0
    count = previous + length(memories)
    importance = importance(transition, count)

    transition =
      Enum.reduce(memories, transition, fn memory, transition ->
        Transition.update_memory(transition, memory.id, &%{&1 | consolidated_into: id},
          field: :consolidated_into
        )
      end)

    content = content(pattern, actor, character, count)

    data = %{
      "event" => "impression",
      "pattern" => pattern,
      "from" => actor,
      "to" => character,
      "count" => count
    }

    if existing do
      transition
      |> Transition.update_memory(
        id,
        &%{
          &1
          | content: content,
            importance: importance,
            strength: importance,
            created_tick: transition.state.clock,
            data: data
        },
        field: :content
      )
      |> Transition.log(
        "[Memory] #{Transition.name(transition, character)}'s impression deepens: \"#{content}\""
      )
    else
      Transition.remember(
        transition,
        Memory.new(
          id: id,
          character_id: character,
          content: content,
          importance: importance,
          created_at: "consolidated",
          related_characters: [actor],
          kind: :impression,
          topic: "impression:#{character}:#{pattern}:#{actor}",
          data: data
        )
      )
    end
  end

  defp importance(transition, count) do
    min(
      Transition.param(transition, :base_importance) +
        Transition.param(transition, :per_occurrence) * count,
      Transition.param(transition, :max_importance)
    )
  end

  defp impression_id({character, pattern, actor}),
    do: "memory:#{character}:impression:#{pattern}:#{actor}"

  defp content("gift", actor, character, count),
    do: "#{actor} has given #{character} #{count} gifts."

  defp content("apology", actor, character, count),
    do: "#{actor} has apologized to #{character} #{count} times."

  defp content("comfort", actor, character, count),
    do: "#{actor} has comforted #{character} #{count} times."

  defp content(tone, actor, character, count),
    do: "#{actor} has been #{tone} to #{character} #{count} times."
end
