defmodule Aethrion.MessageTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Runtime, State}

  defp send_to_mina(tone, text \\ "hello") do
    dispatch!(Runtime.demo_state(), Event.message_sent("user", "mina", text, tone: tone))
  end

  test "warm messages build the relationship and ease loneliness" do
    {state, outputs} = send_to_mina(:warm, "Thank you for today.")

    relationship = State.get_relationship(state, "mina", "user")
    assert relationship.affinity == 44
    assert relationship.trust == 27
    assert character_state(state, "mina").loneliness == 0
    assert character_state(state, "mina").joy == 8

    assert [%{memory: %{kind: :experienced, importance: 45, data: %{"tone" => "warm"}}}] =
             of_type(outputs, :memory_created)
  end

  test "neutral messages only ease loneliness and are not remembered" do
    {state, outputs} = send_to_mina(:neutral)

    assert character_state(state, "mina").loneliness == 6
    assert State.get_relationship(state, "mina", "user").affinity == 40
    assert [] = of_type(outputs, :memory_created)
  end

  test "cold messages cool the relationship" do
    {state, _outputs} = send_to_mina(:cold, "whatever")

    relationship = State.get_relationship(state, "mina", "user")
    assert relationship.affinity == 37
    assert relationship.tension == 4
  end

  test "hostile messages hurt and upset the receiver" do
    {state, outputs} = send_to_mina(:hostile, "go away")

    relationship = State.get_relationship(state, "mina", "user")
    assert relationship.affinity == 32
    assert relationship.trust == 19
    assert relationship.tension == 10
    assert character_state(state, "mina").stress == 20

    {state, outputs2} =
      dispatch!(state, Event.message_sent("user", "mina", "I mean it", tone: :hostile))

    assert character_state(state, "mina").mood == :upset
    assert [%{text: "Why would you say that?"}] = of_type(outputs, :reply)
    assert [%{text: "Please stop."}] = of_type(outputs2, :reply)
  end

  test "replies carry a read-only context snapshot and depend on mood" do
    {_state, outputs} = send_to_mina(:warm, "You look happy.")

    assert [reply] = of_type(outputs, :reply)
    assert reply.character_id == "mina"
    assert reply.to == "user"
    assert reply.tone == :warm
    assert reply.context.kind == :reply
    assert reply.context.message == "You look happy."
    assert reply.context.speaker.mood == :neutral
    assert reply.context.relationship.affinity == 44
    assert reply.text == reply.context.fallback_text
  end

  test "a jealous character answers warmth guardedly" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())

    {_state, outputs} =
      dispatch!(state, Event.message_sent("user", "yuna", "You matter too.", tone: :warm))

    assert [%{text: "...Thanks. I guess I needed to hear that."}] = of_type(outputs, :reply)
  end

  test "characters do not auto-reply to each other" do
    {_state, outputs} =
      dispatch!(Runtime.demo_state(), Event.message_sent("haru", "yuna", "hey", tone: :warm))

    assert [] = of_type(outputs, :reply)
  end

  test "blocked characters do not reply" do
    state = State.update_character_state(Runtime.demo_state(), "mina", &%{&1 | blocked?: true})
    {_state, outputs} = dispatch!(state, Event.message_sent("user", "mina", "hi"))

    assert [] = of_type(outputs, :reply)
  end

  describe "history" do
    defp with_history(tone, count) do
      events =
        for i <- 1..count, do: Event.message_sent("user", "mina", "m#{i}", tone: tone)

      {state, _outputs} = run!(Runtime.demo_state(), events ++ [Event.time_tick("t", hours: 200)])
      # Reset feelings so only the next message's effect is measured.
      state
      |> State.update_character_state("mina", &%{&1 | stress: 0, joy: 0, loneliness: 50})
      |> State.update_relationship("mina", "user", &%{&1 | affinity: 0, trust: 0, tension: 0})
    end

    test "a record of kindness halves the impact of hostility" do
      state = with_history(:warm, 3)
      {:ok, step} = Runtime.step(state, Event.message_sent("user", "mina", "ugh", tone: :hostile))

      assert State.get_relationship(step.state, "mina", "user").tension == 5
      assert character_state(step.state, "mina").stress == 10
      assert Enum.any?(step.log, &(&1 =~ "benefit of the doubt"))
      assert [%{text: "That's not like you. Is something wrong?"}] = of_type(step.outputs, :reply)
    end

    test "too little kindness is not enough" do
      state = with_history(:warm, 2)

      {state, _outputs} =
        dispatch!(state, Event.message_sent("user", "mina", "ugh", tone: :hostile))

      assert State.get_relationship(state, "mina", "user").tension == 10
    end

    test "repeated hostility makes warmth land at half strength" do
      state = with_history(:hostile, 2)

      {:ok, step} =
        Runtime.step(state, Event.message_sent("user", "mina", "sorry, you ok?", tone: :warm))

      assert State.get_relationship(step.state, "mina", "user").affinity == 2
      # After a quiet stretch a kind word eases half the loneliness (50 -> 25),
      # and wariness halves that too.
      assert character_state(step.state, "mina").loneliness == 50 - 12
      assert Enum.any?(step.log, &(&1 =~ "wary of kindness"))
    end

    test "goodwill is tunable" do
      state =
        :warm
        |> with_history(3)
        |> Aethrion.Tuning.put(:message, :goodwill_percent, 0)

      {state, _outputs} =
        dispatch!(state, Event.message_sent("user", "mina", "ugh", tone: :hostile))

      assert State.get_relationship(state, "mina", "user").tension == 0
    end
  end

  describe "tension easing" do
    test "an apology eases tension toward the apologizer, never below zero" do
      {state, _outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "mina", "ugh", tone: :cold),
          Event.apology_offered("user", "mina", "sorry")
        ])

      assert State.get_relationship(state, "mina", "user").tension == 0
    end

    test "tension fades by day boundaries, however time is split" do
      {state, _outputs} =
        dispatch!(Runtime.demo_state(), Event.message_sent("user", "mina", "ugh", tone: :hostile))

      {one, _outputs} = dispatch!(state, Event.time_tick("t", hours: 72))
      {hourly, _outputs} = run!(state, for(_ <- 1..72, do: Event.time_tick("t", hours: 1)))

      assert State.get_relationship(one, "mina", "user").tension == 4
      assert State.get_relationship(hourly, "mina", "user").tension == 4
    end

    test "fading tension is traced but does not flood outputs or the log" do
      {state, _outputs} =
        dispatch!(Runtime.demo_state(), Event.message_sent("user", "mina", "ugh", tone: :hostile))

      {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 24))

      assert Enum.any?(step.trace, &(&1.rule == :time_passage and &1.field == :tension))

      refute Enum.any?(
               step.outputs,
               &(&1.type == :relationship_changed and &1.rule == :time_passage)
             )

      refute Enum.any?(step.log, &(&1 =~ "tension toward"))
    end
  end
end
