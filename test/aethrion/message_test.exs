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
    assert character_state(state, "mina").loneliness == 4
    assert character_state(state, "mina").joy == 8

    assert [%{memory: %{kind: :experienced, importance: 45, data: %{"tone" => "warm"}}}] =
             of_type(outputs, :memory_created)
  end

  test "neutral messages only ease loneliness and are not remembered" do
    {state, outputs} = send_to_mina(:neutral)

    assert character_state(state, "mina").loneliness == 8
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
end
