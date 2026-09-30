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

    test "inactive or blocked characters witness nothing" do
      for change <- [&%{&1 | active?: false}, &%{&1 | blocked?: true}] do
        state = update_in(world().characters["haru"].state, change)
        {state, _outputs} = dispatch!(state, message("user", "mina", :hostile, ["haru"]))

        refute State.memory(state, "memory:haru:observed:e1")
        assert %{trust: 0, tension: 0} = to_user(state, "haru")
      end
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

  describe "apologies in public" do
    test "witnesses who care trust the apologizer a little more and ease tension" do
      {state, _outputs} =
        run!(world(), [
          message("user", "mina", :hostile, ["haru"]),
          Event.apology_offered("user", "mina", "I'm sorry", observed_by: ["haru"])
        ])

      assert %Memory{kind: :observed, topic: "apology:e2"} =
               State.memory(state, "memory:haru:observed:e2")

      # -4 + 2 trust; +4 - 3 tension.
      assert %{trust: -2, tension: 1} = to_user(state, "haru")
    end

    test "easing tension never makes it negative" do
      {state, _outputs} =
        dispatch!(world(), Event.apology_offered("user", "mina", "sorry", observed_by: ["haru"]))

      assert %{trust: 2, tension: 0} = to_user(state, "haru")
    end

    test "hearing about an apology counts for half" do
      {state, _outputs} =
        run!(world(), [
          Event.apology_offered("user", "mina", "I'm sorry"),
          Event.gossip_shared("mina", "yuna", "memory:mina:apology:e1")
        ])

      assert %{trust: 1} = to_user(state, "yuna")
    end

    test "a witnessed apology takes the edge off a pointed reply" do
      {state, _outputs} =
        run!(world(), [
          message("user", "mina", :hostile, ["haru"]),
          Event.apology_offered("user", "mina", "I'm sorry", observed_by: ["haru"])
        ])

      {_state, outputs} = dispatch!(state, message("user", "haru", :warm))
      [reply] = of_type(outputs, :reply)
      refute reply.text =~ "what you said to Mina"
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

  describe "counting each story once" do
    test "hearing again about a message whose details were forgotten changes nothing" do
      state =
        State.new(
          characters: [character("mina"), character("haru"), character("sora")],
          relationships: [
            relationship("haru", "mina", affinity: 40),
            relationship("sora", "mina", affinity: 40)
          ]
        )

      hostile = &message("user", "mina", :hostile, &1)

      # Haru's sightings fold into a reputation and are forgotten; Sora keeps
      # a single, unconsolidated memory of the first message.
      {state, _outputs} =
        run!(state, [
          hostile.(["haru", "sora"]),
          hostile.(["haru"]),
          Event.time_tick("t", hours: 960),
          Event.time_tick("t", hours: 1)
        ])

      refute State.memory(state, "memory:haru:observed:e1")
      assert State.memory(state, "memory:sora:observed:e1")
      trust = to_user(state, "haru").trust

      {state, _outputs} =
        run!(state, [
          Event.gossip_shared("sora", "haru", "memory:sora:observed:e1"),
          Event.time_tick("t", hours: 240)
        ])

      assert to_user(state, "haru").trust == trust
      refute State.memory(state, "memory:haru:heard:e5")

      assert %Memory{data: %{"count" => 2, "topics" => ["message:e1", "message:e2"]}} =
               State.memory(state, "memory:haru:reputation:hostile:user")
    end
  end

  describe "firsthand history wins" do
    defp impression(scope, pattern, count) do
      Memory.new(
        id: "memory:mina:#{scope}:#{pattern}:user",
        character_id: "mina",
        content: "#{scope} #{pattern}",
        importance: 80,
        created_at: "consolidated",
        kind: :impression,
        topic: "#{scope}:mina:#{pattern}:user",
        related_characters: ["user"],
        data: %{
          "event" => if(scope == "impression", do: "impression", else: "reputation"),
          "pattern" => pattern,
          "from" => "user",
          "to" => "mina",
          "about" => ["yuna"],
          "count" => count
        }
      )
    end

    defp land(memories, tone) do
      state = %{world() | memories: memories}
      {:ok, step} = Aethrion.Runtime.step(state, message("user", "mina", tone))
      {State.get_relationship(step.state, "mina", "user"), step}
    end

    test "a warm record with the receiver outweighs a hostile reputation" do
      {rel, step} =
        land([impression("impression", "warm", 5), impression("reputation", "hostile", 2)], :warm)

      assert rel.affinity == 4
      assert [%{text: "That's sweet of you."}] = of_type(step.outputs, :reply)
    end

    test "a hostile record with the receiver outweighs a warm reputation" do
      {rel, _step} =
        land(
          [impression("impression", "hostile", 4), impression("reputation", "warm", 3)],
          :hostile
        )

      assert rel.trust == -6
    end
  end

  test "watching gifts to others is not a reputation" do
    {state, _outputs} =
      run!(world(relationships: [relationship("mina", "yuna", affinity: 40, trust: 40)]), [
        Event.gift_received("user", "yuna", "a", observed_by: ["mina"]),
        Event.gift_received("user", "yuna", "b", observed_by: ["mina"]),
        Event.time_tick("t", hours: 200)
      ])

    assert Consolidation.reputation_count(state, "mina", "gift", "user") == 0
    assert %{consolidated_into: nil} = State.memory(state, "memory:mina:observed:e1")
  end

  describe "speaking up" do
    defp protective(outputs),
      do: outputs |> of_type(:proactive_message) |> Enum.filter(&(&1.reason == :protective))

    test "a witness who cares speaks up to the person, once per incident" do
      {_state, outputs} =
        run!(world(), [
          message("user", "mina", :hostile, ["haru"]),
          Event.time_tick("t", hours: 2)
        ])

      assert [%{character_id: "haru", to: "user", text: text}] = protective(outputs)
      assert text == "That was harsh, what you said to Mina. Mina didn't deserve that."
    end

    test "calm characters say it gently, in both languages" do
      state = put_in(world().characters["haru"].traits, [:calm])
      {_state, outputs} = dispatch!(state, message("user", "mina", :hostile, ["haru"]))

      assert [%{text: "What you said to Mina was unkind. Is everything okay?"} = output] =
               protective(outputs)

      assert Aethrion.Expression.Templates.Ko.render(output.context) ==
               "Mina한테 한 말은 좀 모질었어. 무슨 일 있어?"
    end

    test "nobody speaks up for someone they do not care about, or to a character" do
      {_state, outputs} = dispatch!(world(), message("user", "mina", :hostile, ["bo"]))
      assert protective(outputs) == []

      {_state, outputs} = dispatch!(world(), message("yuna", "mina", :hostile, ["haru"]))
      assert protective(outputs) == []
    end

    test "cold words or hearsay are not enough" do
      {_state, outputs} = dispatch!(world(), message("user", "mina", :cold, ["haru"]))
      assert protective(outputs) == []

      {_state, outputs} =
        run!(world(), [
          message("user", "mina", :hostile),
          Event.gossip_shared("mina", "yuna", "memory:mina:message:e1")
        ])

      assert protective(outputs) == []
    end
  end

  describe "long-running worlds stay bounded" do
    test "curiosity keys are dropped once the news has faded" do
      {state, _outputs} =
        run!(Aethrion.Runtime.demo_state(), [flower_for_mina(), Event.time_tick("t", hours: 2)])

      key = "proactive:haru:curious:gift:e1"
      assert Map.has_key?(state.cooldowns, key)

      {state, _outputs} = dispatch!(state, Event.time_tick("t", hours: 200))
      refute Map.has_key?(state.cooldowns, key)
    end

    test "impressions keep only topics some memory still carries" do
      hostile = &message("user", "mina", :hostile, &1)

      {state, _outputs} =
        run!(world(), [
          hostile.(["haru"]),
          hostile.(["haru"]),
          Event.time_tick("t", hours: 120),
          # Both sightings are forgotten; then two more fold into the same reputation.
          Event.time_tick("t", hours: 900),
          hostile.(["haru"]),
          hostile.(["haru"]),
          Event.time_tick("t", hours: 120)
        ])

      assert %Memory{data: %{"count" => 4, "topics" => topics}} =
               State.memory(state, "memory:haru:reputation:hostile:user")

      live = for m <- state.memories, m.kind != :impression, into: MapSet.new(), do: m.topic

      # Nothing remembers the first message any more, so it cannot be retold.
      refute MapSet.member?(live, "message:e1")
      refute "message:e1" in topics
      assert Enum.all?(topics, &MapSet.member?(live, &1))
    end
  end
end
