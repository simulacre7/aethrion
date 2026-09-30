defmodule Aethrion.ReputationTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Explain, Memory, State}
  alias Aethrion.Rules.Consolidation

  # Haru and Yuna care about Mina; Mina trusts Yuna; nobody knows the user yet.
  defp world(opts \\ []) do
    State.new(
      characters: [character("mina"), character("haru"), character("yuna"), character("bo")],
      relationships:
        [
          relationship("haru", "mina", affinity: 40),
          relationship("yuna", "mina", affinity: 40),
          relationship("mina", "yuna", affinity: 40, trust: 40)
        ] ++ Keyword.get(opts, :relationships, [])
    )
  end

  defp to_user(state, from), do: State.get_relationship(state, from, "user")

  defp message(from, to, tone, observers \\ []),
    do: Event.message_sent(from, to, "...", tone: tone, observed_by: observers)

  describe "witnesses" do
    test "a witness who cares about the receiver trusts a hostile sender less" do
      {state, _outputs} = dispatch!(world(), message("user", "mina", :hostile, ["haru"]))

      assert %Memory{kind: :observed, topic: "message:e1", related_characters: ["user", "mina"]} =
               State.memory(state, "memory:haru:observed:e1")

      assert %{trust: -4, tension: 4, affinity: 0} = to_user(state, "haru")
    end

    test "kindness to a friend earns a little warmth" do
      {state, _outputs} = dispatch!(world(), message("user", "mina", :warm, ["haru"]))

      assert %{affinity: 2, trust: 1, tension: 0} = to_user(state, "haru")
    end

    test "a witness who does not care about the receiver only remembers" do
      {state, _outputs} = dispatch!(world(), message("user", "mina", :hostile, ["bo"]))

      assert State.memory(state, "memory:bo:observed:e1")
      assert %{trust: 0, tension: 0} = to_user(state, "bo")
    end

    test "neutral messages are not remembered by witnesses" do
      {state, _outputs} = dispatch!(world(), message("user", "mina", :neutral, ["haru"]))

      refute State.memory(state, "memory:haru:observed:e1")
    end

    test "the sender and receiver are not their own witnesses" do
      {state, _outputs} = dispatch!(world(), message("user", "mina", :hostile, ["mina", "haru"]))

      refute State.memory(state, "memory:mina:observed:e1")
      assert State.memory(state, "memory:haru:observed:e1")
    end

    test "an unknown witness is rejected" do
      assert {:error, %{code: :unknown_character, details: %{field: :observed_by}}} =
               Aethrion.Runtime.dispatch(world(), message("user", "mina", :hostile, ["zed"]))
    end

    test "the judgement is explained" do
      {:ok, step} = Aethrion.Runtime.step(world(), message("user", "mina", :hostile, ["haru"]))

      assert [%{rule: :reputation, event_id: "e1"} | _] =
               Explain.relationship([step], "haru", "user", :trust)
    end
  end

  describe "hearsay" do
    test "hearing about hostility to a friend has half the effect" do
      {state, _outputs} =
        run!(world(), [
          message("user", "mina", :hostile),
          Event.gossip_shared("mina", "yuna", "memory:mina:message:e1")
        ])

      assert State.memory(state, "memory:yuna:heard:e2")
      assert %{trust: -2, tension: 2} = to_user(state, "yuna")
    end

    test "nobody judges themselves from what they hear" do
      {state, _outputs} =
        run!(world(relationships: [relationship("haru", "yuna", affinity: 40)]), [
          message("haru", "mina", :hostile),
          Event.gossip_shared("mina", "haru", "memory:mina:message:e1")
        ])

      assert %{trust: 0, tension: 0} = State.get_relationship(state, "haru", "haru")
    end

    test "news that is not about treatment changes nothing" do
      {state, _outputs} =
        run!(world(), [
          Event.gift_received("user", "mina", "flower"),
          Event.gossip_shared("mina", "yuna", "memory:mina:gift:e1")
        ])

      assert %{trust: 0, tension: 0, affinity: 0} = to_user(state, "yuna")
    end
  end

  describe "reputation impressions" do
    setup do
      {state, _outputs} =
        run!(world(relationships: [relationship("haru", "yuna", affinity: 40)]), [
          message("user", "mina", :hostile, ["haru"]),
          message("user", "yuna", :hostile, ["haru"]),
          # Long enough for the sightings to fade, not the impression.
          Event.time_tick("t", hours: 120)
        ])

      %{state: state}
    end

    test "faded sightings fold into what the witness knows about the sender", %{state: state} do
      assert %Memory{
               kind: :impression,
               content: "haru knows user has been hostile to mina and yuna 2 times.",
               data: %{"event" => "reputation", "about" => ["mina", "yuna"], "count" => 2}
             } = State.memory(state, "memory:haru:reputation:hostile:user")

      assert Consolidation.reputation_count(state, "haru", "hostile", "user") == 2
      assert Consolidation.impression_count(state, "haru", "hostile", "user") == 0
    end

    test "a hostile reputation blunts the sender's warmth", %{state: state} do
      before = to_user(state, "haru")
      {:ok, step} = Aethrion.Runtime.step(state, message("user", "haru", :warm))
      after_warm = to_user(step.state, "haru")

      # 75% of +4 affinity and +2 trust.
      assert after_warm.affinity - before.affinity == 3
      assert after_warm.trust - before.trust == 1
      assert Enum.any?(step.trace, &((&1.detail || "") =~ "knowing how they have treated others"))
    end

    test "firsthand wariness takes precedence over reputation", %{state: state} do
      {state, _outputs} =
        run!(state, [
          message("user", "haru", :hostile),
          message("user", "haru", :hostile),
          Event.time_tick("t", hours: 200)
        ])

      before = to_user(state, "haru")
      {:ok, step} = Aethrion.Runtime.step(state, message("user", "haru", :warm))

      assert to_user(step.state, "haru").affinity - before.affinity == 2
      assert Enum.any?(step.trace, &((&1.detail || "") =~ "after repeated hostility"))
    end
  end

  test "a reputation for kindness softens harsh words" do
    {state, _outputs} =
      run!(world(relationships: [relationship("haru", "yuna", affinity: 40)]), [
        message("user", "mina", :warm, ["haru"]),
        message("user", "yuna", :warm, ["haru"]),
        message("user", "mina", :warm, ["haru"]),
        Event.time_tick("t", hours: 120)
      ])

    assert Consolidation.reputation_count(state, "haru", "warm", "user") == 3

    before = to_user(state, "haru")
    {:ok, step} = Aethrion.Runtime.step(state, message("user", "haru", :hostile))

    # 75% of -6 trust and +10 tension.
    assert to_user(step.state, "haru").trust - before.trust == -4
    assert to_user(step.state, "haru").tension - before.tension == 7
  end

  describe "replies" do
    defp warm_reply(state) do
      {_state, outputs} = dispatch!(state, message("user", "haru", :warm))
      [reply] = of_type(outputs, :reply)
      reply
    end

    test "a witness answers kindness with what they saw" do
      {state, _outputs} = dispatch!(world(), message("user", "mina", :hostile, ["haru"]))
      reply = warm_reply(state)

      assert reply.text == "Thanks... but I saw what you said to Mina."

      assert Aethrion.Expression.Templates.Ko.render(reply.context) ==
               "고마워... 그런데 네가 Mina한테 한 말, 나도 봤어."
    end

    test "a listener answers kindness with what they heard" do
      {state, _outputs} =
        run!(world(relationships: [relationship("mina", "haru", affinity: 40, trust: 60)]), [
          message("user", "mina", :hostile),
          Event.gossip_shared("mina", "haru", "memory:mina:message:e1")
        ])

      assert warm_reply(state).text == "Thanks... but I heard what you said to Mina."
    end

    test "a reputation is enough once the details fade" do
      {state, _outputs} =
        run!(world(relationships: [relationship("haru", "yuna", affinity: 40)]), [
          message("user", "mina", :hostile, ["haru"]),
          message("user", "yuna", :hostile, ["haru"]),
          Event.time_tick("t", hours: 120)
        ])

      assert warm_reply(state).text == "...Thanks. I've heard how you treat people, though."
    end
  end
end
