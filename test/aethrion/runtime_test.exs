defmodule Aethrion.RuntimeTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Runtime, State}
  alias Aethrion.LLM.FakeAdapter

  describe "gifts" do
    test "gift changes the receiver's affinity, joy, and loneliness and creates a memory" do
      {state, outputs} =
        dispatch!(
          Runtime.demo_state(),
          Event.gift_received("user", "mina", "flower", at: "test:t1")
        )

      assert State.get_relationship(state, "mina", "user").affinity == 50
      assert character_state(state, "mina").joy == 20
      assert character_state(state, "mina").loneliness == 2
      assert character_state(state, "mina").mood == :happy

      assert [%{character_id: "mina", content: "user gave mina a flower.", kind: :experienced}] =
               state.memories

      assert [%{memory: %{id: "memory:mina:gift:e1"}}] = of_type(outputs, :memory_created)

      assert [%{character_id: "mina", before: :neutral, after: :happy}] =
               of_type(outputs, :mood_changed)
    end

    test "an observer who cares about the giver becomes jealous and tense" do
      {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())

      assert character_state(state, "yuna").jealousy == 15
      assert character_state(state, "yuna").mood == :jealous
      assert State.get_relationship(state, "yuna", "mina").tension == 8
    end

    test "observers remember what they saw, linked to the receiver's memory by topic" do
      {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())

      mina_memory = Enum.find(state.memories, &(&1.character_id == "mina"))
      yuna_memory = Enum.find(state.memories, &(&1.character_id == "yuna"))

      assert yuna_memory.kind == :observed
      assert yuna_memory.content == "yuna saw user give mina a flower."
      assert yuna_memory.topic == mina_memory.topic
      assert yuna_memory.related_characters == ["user", "mina"]
    end

    test "observers who do not care about the giver only remember" do
      event = Event.gift_received("user", "mina", "tea", observed_by: ["haru"])
      {state, _outputs} = dispatch!(Runtime.demo_state(), event)

      assert character_state(state, "haru").jealousy == 0
      assert State.get_relationship(state, "haru", "mina").tension == 0
      assert Enum.any?(state.memories, &(&1.character_id == "haru" and &1.kind == :observed))
    end

    test "traits modify jealousy" do
      state =
        state(
          [
            character("ren"),
            character("calm", traits: [:calm]),
            character("soft", traits: [:sensitive])
          ],
          [
            relationship("calm", "user", affinity: 40),
            relationship("soft", "user", affinity: 40)
          ]
        )

      event = Event.gift_received("user", "ren", "ring", observed_by: ["calm", "soft"])
      {state, _outputs} = dispatch!(state, event)

      assert character_state(state, "calm").jealousy == 5
      assert character_state(state, "soft").jealousy == 15
    end

    test "the giver and receiver are never treated as observers" do
      event = Event.gift_received("yuna", "mina", "pin", observed_by: ["yuna", "mina"])
      {state, _outputs} = dispatch!(Runtime.demo_state(), event)

      refute Enum.any?(state.memories, &(&1.kind == :observed))
    end
  end

  describe "time" do
    test "time tick advances the clock and loneliness" do
      {state, _outputs} = dispatch!(Runtime.demo_state(), Event.time_tick("test:t2", hours: 2))

      assert state.clock == 2
      assert character_state(state, "mina").loneliness == 20
      assert character_state(state, "yuna").loneliness == 34
      assert character_state(state, "haru").loneliness == 16
      assert character_state(state, "haru").last_active_at == "test:t2"
    end

    test "inactive characters do not grow lonely" do
      state =
        Runtime.demo_state()
        |> State.update_character_state("haru", &%{&1 | active?: false})

      {state, _outputs} = dispatch!(state, Event.time_tick("test:t2", hours: 2))

      assert character_state(state, "haru").loneliness == 8
    end

    test "jealousy does not fade with time alone" do
      state =
        Runtime.demo_state()
        |> State.update_character_state("haru", &%{&1 | blocked?: true})

      {state, _outputs} =
        run!(state, [flower_for_mina(), Event.time_tick("test:t2", hours: 8)])

      assert character_state(state, "yuna").jealousy == 15
    end
  end

  describe "apology" do
    test "apology reduces social pressure and creates a reconciliation memory" do
      {state, outputs} =
        run!(Runtime.demo_state(), [
          flower_for_mina(),
          Event.apology_offered("user", "yuna", "I should have checked in with you too.",
            at: "test:t2"
          )
        ])

      assert character_state(state, "yuna").jealousy == 0
      assert character_state(state, "yuna").loneliness == 20
      assert character_state(state, "yuna").mood == :neutral
      assert State.get_relationship(state, "yuna", "user").trust == 28

      assert [%{character_id: "yuna", content: "user apologized to yuna: " <> _} | _] =
               state.memories

      assert Enum.any?(outputs, &match?(%{type: :memory_created}, &1))
    end
  end

  describe "proactive messages" do
    test "jealousy threshold emits a proactive message grounded in memory" do
      {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
      {_state, outputs} = dispatch!(state, Event.time_tick("test:t2", hours: 2))

      assert [message] = proactive(outputs, "yuna")
      assert message.reason == :jealous
      assert message.to == "user"
      assert message.text =~ "Mina"
      assert "memory:yuna:observed:e1" in message.memory_refs
      assert message.context.speaker.name == "Yuna"
    end

    test "a proactive message repeats only after its cooldown" do
      state =
        Runtime.demo_state()
        |> State.update_character_state("haru", &%{&1 | blocked?: true})

      {state, first} = run!(state, [flower_for_mina(), Event.time_tick("t2", hours: 2)])
      {state, during} = dispatch!(state, Event.time_tick("t3", hours: 10))
      {_state, after_cooldown} = dispatch!(state, Event.time_tick("t4", hours: 14))

      assert [%{reason: :jealous}] = proactive(first, "yuna")
      assert [] = proactive(during, "yuna")
      assert [%{reason: :jealous}] = proactive(after_cooldown, "yuna")
    end

    test "lonely characters reach out when nobody has been in touch" do
      {_state, outputs} = dispatch!(Runtime.demo_state(), Event.time_tick("t1", hours: 12))

      assert [%{reason: :lonely, text: "It's been quiet today." <> _}] =
               proactive(outputs, "mina")

      assert [%{reason: :lonely}] = proactive(outputs, "yuna")
      assert [] = proactive(outputs, "haru")
    end

    test "lonely messages recall the user's last kind words" do
      events = [
        Event.message_sent("user", "mina", "You did great today.", tone: :warm),
        Event.time_tick("t1", hours: 16)
      ]

      {_state, outputs} = run!(Runtime.demo_state(), events)

      assert [%{reason: :lonely, text: text}] = proactive(outputs, "mina")
      assert text =~ "You did great today."
    end

    test "blocked characters cannot proactively message" do
      state =
        Runtime.demo_state()
        |> State.update_character_state("yuna", &%{&1 | blocked?: true, jealousy: 50})

      {_state, outputs} = dispatch!(state, Event.time_tick("test:t1", hours: 1))

      assert [] = proactive(outputs, "yuna")
    end
  end

  describe "scenarios" do
    test "the ignored branch cascades: Yuna messages the user, confides in Haru, and is comforted" do
      {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
      {:ok, step} = Runtime.step(state, Event.time_tick("branch:ignored:t2", hours: 2))

      assert [
               %{id: "e2", type: :time_tick},
               %{id: "e3", type: :gossip_shared, from: "yuna", to: "haru", cause: "e2"},
               %{id: "e4", type: :comfort_offered, from: "haru", to: "yuna", cause: "e3"}
             ] = step.events

      assert [%{reason: :jealous}] = proactive(step.outputs, "yuna")

      assert [%{reason: :curious, text: "Yuna told me you gave Mina a flower. Smooth."}] =
               proactive(step.outputs, "haru")

      assert [%{kind: :gossip}, %{kind: :comfort}] = of_type(step.outputs, :character_interaction)

      yuna = character_state(step.state, "yuna")
      assert yuna.jealousy == 10
      assert yuna.loneliness == 18
      assert yuna.mood == :neutral
      assert State.get_relationship(step.state, "yuna", "haru").trust == 47
    end

    test "the apology branch stays calm" do
      {base, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())

      {state, outputs} =
        run!(base, [
          Event.apology_offered("user", "yuna", "I should have checked in with you too.",
            at: "branch:apology:t2"
          ),
          Event.time_tick("branch:apology:t3", hours: 2)
        ])

      assert character_state(state, "yuna").jealousy == 0
      assert character_state(state, "yuna").loneliness == 28
      assert [] = of_type(outputs, :proactive_message)
      assert [] = of_type(outputs, :character_interaction)
    end

    test "repeated gifts accumulate but the jealous message fires once" do
      events = [
        flower_for_mina("t1"),
        Event.gift_received("user", "mina", "book", observed_by: ["yuna"], at: "t2"),
        Event.gift_received("user", "mina", "tea", observed_by: ["yuna"], at: "t3"),
        Event.time_tick("t4", hours: 2)
      ]

      {state, outputs} = run!(Runtime.demo_state(), events)

      assert State.get_relationship(state, "mina", "user").affinity == 70
      assert State.get_relationship(state, "yuna", "mina").tension == 24
      assert [%{reason: :jealous}] = proactive(outputs, "yuna")
    end

    test "the same event sequence always produces the same state and outputs" do
      events = [
        flower_for_mina(),
        Event.message_sent("user", "haru", "Thanks for looking out for everyone.", tone: :warm),
        Event.time_tick("t2", hours: 3),
        Event.apology_offered("user", "yuna", "Sorry.", at: "t3"),
        Event.time_tick("t4", hours: 20)
      ]

      assert run!(Runtime.demo_state(), events) == run!(Runtime.demo_state(), events)
    end

    test "run/3 returns every step and stops at the first invalid event" do
      events = [flower_for_mina(), Event.time_tick("t2", hours: 2)]

      assert {:ok, state, [first, second]} = Runtime.run(Runtime.demo_state(), events)
      assert first.event.id == "e1"
      assert second.event.id == "e2"
      assert state == second.state

      assert {:error, %{code: :unknown_character, details: %{index: 1, steps: [_first]}}} =
               Runtime.run(Runtime.demo_state(), [
                 flower_for_mina(),
                 Event.gift_received("user", "nobody", "rock")
               ])
    end

    test "relationship and character values stay clamped" do
      events =
        for index <- 1..20 do
          Event.gift_received("user", "mina", "flower-#{index}",
            observed_by: ["yuna"],
            at: "test:#{index}"
          )
        end

      {state, _outputs} = run!(Runtime.demo_state(), events)

      for relationship <- Map.values(state.relationships),
          field <- [:affinity, :trust, :tension] do
        assert Map.fetch!(relationship, field) in -100..100
      end

      assert character_state(state, "yuna").jealousy == 100
    end
  end

  describe "expression boundary" do
    test "fake llm output does not mutate authoritative state" do
      state = Runtime.demo_state()

      assert FakeAdapter.proactive_message("yuna", :jealous) =~ "forgot about me"
      assert state == Runtime.demo_state()
    end
  end

  describe "errors" do
    test "unknown gift receiver returns structured error" do
      assert {:error, %{code: :unknown_character, message: message}} =
               Runtime.dispatch(
                 Runtime.demo_state(),
                 Event.gift_received("user", "unknown", "flower")
               )

      assert message =~ "unknown character"
    end

    test "unknown observer returns structured error" do
      assert {:error, %{code: :unknown_character, details: %{field: :observed_by}}} =
               Runtime.dispatch(
                 Runtime.demo_state(),
                 Event.gift_received("user", "mina", "flower", observed_by: ["ghost"])
               )
    end

    test "unknown apology receiver returns structured error" do
      assert {:error, %{code: :unknown_character}} =
               Runtime.dispatch(
                 Runtime.demo_state(),
                 Event.apology_offered("user", "unknown", "sorry")
               )
    end

    test "unsupported event returns structured error" do
      assert {:error, %{code: :unsupported_event}} =
               Runtime.dispatch(Runtime.demo_state(), %{type: :story_event})
    end

    test "events without a type and invalid state return structured errors" do
      assert {:error, %{code: :invalid_event}} = Runtime.dispatch(Runtime.demo_state(), %{})
      assert {:error, %{code: :invalid_state}} = Runtime.dispatch(%{}, Event.time_tick("t"))
    end

    test "messages require a known tone and distinct actors" do
      state = Runtime.demo_state()

      assert {:error, %{code: :invalid_event, details: %{field: :tone}}} =
               Runtime.dispatch(state, Event.message_sent("user", "mina", "hi", tone: :smug))

      assert {:error, %{code: :invalid_event, details: %{field: :from}}} =
               Runtime.dispatch(state, Event.message_sent("mina", "mina", "hi"))

      assert {:error, %{code: :invalid_event, details: %{field: :text}}} =
               Runtime.dispatch(state, Event.message_sent("user", "mina", ""))
    end

    test "gossip must reference a memory held by the teller" do
      {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())

      assert {:error, %{code: :invalid_event, details: %{field: :memory_id}}} =
               Runtime.dispatch(
                 state,
                 Event.gossip_shared("haru", "mina", "memory:yuna:observed:e1")
               )
    end

    test "invalid time ticks are rejected" do
      assert {:error, %{code: :invalid_event}} =
               Runtime.dispatch(Runtime.demo_state(), Event.time_tick("t", hours: 0))

      assert {:error, %{code: :invalid_event}} =
               Runtime.dispatch(Runtime.demo_state(), Event.time_tick("t", hours: "2"))
    end
  end
end
