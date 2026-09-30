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

  **Reputation.** Secondhand memories (`:observed` and `:heard`) of how an
  actor treated *other* characters fold the same way into a reputation
  impression, across everyone the actor treated that way:
  `"haru knows user has been hostile to mina and yuna 2 times."` Its id is
  `memory:<holder>:reputation:<pattern>:<actor>`, and `reputation_count/4`
  reads it. `Aethrion.Rules.Message` weighs reputation less than firsthand
  impressions.

  Consolidation is deterministic and purely structural; no summarization
  model is involved.
  """

  use Aethrion.Rule,
    id: :consolidation,
    description:
      "Folds 2+ faded memories of the same interaction with the same actor into one lasting impression; secondhand ones into a reputation.",
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
  memory of one of the covered interactions, or a secondhand one of how
  someone treated another character.
  """
  def consolidatable?(%Memory{} = memory), do: not is_nil(classify(memory))

  defp candidate?(%Memory{} = memory) do
    Memory.faded?(memory) and is_nil(memory.consolidated_into) and consolidatable?(memory)
  end

  defp key(%Memory{} = memory) do
    {scope, pattern, actor, _target} = classify(memory)
    {memory.character_id, scope, pattern, actor}
  end

  # {scope, pattern, actor, target}: "impression" for what happened to the
  # holder, "reputation" for what the holder saw or heard happen to others.
  defp classify(%Memory{character_id: me, kind: kind, data: data}) do
    case {kind, interaction(data)} do
      {_kind, nil} ->
        nil

      {:experienced, {pattern, actor, ^me}} ->
        {"impression", pattern, actor, me}

      {:experienced, _other} ->
        nil

      {kind, {_pattern, ^me, _target}} when kind in [:observed, :heard] ->
        nil

      {kind, {_pattern, _actor, ^me}} when kind in [:observed, :heard] ->
        nil

      {kind, {pattern, actor, target}} when kind in [:observed, :heard] ->
        {"reputation", pattern, actor, target}

      _other ->
        nil
    end
  end

  defp interaction(data) do
    case data do
      %{"event" => "gift_received", "from" => actor, "to" => target} ->
        {"gift", actor, target}

      %{"event" => "message_sent", "tone" => tone, "from" => actor, "to" => target}
      when tone in ["warm", "cold", "hostile"] ->
        {tone, actor, target}

      %{"event" => "apology_offered", "from" => actor, "to" => target} ->
        {"apology", actor, target}

      %{"event" => "comfort_offered", "from" => actor, "to" => target} ->
        {"comfort", actor, target}

      %{"event" => "time_spent_together", "from" => actor, "to" => target} ->
        {"together", actor, target}

      _ ->
        nil
    end
  end

  defp consolidate(transition, {character, scope, pattern, actor} = key, memories, existing) do
    id = impression_id(key)
    previous = if existing, do: existing.data["count"], else: 0
    count = previous + length(memories)

    about =
      memories
      |> Enum.map(&(&1 |> classify() |> elem(3)))
      |> Enum.concat(if existing, do: Map.get(existing.data, "about", []), else: [])
      |> Enum.uniq()
      |> Enum.sort()

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

    {content, data} =
      case scope do
        "impression" ->
          {content(pattern, actor, character, count),
           %{
             "event" => "impression",
             "pattern" => pattern,
             "from" => actor,
             "to" => character,
             "count" => count
           }}

        "reputation" ->
          {reputation_content(pattern, actor, character, others(about), count),
           %{
             "event" => "reputation",
             "pattern" => pattern,
             "from" => actor,
             "about" => about,
             "count" => count
           }}
      end

    impression =
      Memory.new(
        id: id,
        character_id: character,
        content: content,
        importance: importance,
        created_at: "consolidated",
        created_tick: formed_at,
        related_characters: Enum.uniq([actor | if(scope == "reputation", do: about, else: [])]),
        kind: :impression,
        topic: "#{scope}:#{character}:#{pattern}:#{actor}",
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
            related_characters: impression.related_characters,
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
    count(state, {character, "impression", pattern, actor})
  end

  @doc """
  How many times `character` has seen or heard `actor` act out `pattern`
  toward other characters, from a reputation impression. Zero without one, or
  when it has faded.
  """
  def reputation_count(%State{} = state, character, pattern, actor) do
    count(state, {character, "reputation", pattern, actor})
  end

  defp count(state, key) do
    case State.memory(state, impression_id(key)) do
      %Memory{data: %{"count" => count}} = memory when is_integer(count) ->
        # A faded impression is a forgotten pattern.
        if Memory.faded?(memory), do: 0, else: count

      _ ->
        0
    end
  end

  defp impression_id({character, scope, pattern, actor}),
    do: "memory:#{character}:#{scope}:#{pattern}:#{actor}"

  defp reputation_content("together", actor, character, others, count),
    do: "#{character} knows #{actor} has spent time with #{others} #{count} times."

  defp reputation_content(pattern, actor, character, others, count),
    do: "#{character} knows " <> content(pattern, actor, others, count)

  defp others([one]), do: one
  defp others(many), do: Enum.join(Enum.drop(many, -1), ", ") <> " and " <> List.last(many)

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
