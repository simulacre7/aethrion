defmodule Aethrion.RuntimeTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Event, Runtime, State}
  alias Aethrion.LLM.FakeAdapter

  test "gift event changes affinity and creates memory" do
    state = Runtime.demo_state()
    event = Event.gift_received("user", "mina", "flower", observed_by: [], at: "demo:test")

    {:ok, state, outputs, _log} = Runtime.dispatch(state, event)

    relationship = State.get_relationship(state, "mina", "user")

    assert relationship.affinity == 50
    assert [%{character_id: "mina", content: "user gave mina a flower."}] = state.memories
    assert Enum.any?(outputs, &match?(%{type: :memory_created}, &1))
  end

  test "observed gift increases jealousy and tension" do
    state = Runtime.demo_state()
    event = Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "demo:test")

    {:ok, state, _outputs, _log} = Runtime.dispatch(state, event)

    assert state.characters["yuna"].state.jealousy == 15
    assert State.get_relationship(state, "yuna", "mina").tension == 8
  end

  test "time tick changes loneliness" do
    state = Runtime.demo_state()
    event = Event.time_tick("demo:t2", hours: 2)

    {:ok, state, _outputs, _log} = Runtime.dispatch(state, event)

    assert state.characters["mina"].state.loneliness == 20
    assert state.characters["yuna"].state.loneliness == 34
    assert state.characters["haru"].state.loneliness == 16
  end

  test "apology reduces social pressure and creates reconciliation memory" do
    state = Runtime.demo_state()

    {:ok, state, _outputs, _log} =
      Runtime.dispatch(
        state,
        Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "demo:t1")
      )

    {:ok, state, outputs, _log} =
      Runtime.dispatch(
        state,
        Event.apology_offered("user", "yuna", "I should have checked in with you too.",
          at: "demo:t2"
        )
      )

    assert state.characters["yuna"].state.jealousy == 0
    assert state.characters["yuna"].state.loneliness == 20
    assert State.get_relationship(state, "yuna", "user").trust == 28

    assert [%{character_id: "yuna", content: "user apologized to yuna: " <> _}, _gift_memory] =
             state.memories

    assert Enum.any?(outputs, &match?(%{type: :memory_created}, &1))
  end

  test "jealousy threshold emits a proactive message" do
    state = Runtime.demo_state()

    {:ok, state, _outputs, _log} =
      Runtime.dispatch(
        state,
        Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "demo:t1")
      )

    {:ok, _state, outputs, _log} = Runtime.dispatch(state, Event.time_tick("demo:t2", hours: 2))

    assert [
             %{
               type: :proactive_message,
               character_id: "yuna",
               to: "user",
               reason: :jealous
             }
           ] = Enum.filter(outputs, &(&1.type == :proactive_message))
  end

  test "scenario produces deterministic final state and structured outputs" do
    state = Runtime.demo_state()

    events = [
      Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "demo:t1"),
      Event.gift_received("user", "mina", "book", observed_by: ["yuna"], at: "demo:t2"),
      Event.gift_received("user", "mina", "tea", observed_by: ["yuna"], at: "demo:t3"),
      Event.time_tick("demo:t4", hours: 2)
    ]

    {state, outputs} =
      Enum.reduce(events, {state, []}, fn event, {state, outputs} ->
        {:ok, state, next_outputs, _log} = Runtime.dispatch(state, event)
        {state, outputs ++ next_outputs}
      end)

    assert State.get_relationship(state, "mina", "user").affinity == 70
    assert State.get_relationship(state, "yuna", "mina").tension == 24
    assert state.characters["yuna"].state.jealousy == 45
    assert state.characters["yuna"].state.loneliness == 34
    assert length(state.memories) == 3
    assert Enum.count(outputs, &(&1.type == :proactive_message)) == 1
  end

  test "branched scenario diverges after apology choice" do
    base_state = Runtime.demo_state()

    {:ok, base_state, _outputs, _log} =
      Runtime.dispatch(
        base_state,
        Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "branch:t1")
      )

    {:ok, ignored_state, ignored_outputs, _log} =
      Runtime.dispatch(base_state, Event.time_tick("branch:ignored:t2", hours: 2))

    {:ok, apology_state, _outputs, _log} =
      Runtime.dispatch(
        base_state,
        Event.apology_offered("user", "yuna", "I should have checked in with you too.",
          at: "branch:apology:t2"
        )
      )

    {:ok, apology_state, apology_outputs, _log} =
      Runtime.dispatch(apology_state, Event.time_tick("branch:apology:t3", hours: 2))

    assert ignored_state.characters["yuna"].state.jealousy == 15
    assert ignored_state.characters["yuna"].state.loneliness == 34
    assert Enum.any?(ignored_outputs, &(&1.type == :proactive_message))

    assert apology_state.characters["yuna"].state.jealousy == 0
    assert apology_state.characters["yuna"].state.loneliness == 28
    refute Enum.any?(apology_outputs, &(&1.type == :proactive_message))
  end

  test "relationship values stay clamped" do
    state = Runtime.demo_state()

    events =
      for index <- 1..20 do
        Event.gift_received("user", "mina", "flower-#{index}",
          observed_by: ["yuna"],
          at: "demo:#{index}"
        )
      end

    {state, _outputs} =
      Enum.reduce(events, {state, []}, fn event, {state, outputs} ->
        {:ok, state, next_outputs, _log} = Runtime.dispatch(state, event)
        {state, outputs ++ next_outputs}
      end)

    for relationship <- Map.values(state.relationships) do
      assert relationship.affinity in -100..100
      assert relationship.trust in -100..100
      assert relationship.tension in -100..100
    end
  end

  test "blocked characters cannot proactively message" do
    state =
      Runtime.demo_state()
      |> State.update_character_state("yuna", fn character_state ->
        %{character_state | blocked?: true, jealousy: 50}
      end)

    {:ok, _state, outputs, _log} = Runtime.dispatch(state, Event.time_tick("demo:t1", hours: 1))

    refute Enum.any?(outputs, &(&1.type == :proactive_message))
  end

  test "fake llm output does not mutate authoritative state" do
    state = Runtime.demo_state()

    assert FakeAdapter.proactive_message("yuna", :jealous) =~ "Mina"
    assert state == Runtime.demo_state()
  end

  test "unknown gift receiver returns structured error" do
    state = Runtime.demo_state()

    assert {:error, %{code: :unknown_character, message: message}} =
             Runtime.dispatch(state, Event.gift_received("user", "unknown", "flower"))

    assert message =~ "unknown character"
  end

  test "unknown apology receiver returns structured error" do
    state = Runtime.demo_state()

    assert {:error, %{code: :unknown_character, message: message}} =
             Runtime.dispatch(state, Event.apology_offered("user", "unknown", "sorry"))

    assert message =~ "unknown character"
  end

  test "unsupported event returns structured error" do
    state = Runtime.demo_state()

    assert {:error, %{code: :unsupported_event}} = Runtime.dispatch(state, %{type: :story_event})
  end
end
