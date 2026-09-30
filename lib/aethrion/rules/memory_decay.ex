defmodule Aethrion.Rules.MemoryDecay do
  @moduledoc """
  Memories weaken with age. Strength is recomputed from the memory's age so
  the result never depends on how time was split into ticks:

      strength = importance - div(age_hours * (100 - importance), 96)

  In other words a memory loses `(100 - importance) / 4` strength per
  simulated day. An importance-45 message fades (strength < 20) after about
  two days, an importance-60 gift after four days, an importance-90 memory
  after four weeks, and an importance-100 memory never fades.

  Impressions (see `Aethrion.Rules.Consolidation`) decay
  `impression_slowdown` times more slowly, so patterns outlast details.

  Faded memories are kept for inspection but no longer selected as context.
  """

  use Aethrion.Rule,
    id: :memory_decay,
    description:
      "Memory strength = importance - age_hours * (100 - importance) / 96; impressions decay 4x slower.",
    params: [hours_per_unit: 96, impression_slowdown: 4]

  alias Aethrion.{Memory, Transition}

  @impl true
  def apply(%Transition{} = transition) do
    clock = transition.state.clock
    units = units(transition)

    decayed = fn memory ->
      if Memory.faded?(memory),
        do: memory,
        else: %{
          memory
          | strength: min(memory.strength, strength_at(memory, clock, unit(memory, units)))
        }
    end

    note_fading = fn transition, before, updated ->
      if Memory.faded?(updated) and not Memory.faded?(before) do
        Transition.note(
          transition,
          "#{Transition.name(transition, before.character_id)}'s memory faded: \"#{before.content}\"",
          subject: before.character_id
        )
      else
        transition
      end
    end

    Transition.map_memories(transition, :strength, decayed, on_change: note_fading)
  end

  @doc "Strength of `memory` at simulated hour `clock`."
  def strength_at(%Memory{} = memory, clock, unit \\ 96) do
    age = max(clock - memory.created_tick, 0)
    max(memory.importance - div(age * (100 - memory.importance), max(unit, 1)), 0)
  end

  @doc """
  The simulated hour at which `memory` first counts as faded, or `nil` if it
  never fades.
  """
  def fade_tick(%Memory{} = memory, unit \\ 96) do
    threshold = Memory.faded_threshold()
    unit = max(unit, 1)

    cond do
      memory.importance < threshold ->
        memory.created_tick

      memory.importance >= 100 ->
        nil

      true ->
        decay = 100 - memory.importance
        needed = (memory.importance - threshold + 1) * unit
        memory.created_tick + div(needed + decay - 1, decay)
    end
  end

  @doc false
  def units(%Transition{state: state}), do: units(state)

  def units(%Aethrion.State{} = state) do
    unit = Aethrion.Tuning.get(state, __MODULE__, :hours_per_unit)
    {unit, unit * max(Aethrion.Tuning.get(state, __MODULE__, :impression_slowdown), 1)}
  end

  @doc false
  def unit(%Memory{kind: :impression}, {_unit, impression_unit}), do: impression_unit
  def unit(%Memory{}, {unit, _impression_unit}), do: unit
end
