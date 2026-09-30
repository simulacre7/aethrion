defmodule Aethrion.Rules.MemoryDecay do
  @moduledoc """
  Memories weaken with age. Strength is recomputed from the memory's age so
  the result never depends on how time was split into ticks:

      strength = importance - div(age_hours * (100 - importance), 96)

  In other words a memory loses `(100 - importance) / 4` strength per
  simulated day. An importance-45 message fades (strength < 20) after about
  two days, an importance-60 gift after four days, an importance-90 memory
  after four weeks, and an importance-100 memory never fades.

  Faded memories are kept for inspection but no longer selected as context.
  """

  use Aethrion.Rule,
    id: :memory_decay,
    description: "Memory strength = importance - age_hours * (100 - importance) / 96.",
    params: [hours_per_unit: 96]

  alias Aethrion.{Memory, Transition}

  @impl true
  def apply(%Transition{} = transition) do
    clock = transition.state.clock
    unit = Transition.param(transition, :hours_per_unit)

    decayed = fn memory ->
      if Memory.faded?(memory),
        do: memory,
        else: %{memory | strength: min(memory.strength, strength_at(memory, clock, unit))}
    end

    newly_faded =
      transition.state.memories
      |> Enum.reject(&Memory.faded?/1)
      |> Enum.filter(&Memory.faded?(decayed.(&1)))
      |> Enum.reverse()

    newly_faded
    |> Enum.reduce(Transition.map_memories(transition, :strength, decayed), fn memory,
                                                                               transition ->
      Transition.note(
        transition,
        "#{Transition.name(transition, memory.character_id)}'s memory faded: \"#{memory.content}\"",
        subject: memory.character_id
      )
    end)
  end

  @doc "Strength of `memory` at simulated hour `clock`."
  def strength_at(%Memory{} = memory, clock, unit \\ 96) do
    age = max(clock - memory.created_tick, 0)
    max(memory.importance - div(age * (100 - memory.importance), max(unit, 1)), 0)
  end
end
