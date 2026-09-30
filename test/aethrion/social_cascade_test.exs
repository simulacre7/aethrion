defmodule Aethrion.SocialCascadeTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Memories, Pipeline, Runtime, State}

  test "gossip gives the listener a secondhand memory of the same topic" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())

    {state, outputs} =
      dispatch!(state, Event.gossip_shared("yuna", "haru", "memory:yuna:observed:e1", at: "t2"))

    heard = Enum.find(state.memories, &(&1.character_id == "haru"))
    original = State.memory(state, "memory:yuna:observed:e1")

    assert heard.kind == :heard
    assert heard.source == "yuna"
    assert heard.importance == 45
    assert heard.topic == original.topic
    assert heard.data == original.data
    assert "haru" not in heard.related_characters
    assert original.shared_with == ["haru"]

    assert [
             %{kind: :gossip, character_id: "yuna", to: "haru", memory_refs: [_]},
             %{kind: :comfort}
           ] =
             of_type(outputs, :character_interaction)
  end

  test "sharing news someone already knows creates no new memory" do
    {state, _outputs} =
      dispatch!(
        Runtime.demo_state(),
        Event.gift_received("user", "mina", "flower", observed_by: ["yuna", "haru"])
      )

    {next_state, outputs} =
      dispatch!(state, Event.gossip_shared("yuna", "haru", "memory:yuna:observed:e1"))

    assert Enum.count(next_state.memories, &(&1.character_id == "haru")) == 1
    refute Enum.any?(of_type(outputs, :character_interaction), &(&1.kind == :gossip))
  end

  test "a playful listener mentions secondhand news about the user only once" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    gossip = Event.gossip_shared("yuna", "haru", "memory:yuna:observed:e1")

    {state, outputs} = dispatch!(state, gossip)
    assert [%{reason: :curious}] = proactive(outputs, "haru")

    {_state, outputs} = dispatch!(state, Event.time_tick("t3", hours: 1))
    assert [] = proactive(outputs, "haru")
  end

  test "comfort is offered at most once per 12 hours per pair" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {state, first} = dispatch!(state, Event.time_tick("t2", hours: 2))

    assert [%{kind: :comfort}] =
             first |> of_type(:character_interaction) |> Enum.filter(&(&1.kind == :comfort))

    {state, _outputs} =
      dispatch!(state, Event.gift_received("user", "mina", "cake", observed_by: ["yuna"]))

    {_state, second} = dispatch!(state, Event.time_tick("t3", hours: 2))

    assert Enum.any?(of_type(second, :character_interaction), &(&1.kind == :gossip))
    refute Enum.any?(of_type(second, :character_interaction), &(&1.kind == :comfort))
  end

  test "talkative characters share news even when they feel fine" do
    state =
      state(
        [
          character("ari", traits: [:talkative]),
          character("bo"),
          character("cy")
        ],
        [relationship("ari", "bo", trust: 50), relationship("ari", "cy", trust: 35)]
      )

    {state, _outputs} =
      dispatch!(state, Event.gift_received("user", "cy", "map", observed_by: ["ari"]))

    {:ok, step} = Runtime.step(state, Event.time_tick("t2", hours: 1))

    assert [_tick, %{type: :gossip_shared, from: "ari", to: "bo"}] = step.events
    assert Memories.knows_topic?(step.state, "bo", "gift:e1")
  end

  test "news travels to the next most trusted friend who has not heard it" do
    state =
      state(
        [
          character("ari", traits: [:talkative]),
          character("bo"),
          character("cy"),
          character("dee")
        ],
        [relationship("ari", "bo", trust: 50), relationship("ari", "cy", trust: 35)]
      )

    {state, _outputs} =
      dispatch!(state, Event.gift_received("user", "dee", "map", observed_by: ["ari"]))

    {state, _outputs} = dispatch!(state, Event.time_tick("t2", hours: 1))
    assert Memories.knows_topic?(state, "bo", "gift:e1")
    refute Memories.knows_topic?(state, "cy", "gift:e1")

    {state, _outputs} = dispatch!(state, Event.time_tick("t3", hours: 1))
    assert Memories.knows_topic?(state, "cy", "gift:e1")
  end

  test "people who experienced the event are skipped as confidants" do
    state =
      state(
        [character("ari", traits: [:talkative]), character("bo"), character("cy")],
        [relationship("ari", "bo", trust: 50), relationship("ari", "cy", trust: 35)]
      )

    {state, _outputs} =
      dispatch!(state, Event.gift_received("user", "bo", "map", observed_by: ["ari"]))

    {:ok, step} = Runtime.step(state, Event.time_tick("t2", hours: 1))
    assert [_tick, %{type: :gossip_shared, to: "cy"}] = step.events
  end

  test "follow-up events record their cause" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {:ok, step} = Runtime.step(state, Event.time_tick("t2", hours: 2))

    causes = Map.new(step.events, &{&1.id, Map.get(&1, :cause)})
    assert causes == %{"e2" => nil, "e3" => "e2", "e4" => "e3"}
  end

  test "cascade depth is bounded and dropped follow-ups are explained" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {:ok, step} = Runtime.step(state, Event.time_tick("t2", hours: 2), max_depth: 1)

    assert [%{type: :time_tick}, %{type: :gossip_shared}] = step.events
    assert Enum.any?(step.log, &(&1 =~ "[Cascade] dropped comfort_offered"))
    assert Enum.any?(step.trace, &((&1.detail || "") =~ "dropped follow-up comfort_offered"))
  end

  test "cascade event count is bounded" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {:ok, step} = Runtime.step(state, Event.time_tick("t2", hours: 2), max_events: 2)

    assert length(step.events) == 2
  end

  test "rules can be removed to switch off autonomous behavior" do
    pipeline = Pipeline.remove(Pipeline.default(), Aethrion.Rules.Autonomy)
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina(), pipeline: pipeline)
    {:ok, step} = Runtime.step(state, Event.time_tick("t2", hours: 2), pipeline: pipeline)

    assert [%{type: :time_tick}] = step.events
  end

  test "the default event limit scales with the number of characters" do
    ids = for i <- 1..80, do: "c#{i}"

    state =
      state(
        Enum.map(ids, &character(&1, state: [loneliness: 55])),
        for {id, i} <- Enum.with_index(ids) do
          relationship(id, Enum.at(ids, rem(i + 1, 80)), affinity: 40)
        end
      )

    assert Runtime.default_max_events(state) == 320

    {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 1))
    assert length(step.events) > 32
    refute Enum.any?(step.log, &String.starts_with?(&1, "[Cascade] dropped"))
  end

  test "runtime servers honor cascade limits" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    server = start_supervised!({Aethrion.RuntimeServer, initial_state: state, max_events: 2})

    {:ok, step} = Aethrion.RuntimeServer.step(server, Event.time_tick("t2", hours: 2))
    assert length(step.events) == 2
  end
end
