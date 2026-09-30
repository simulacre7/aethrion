defmodule Aethrion.TuningTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Runtime, Scenario, State, Tuning}
  alias Aethrion.Rules.{Gift, Mood}

  test "rules read defaults unless the world overrides them" do
    state = Runtime.demo_state()
    assert Tuning.get(state, Gift, :affinity_delta) == 10

    tuned = Tuning.put(state, :gift, :affinity_delta, 25)
    assert Tuning.get(tuned, Gift, :affinity_delta) == 25

    {tuned, _outputs} = dispatch!(tuned, Event.gift_received("user", "mina", "ring"))
    assert State.get_relationship(tuned, "mina", "user").affinity == 65
  end

  test "tuning reaches derived values such as mood" do
    state = Tuning.put(Runtime.demo_state(), Mood, :lonely_loneliness, 20)
    {state, _outputs} = dispatch!(state, Event.time_tick("t", hours: 1))

    assert character_state(state, "yuna").mood == :lonely
    assert character_state(state, "haru").mood == :neutral
  end

  test "tuning changes cascades: a lower confiding threshold lets news spread" do
    state =
      state(
        [character("a", traits: [:talkative]), character("b"), character("c")],
        [relationship("a", "b", trust: 20)]
      )

    events = [
      Event.gift_received("user", "c", "map", observed_by: ["a"]),
      Event.time_tick("t", hours: 1)
    ]

    {default, _outputs} = run!(state, events)
    {tuned, _outputs} = run!(Tuning.put(state, :autonomy, :trust_threshold, 20), events)

    refute Aethrion.Memories.knows_topic?(default, "b", "gift:e1")
    assert Aethrion.Memories.knows_topic?(tuned, "b", "gift:e1")
  end

  test "unknown parameters are rejected" do
    assert_raise ArgumentError, fn -> Tuning.put(Runtime.demo_state(), :gift, :sparkle, 1) end
    assert_raise ArgumentError, fn -> Tuning.put(Runtime.demo_state(), :nope, :x, 1) end
    assert_raise ArgumentError, fn -> Tuning.get(Runtime.demo_state(), Gift, :sparkle) end
  end

  test "json tuning is validated against declared parameters" do
    assert {:ok, %{gift: %{importance: 80}}} =
             Tuning.from_data(%{"gift" => %{"importance" => 80}})

    assert {:error, %{code: :invalid_tuning, details: %{rule: "magic"}}} =
             Tuning.from_data(%{"magic" => %{}})

    assert {:error, %{code: :invalid_tuning, details: %{rule: :gift, parameter: "sparkle"}}} =
             Tuning.from_data(%{"gift" => %{"sparkle" => 1}})

    assert {:error, %{code: :invalid_tuning, details: %{parameter: "importance", value: "high"}}} =
             Tuning.from_data(%{"gift" => %{"importance" => "high"}})
  end

  test "tuning persists and scenarios apply it" do
    state = Tuning.put(Runtime.demo_state(), :proactive, :cooldown_hours, 6)
    data = state |> State.to_data() |> Jason.encode!() |> Jason.decode!()

    assert State.from_data(data).tuning == %{proactive: %{cooldown_hours: 6}}

    assert {:ok, scenario} =
             Scenario.from_data(%{"tuning" => %{"proactive" => %{"cooldown_hours" => 6}}})

    assert scenario.state.tuning == %{proactive: %{cooldown_hours: 6}}

    assert {:error, %{code: :invalid_tuning, details: %{path: ["tuning"]}}} =
             Scenario.from_data(%{"tuning" => %{"proactive" => %{"patience" => 6}}})
  end

  test "describe lists defaults and current values" do
    state = Tuning.put(Runtime.demo_state(), :gift, :joy_delta, 5)
    described = Map.new(Tuning.describe(state))

    assert {:joy_delta, 20, 5} in described.gift
    assert {:affinity_delta, 10, 10} in described.gift
    refute Map.has_key?(described, :reply)
  end
end
