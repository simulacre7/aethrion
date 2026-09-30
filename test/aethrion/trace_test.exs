defmodule Aethrion.TraceTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Runtime, Trace}

  test "every state change is traced to a rule and an event" do
    {:ok, step} = Runtime.step(Runtime.demo_state(), flower_for_mina())

    assert %Trace{rule: :gift, event_id: "e1", field: :affinity, before: 40, after: 50} =
             Enum.find(step.trace, &(&1.kind == :relationship and &1.target == {"mina", "user"}))

    assert %Trace{rule: :observation, subject: "yuna", before: 0, after: 15} =
             Enum.find(step.trace, &(&1.kind == :character and &1.field == :jealousy))

    assert %Trace{rule: :mood, before: :neutral, after: :jealous} =
             Enum.find(step.trace, &(&1.field == :mood and &1.subject == "yuna"))

    assert Enum.all?(step.trace, &(&1.event_id == "e1"))
  end

  test "every output names the rule and event that produced it" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {:ok, step} = Runtime.step(state, Event.time_tick("t2", hours: 2))

    for output <- step.outputs do
      assert is_atom(output.rule)
      assert output.event_id in Enum.map(step.events, & &1.id)
    end

    assert %{rule: :proactive, event_id: "e2"} =
             Enum.find(
               step.outputs,
               &(&1.type == :proactive_message and &1.character_id == "yuna")
             )

    assert %{rule: :comfort, event_id: "e4"} =
             Enum.find(step.outputs, &(&1.type == :character_interaction and &1.kind == :comfort))
  end

  test "trace entries can be filtered by character and described" do
    {:ok, step} = Runtime.step(Runtime.demo_state(), flower_for_mina())

    yuna = Enum.filter(step.trace, &Trace.concerns?(&1, "yuna"))

    assert Enum.any?(yuna, &(&1.kind == :relationship))
    refute Enum.any?(yuna, &(&1.subject == "mina" and &1.kind == :character))

    descriptions = Enum.map(yuna, &Trace.describe/1)
    assert "e1 observation: yuna.jealousy 0 -> 15" in descriptions
    assert "e1 observation: yuna->mina.tension 0 -> 8" in descriptions
  end

  test "clamped changes record the applied delta" do
    state =
      Aethrion.State.update_relationship(
        Runtime.demo_state(),
        "mina",
        "user",
        &%{&1 | affinity: 95}
      )

    {:ok, step} = Runtime.step(state, Event.gift_received("user", "mina", "star"))

    assert [%{delta: %{affinity: 5}}] =
             Enum.filter(step.outputs, &(&1.type == :relationship_changed and &1.from == "mina"))
  end
end
