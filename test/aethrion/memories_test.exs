defmodule Aethrion.MemoriesTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Memories, Memory, Runtime, State}
  alias Aethrion.Rules.MemoryDecay

  defp memory(id, attrs) do
    Memory.new(
      Keyword.merge(
        [id: id, character_id: "mina", content: id, importance: 50, created_at: "t"],
        attrs
      )
    )
  end

  defp with_memories(memories) do
    # Memories are stored newest first.
    State.new(characters: [character("mina")], memories: memories)
  end

  test "strength starts at importance" do
    assert %Memory{strength: 60} = memory("m", importance: 60)
  end

  test "decay depends on age and importance, not on tick size" do
    memory = memory("m", importance: 60, created_tick: 0)

    assert MemoryDecay.strength_at(memory, 0) == 60
    assert MemoryDecay.strength_at(memory, 24) == 50
    assert MemoryDecay.strength_at(memory, 96) == 20
    assert MemoryDecay.strength_at(memory("x", importance: 100), 10_000) == 100

    one_tick =
      Runtime.demo_state()
      |> dispatch!(Event.gift_received("user", "mina", "ring"))
      |> elem(0)
      |> dispatch!(Event.time_tick("t", hours: 48))
      |> elem(0)

    many_ticks =
      Runtime.demo_state()
      |> dispatch!(Event.gift_received("user", "mina", "ring"))
      |> elem(0)
      |> run!(for i <- 1..8, do: Event.time_tick("t#{i}", hours: 6))
      |> elem(0)

    strength = fn state -> State.memory(state, "memory:mina:gift:e1").strength end
    assert strength.(one_tick) == 40
    assert strength.(many_ticks) == 40
  end

  test "memories fade below the threshold and are logged once" do
    {state, _outputs} =
      dispatch!(Runtime.demo_state(), Event.message_sent("user", "haru", "hi", tone: :cold))

    {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 60))

    [memory] =
      Enum.filter(
        step.state.memories,
        &(&1.character_id == "haru" and &1.kind == :experienced and
            &1.data["event"] == "message_sent")
      )

    assert Memory.faded?(memory)
    assert Enum.any?(step.log, &(&1 =~ "Haru's memory faded"))

    {:ok, later} = Runtime.step(step.state, Event.time_tick("t", hours: 60))
    refute Enum.any?(later.log, &(&1 =~ "memory faded: \"user said to haru"))
  end

  test "queries exclude faded memories unless asked" do
    state =
      with_memories([
        memory("new", strength: 10),
        memory("old", strength: 50)
      ])

    assert ["old"] = state |> Memories.for_character("mina") |> Enum.map(& &1.id)

    assert ["new", "old"] =
             state |> Memories.for_character("mina", include_faded: true) |> Enum.map(& &1.id)
  end

  test "recent, important, and about queries are ordered deterministically" do
    state =
      with_memories([
        memory("c", importance: 40, related_characters: ["yuna"]),
        memory("b", importance: 80),
        memory("a", importance: 80, related_characters: ["yuna"])
      ])

    assert ["c", "b"] = state |> Memories.recent("mina", 2) |> Enum.map(& &1.id)
    assert ["b", "a", "c"] = state |> Memories.important("mina") |> Enum.map(& &1.id)
    assert ["c", "a"] = state |> Memories.about("mina", "yuna") |> Enum.map(& &1.id)
  end

  test "relevant memories favor focus characters, strength, and recency" do
    state =
      with_memories([
        memory("recent-weak", strength: 30),
        memory("focus", strength: 40, related_characters: ["user"]),
        memory("strong", strength: 70)
      ])

    assert ["strong", "focus", "recent-weak"] =
             state |> Memories.relevant("mina", focus: ["user"]) |> Enum.map(& &1.id)

    assert ["strong"] =
             state |> Memories.relevant("mina", focus: ["user"], limit: 1) |> Enum.map(& &1.id)
  end

  test "knows_topic? includes faded memories" do
    state = with_memories([memory("m", topic: "gift:e1", strength: 0)])

    assert Memories.knows_topic?(state, "mina", "gift:e1")
    refute Memories.knows_topic?(state, "mina", "gift:e2")
  end

  test "memories faded for long enough are forgotten, with a trace" do
    state = State.new(characters: [character("mina"), character("haru")])

    {state, _outputs} =
      dispatch!(state, Aethrion.Event.message_sent("haru", "mina", "hm", tone: :cold))

    [memory] = state.memories
    faded_at = Aethrion.Rules.MemoryDecay.fade_tick(memory)

    {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: faded_at + 719))
    assert [_] = step.state.memories

    {:ok, step} = Runtime.step(step.state, Event.time_tick("t", hours: 1))
    assert [] = step.state.memories
    assert Enum.any?(step.trace, &((&1.detail || "") =~ "mina forgot"))
  end

  test "forgetting is tunable" do
    state =
      State.new(characters: [character("mina"), character("haru")])
      |> Aethrion.Tuning.put(:memory_decay, :forget_after_hours, 0)

    {state, _outputs} =
      run!(state, [
        Aethrion.Event.message_sent("haru", "mina", "hm", tone: :cold),
        Event.time_tick("t", hours: 100)
      ])

    assert [] = state.memories
  end
end
