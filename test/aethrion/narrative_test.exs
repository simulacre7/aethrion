defmodule Aethrion.NarrativeTest do
  # Behavior found by playing long sessions: what a person would find
  # implausible if it happened.
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Runtime, State}
  alias Aethrion.Expression.Templates.Ko
  alias Aethrion.Rules.Bond

  defp replies(outputs, id), do: for(%{type: :reply, character_id: ^id} = o <- outputs, do: o)

  describe "loneliness" do
    test "a character talked to every day does not saturate into loneliness" do
      events =
        Enum.flat_map(1..8, fn day ->
          [Event.message_sent("user", "mina", "Morning #{day}!", tone: :warm), tick(24)]
        end)

      {state, outputs} = run!(Runtime.demo_state(), events)

      assert character_state(state, "mina").mood != :lonely
      assert [] = proactive(outputs, "mina")
      assert State.get_relationship(state, "mina", "user") |> Bond.derive(state) == :close
    end

    test "unanswered lonely messages space out and change their tune" do
      state = Runtime.demo_state()
      {state, outputs} = run!(state, List.duplicate(tick(24), 14))

      sent =
        for %{type: :proactive_message, character_id: "mina"} = o <- outputs,
            do: {o.event_id, o.text}

      # Day 1, then three days after no reply, then a week after a week of silence.
      assert [
               {_, "It's been a while" <> _},
               {_, "We haven't talked in a few days." <> _},
               {_, busy}
             ] =
               sent

      assert busy == "I guess you've been busy. I'll be here whenever you want to talk."

      # Each message after one that went unanswered costs a little affinity.
      assert State.get_relationship(state, "mina", "user").affinity == 40 - 2 * 2
    end

    test "a week of silence never shortens a longer tuned wait" do
      state = Aethrion.Tuning.put(Runtime.demo_state(), :proactive, :unanswered_hours, 240)
      {_state, outputs} = run!(state, List.duplicate(tick(24), 30))

      # Day 1, then every ten days: a week of silence does not bring it forward.
      assert length(proactive(outputs, "mina")) == 3
    end

    test "a reply resets the wait to a day" do
      {state, _outputs} = run!(Runtime.demo_state(), [tick(24)])

      {_state, outputs} =
        run!(state, [
          Event.message_sent("user", "mina", "Sorry, I was busy.", tone: :neutral),
          tick(24),
          tick(24)
        ])

      assert [%{reason: :lonely}] = proactive(outputs, "mina")
    end

    test "characters only reach out to someone they like enough" do
      # Haru likes the user at 20: lonely, but no message.
      state =
        State.update_relationship(Runtime.demo_state(), "haru", "yuna", &%{&1 | affinity: 0})

      {state, outputs} = run!(state, [tick(48)])

      assert character_state(state, "haru").loneliness >= 60
      assert [] = proactive(outputs, "haru")
    end

    test "a character heading out with a friend does not also message" do
      {_state, outputs} = run!(Runtime.demo_state(), [tick(24)])

      assert [%{kind: :together, character_id: "haru", to: "yuna"}] =
               of_type(outputs, :character_interaction)

      assert [] = proactive(outputs, "yuna")
    end

    test "lonely messages do not quote kind words over harsh ones" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "mina", "You did great today.", tone: :warm),
          Event.message_sent("user", "mina", "Actually, never mind.", tone: :hostile),
          tick(24),
          tick(24),
          tick(24)
        ])

      for %{text: text} <- proactive(outputs, "mina") do
        refute text =~ "You did great today."
      end
    end
  end

  describe "apologies" do
    test "an apology repairs at most what the insult took, and less each time" do
      insult = Event.message_sent("user", "mina", "Go away.", tone: :hostile)
      sorry = Event.apology_offered("user", "mina", "Sorry.")

      trust = fn state -> State.get_relationship(state, "mina", "user").trust end

      {state, _} = run!(Runtime.demo_state(), [insult])
      {after_one, _} = run!(state, [sorry])
      {state, _} = run!(after_one, [insult])
      {after_two, _} = run!(state, [sorry])

      # Up to 8, but no more than the insult cost; the next one repairs half.
      assert trust.(after_one) == 25 - 6 + 6
      assert trust.(after_two) == trust.(after_one) - 6 + 4
    end

    test "an apology from someone seen being hostile to others is taken warily" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "yuna", "Leave me alone.",
            tone: :hostile,
            observed_by: ["haru"]
          ),
          Event.message_sent("user", "haru", "You too.", tone: :hostile),
          Event.apology_offered("user", "haru", "I was out of line.")
        ])

      assert [%{context: context, text: text}] =
               for(o <- replies(outputs, "haru"), o.tone == :apology, do: o)

      assert text == "Thank you. But I've seen how you treat others too, so give me time."
      assert Ko.render(context) =~ "다른 사람들한테 어떻게 하는지도 봤어"
    end

    test "amends seen made to someone else are not apologies to oneself" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "yuna", "Leave me alone.",
            tone: :hostile,
            observed_by: ["haru"]
          ),
          Event.apology_offered("user", "yuna", "I'm sorry.", observed_by: ["haru"]),
          Event.message_sent("user", "haru", "You too.", tone: :hostile),
          Event.apology_offered("user", "haru", "I was out of line.")
        ])

      assert [%{text: text}] = for(o <- replies(outputs, "haru"), o.tone == :apology, do: o)
      refute text =~ "habit"
      refute text =~ "seen how you treat others"
    end

    test "an insult and apology never gain trust, however they are spread out" do
      trust = fn state, who -> State.get_relationship(state, who, "user").trust end
      insult = &Event.message_sent("user", &1, "Go away.", tone: :hostile)
      sorry = &Event.apology_offered("user", &1, "Sorry.")

      # Long enough for the insult to fade before the apology.
      cycle = [insult.("mina"), tick(130), sorry.("mina"), tick(40)]
      {state, _} = run!(Runtime.demo_state(), cycle ++ cycle ++ cycle)
      assert trust.(state, "mina") <= trust.(Runtime.demo_state(), "mina")

      # Only what the words actually took comes back.
      low =
        State.update_relationship(Runtime.demo_state(), "haru", "user", &%{&1 | trust: 3})

      {state, _} = run!(low, [insult.("haru"), sorry.("haru")])
      assert trust.(state, "haru") == 3

      # Two insults, one apology: still behind.
      {state, _} = run!(low, [insult.("haru"), insult.("haru"), sorry.("haru")])
      assert trust.(state, "haru") < 3

      # An apology seen made to someone else is not the last one to oneself:
      # one's own still gives back what the insult took.
      {seen, _} =
        run!(Runtime.demo_state(), [
          insult.("haru"),
          Event.apology_offered("user", "yuna", "Sorry.", observed_by: ["haru"])
        ])

      {state, _} = run!(seen, [sorry.("haru")])
      assert trust.(state, "haru") - trust.(seen, "haru") == 6
    end

    test "amends seen made to others do not undo one's own forgiveness" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "haru", "Useless.", tone: :hostile),
          Event.apology_offered("user", "haru", "Sorry."),
          Event.message_sent("user", "yuna", "Go away.", tone: :hostile, observed_by: ["haru"]),
          Event.apology_offered("user", "yuna", "Sorry.", observed_by: ["haru"]),
          Event.apology_offered("user", "haru", "Sorry again.")
        ])

      texts = for o <- replies(outputs, "haru"), o.tone == :apology, do: o.text
      assert List.last(texts) == "It's okay, really. We're good now."
    end

    test "an apology from someone only heard about says heard, not seen" do
      memory = fn kind, to, event, n ->
        %{
          kind: kind,
          topic: "x:e#{n}",
          data: %{"event" => event, "from" => "user", "to" => to, "tone" => "hostile"}
        }
      end

      request = %Aethrion.Expression.Request{
        kind: :reply,
        reason: :reply,
        tone: :apology,
        speaker: %{id: "haru", name: "Haru", traits: [], mood: :neutral},
        listener: %{id: "user", name: "you"},
        relationship: %{affinity: 30, trust: 20, tension: 0, bond: :neutral},
        names: %{"user" => "you", "yuna" => "Yuna", "haru" => "Haru"},
        memories: [
          memory.(:heard, "yuna", "message_sent", 1),
          memory.(:experienced, "haru", "message_sent", 2),
          memory.(:experienced, "haru", "apology_offered", 3)
        ]
      }

      assert Aethrion.Expression.Templates.render(request) ==
               "Thank you. But I've heard how you treat others too, so give me time."

      assert Ko.render(request) =~ "어떻게 하는지도 들었어"
    end

    test "saying sorry for nothing builds no trust" do
      trust = fn state -> State.get_relationship(state, "haru", "user").trust end
      sorry = Event.apology_offered("user", "haru", "Sorry!")
      {state, _} = run!(Runtime.demo_state(), [sorry, sorry, sorry])
      assert trust.(state) == trust.(Runtime.demo_state())
    end

    test "apologizing again for one thing is not taken as a pattern" do
      events =
        [Event.message_sent("user", "haru", "Useless.", tone: :hostile)] ++
          List.duplicate(Event.apology_offered("user", "haru", "I was rude."), 4)

      {_state, outputs} = run!(Runtime.demo_state(), events)
      texts = for o <- replies(outputs, "haru"), o.tone == :apology, do: o.text

      refute Enum.any?(texts, &(&1 =~ "keep saying sorry"))
      assert List.last(texts) == "You already apologized. It's okay, really."
    end

    test "an insult-and-apology cycle does not build trust" do
      cycle = fn i ->
        [
          Event.message_sent("user", "mina", "You're the best #{i}", tone: :warm),
          tick(3),
          Event.message_sent("user", "mina", "Go away #{i}", tone: :hostile),
          tick(3),
          Event.apology_offered("user", "mina", "Sorry #{i}"),
          tick(18)
        ]
      end

      {state, outputs} = run!(Runtime.demo_state(), Enum.flat_map(1..6, cycle))

      relationship = State.get_relationship(state, "mina", "user")
      assert relationship.trust < 25
      assert Bond.derive(relationship, state) == :strained

      texts = for o <- replies(outputs, "mina"), o.tone == :apology, do: o.text
      assert "Okay... Just please don't make a habit of it." in texts
      assert List.last(texts) == "You keep saying sorry. I just need it to stop happening."

      # The benefit of the doubt runs out.
      hostile_replies = for o <- replies(outputs, "mina"), o.tone == :hostile, do: o.text
      refute "That's not like you. Is something wrong?" in hostile_replies
    end

    test "an apology for a gift someone else got lands as relief" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          flower_for_mina(),
          Event.apology_offered("user", "yuna", "I should have thought of you too.")
        ])

      assert [%{tone: :apology, text: "Thanks. I just wanted to feel remembered too."} = reply] =
               replies(outputs, "yuna")

      assert Ko.render(reply.context) == "고마워. 나도 좀 챙겨 줬으면 해서 그랬어."
    end

    test "apologizing again for something already forgiven is settled, not a pattern" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "mina", "Go away.", tone: :hostile),
          Event.apology_offered("user", "mina", "Sorry."),
          tick(48),
          Event.apology_offered("user", "mina", "Still sorry about that.")
        ])

      assert %{text: "It's okay, really. We're good now."} = List.last(replies(outputs, "mina"))
    end

    test "an apology out of nowhere is waved off" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [Event.apology_offered("user", "haru", "Sorry about earlier.")])

      assert [%{text: "You don't have to apologize. We're okay."}] = replies(outputs, "haru")
    end
  end

  describe "hurt feelings" do
    test "a fresh insult makes replies guarded whatever the mood" do
      {state, _outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "yuna", "Leave me alone.", tone: :hostile),
          tick(20)
        ])

      assert State.get_relationship(state, "yuna", "user").tension >= 10

      {_state, outputs} =
        run!(state, [Event.message_sent("user", "yuna", "Hey, thanks!", tone: :warm)])

      assert [%{text: "Thanks... I'm still a little hurt, though."} = reply] =
               replies(outputs, "yuna")

      assert Ko.render(reply.context) == "고마워... 그래도 아직 좀 서운해."
    end

    test "a hurt character keeps their distance for days" do
      # Without Haru to keep her company, a lonely Yuna would write to the user.
      alone = State.update_character_state(Runtime.demo_state(), "haru", &%{&1 | blocked?: true})
      days = [tick(24), tick(24)]
      to_user = fn outputs -> for %{to: "user"} = o <- proactive(outputs, "yuna"), do: o end

      {_state, outputs} = run!(alone, days)
      assert [_ | _] = to_user.(outputs)

      {_state, outputs} =
        run!(alone, [
          Event.message_sent("user", "yuna", "You're so needy.", tone: :hostile) | days
        ])

      assert [] = to_user.(outputs)
    end

    test "jealousy fades within days, and old news is 'the other day'" do
      state =
        State.update_character_state(Runtime.demo_state(), "yuna", &%{&1 | jealousy: 20})

      {state, outputs} = run!(state, [flower_for_mina(), tick(2)])
      assert [%{text: "You looked happy with Mina earlier." <> _}] = proactive(outputs, "yuna")

      {state, outputs} = run!(state, [tick(24)])

      assert [%{text: "You looked happy with Mina the other day." <> _} = message] =
               proactive(outputs, "yuna")

      assert Ko.render(message.context) =~ "지난번에 Mina랑"

      {state, _outputs} = run!(state, [tick(96)])
      assert character_state(state, "yuna").jealousy < 15
    end
  end

  describe "bonds" do
    test "a bond does not flicker at its threshold" do
      state =
        Runtime.demo_state()
        |> State.update_relationship("mina", "user", &%{&1 | affinity: 24, trust: 20})

      warm = Event.message_sent("user", "mina", "Thanks!", tone: :warm)
      cold = Event.message_sent("user", "mina", "Whatever.", tone: :cold)

      {state, outputs} = run!(state, [warm, cold, warm, cold])

      assert [%{before: :neutral, after: :friendly}] = of_type(outputs, :bond_changed)
      assert State.get_relationship(state, "mina", "user").bond == :friendly
    end

    test "a bond gets worse at once, and heals past the margin" do
      state = Runtime.demo_state()
      hostile = Event.message_sent("user", "mina", "Stop.", tone: :hostile)

      {state, outputs} = run!(state, [hostile, hostile])
      assert %{after: :strained} = List.last(of_type(outputs, :bond_changed))

      # Tension 20 eases to 16 over two days: still strained within the margin.
      {state, _outputs} = run!(state, [tick(48)])
      relationship = State.get_relationship(state, "mina", "user")
      assert relationship.tension == 16
      assert Bond.derive(relationship, state) == :strained
    end

    test "the recorded bond survives saving and loading" do
      {state, _outputs} =
        run!(Runtime.demo_state(), [Event.message_sent("user", "mina", "Hi!", tone: :warm)])

      assert %{bond: bond} = State.get_relationship(state, "mina", "user")
      refute is_nil(bond)

      {:ok, loaded} =
        state |> State.to_data() |> Jason.encode!() |> Jason.decode!() |> State.parse()

      assert State.get_relationship(loaded, "mina", "user").bond == bond
    end
  end

  describe "secondhand news" do
    test "no one asks about harsh words they saw for themselves" do
      state =
        State.update_relationship(Runtime.demo_state(), "haru", "user", &%{&1 | affinity: 40})

      {_state, outputs} =
        run!(state, [
          Event.message_sent("user", "yuna", "You're so needy.",
            tone: :hostile,
            observed_by: ["haru"]
          ),
          Event.message_sent("user", "yuna", "Leave me alone.", tone: :hostile),
          tick(24)
        ])

      reasons = for o <- proactive(outputs, "haru"), do: o.reason
      assert :protective in reasons
      refute :curious in reasons
    end

    test "Korean curiosity names who was spoken to" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "mina", "Not now.", tone: :hostile, observed_by: ["yuna"]),
          Event.gossip_shared("yuna", "haru", "memory:yuna:observed:e1")
        ])

      assert [%{reason: :curious} = message] = proactive(outputs, "haru")
      assert message.text =~ "Yuna told me what you said to Mina."
      assert Ko.render(message.context) =~ "Yuna한테 들었어. 네가 Mina한테 그런 말 했다며?"
    end
  end

  describe "variety" do
    test "the same kindness gets different words, and repeated insults escalate" do
      warm = &Event.message_sent("user", "mina", "Thanks #{&1}", tone: :warm)
      hostile = &Event.message_sent("user", "mina", "Go away #{&1}", tone: :hostile)

      {_state, outputs} = run!(Runtime.demo_state(), [warm.(1), warm.(2), warm.(3)])
      texts = for o <- replies(outputs, "mina"), do: o.text
      assert length(Enum.uniq(texts)) == 3

      {_state, outputs} =
        run!(Runtime.demo_state(), [hostile.(1), tick(12), hostile.(2), tick(12), hostile.(3)])

      assert [_first, "Again? What is going on with you?", "I'm not doing this with you anymore."] =
               for(o <- replies(outputs, "mina"), do: o.text)
    end

    test "kind words the day after an insult are met warily, until an apology" do
      {state, _outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "haru", "Useless.", tone: :hostile),
          tick(12)
        ])

      {_state, outputs} = run!(state, [Event.message_sent("user", "haru", "Hey!", tone: :warm)])
      assert [%{text: "Thanks... I'm still a little hurt, though."}] = replies(outputs, "haru")

      {_state, outputs} =
        run!(state, [
          Event.apology_offered("user", "haru", "Sorry."),
          Event.message_sent("user", "haru", "Hey!", tone: :warm)
        ])

      refute List.last(replies(outputs, "haru")).text =~ "hurt"
    end

    test "an insult right after an apology still hurts, whatever the hour" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.apology_offered("user", "haru", "Sorry about before."),
          Event.message_sent("user", "haru", "Useless.", tone: :hostile),
          Event.message_sent("user", "haru", "Hey!", tone: :warm)
        ])

      assert List.last(replies(outputs, "haru")).text =~ "hurt"
    end

    test "several plain messages within an hour do not get the same reply" do
      say = fn text -> Event.message_sent("user", "mina", text, tone: :neutral) end
      {_state, outputs} = run!(Runtime.demo_state(), Enum.map(1..3, &say.("hi #{&1}")))

      assert length(Enum.uniq(Enum.map(replies(outputs, "mina"), & &1.text))) >= 2
    end

    test "sensitive characters take harsh words harder" do
      hostile = fn to -> Event.message_sent("user", to, "Leave me alone.", tone: :hostile) end
      {state, _outputs} = run!(Runtime.demo_state(), [hostile.("mina"), hostile.("yuna")])

      assert character_state(state, "mina").stress == 20
      assert character_state(state, "yuna").stress == 30
    end

    test "a plain question gets an answer that fits a question" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "haru", "What are you reading these days?", tone: :neutral)
        ])

      assert [%{text: text, context: context}] = replies(outputs, "haru")
      assert text in ["Hmm, good question.", "Let me think about that.", "Why, are you curious?"]
      assert Ko.render(context) in ["음, 글쎄. 생각 좀 해 볼게.", "왜? 궁금해?", "음... 좋은 질문이네."]
    end

    test "a first harsh word lands by temperament" do
      hostile = fn to -> Event.message_sent("user", to, "Leave me alone.", tone: :hostile) end
      {_state, outputs} = run!(Runtime.demo_state(), Enum.map(["mina", "yuna", "haru"], hostile))

      texts = Enum.map(outputs |> of_type(:reply), & &1.text)
      assert length(Enum.uniq(texts)) == 3

      assert Enum.map(of_type(outputs, :reply), &Ko.render(&1.context)) == [
               "왜 그런 말을 해?",
               "그 말 좀 아프다. 왜 그런 말을 해?",
               "...그건 좀 너무했다."
             ]
    end

    test "a scene carries the bond its own event records" do
      state =
        State.new(
          characters: [
            %Aethrion.Character{id: "ana", name: "Ana"},
            %Aethrion.Character{id: "ben", name: "Ben"}
          ],
          relationships: [
            %Aethrion.Relationship{
              from: "ana",
              to: "ben",
              affinity: 49,
              trust: 30,
              bond: :friendly
            },
            %Aethrion.Relationship{
              from: "ben",
              to: "ana",
              affinity: 49,
              trust: 30,
              bond: :friendly
            }
          ]
        )

      {_state, outputs} = run!(state, [Event.time_spent_together("ana", "ben")])

      assert [%{after: bond}] =
               for(%{type: :bond_changed, from: "ana", to: "ben"} = o <- outputs, do: o)

      assert [%{context: %{relationship: %{bond: ^bond}}}] =
               of_type(outputs, :character_interaction)
    end

    test "friends do not spend every afternoon the same way" do
      {_state, outputs} = run!(Runtime.demo_state(), List.duplicate(tick(24), 5))

      scenes =
        for %{kind: :together, text: text} <- of_type(outputs, :character_interaction), do: text

      assert length(Enum.uniq(scenes)) >= 3
    end
  end

  describe "gifts" do
    test "jealousy goes to the giver who caused it, not the last gift seen" do
      state =
        State.update_relationship(
          %{Runtime.demo_state() | people: %{"bob" => "Bob"}},
          "yuna",
          "bob",
          &%{&1 | affinity: 5}
        )

      {_state, outputs} =
        run!(state, [
          flower_for_mina(),
          Event.gift_received("bob", "haru", "pin", observed_by: ["yuna"]),
          tick(2)
        ])

      assert [%{to: "user"}] = for(%{reason: :jealous} = o <- proactive(outputs, "yuna"), do: o)
    end

    test "someone heard from lately feels left out rather than forgotten" do
      seen = [flower_for_mina(), tick(2)]
      jealous = &for(%{reason: :jealous} = o <- proactive(&1, "yuna"), do: o)

      {_state, outputs} = run!(Runtime.demo_state(), seen)
      assert [%{text: forgotten}] = jealous.(outputs)
      assert forgotten =~ "forgot about me"

      chatted = [Event.message_sent("user", "yuna", "Hey Yuna", tone: :neutral), tick(20)]
      {_state, outputs} = run!(Runtime.demo_state(), chatted ++ seen)
      assert [%{text: left_out, context: context}] = jealous.(outputs)
      assert left_out =~ "a little left out"
      assert Ko.render(context) =~ "서운했어"
    end

    test "a second gift is not thanked the same way, and items are named in Korean" do
      gift = Event.gift_received("user", "haru", "chocolate")
      {_state, outputs} = run!(Runtime.demo_state(), [gift, gift])

      assert [first, second] = replies(outputs, "haru")
      assert first.text != second.text
      assert Ko.render(first.context) == "초콜릿? ...고맙다. 잘 먹을게."
      assert Ko.render(second.context) == "또 선물이야? 정말 고마워!"

      {_state, outputs} =
        run!(Runtime.demo_state(), [Event.gift_received("user", "haru", "moonstone")])

      assert [%{context: context}] = replies(outputs, "haru")
      assert Ko.render(context) == "선물이야? ...고맙다. 잘 쓸게."
    end

    test "a gift gets a reply that fits, and reassures someone jealous of that giver" do
      {state, _outputs} = run!(Runtime.demo_state(), [flower_for_mina()])

      {after_gift, outputs} = run!(state, [Event.gift_received("user", "yuna", "ribbon")])

      assert [%{tone: :gift, text: "For me? ...I thought you'd forgotten about me."} = reply] =
               replies(outputs, "yuna")

      assert Ko.render(reply.context) == "나한테 주는 거야? ...나 잊은 줄 알았어."
      assert character_state(after_gift, "yuna").jealousy == 5

      # Jealous, but not of this giver: just thanks.
      {_state, outputs} = run!(state, [Event.gift_received("sam", "yuna", "ribbon")])
      assert [%{text: "Thank you for the ribbon!"}] = replies(outputs, "yuna")

      {_state, outputs} =
        run!(Runtime.demo_state(), [Event.gift_received("user", "haru", "tea")])

      assert [%{text: "Thank you for the tea!"}] = replies(outputs, "haru")
    end

    test "a second gift the same day is noticed, not felt again, and never by its receiver" do
      gift = &Event.gift_received("user", &1, &2, observed_by: ["yuna"])

      {state, _outputs} =
        run!(Runtime.demo_state(), [gift.("mina", "flower"), gift.("mina", "tea")])

      assert character_state(state, "yuna").jealousy == 15

      {state, _outputs} =
        run!(Runtime.demo_state(), [
          Event.gift_received("user", "yuna", "ribbon"),
          gift.("mina", "flower")
        ])

      assert character_state(state, "yuna").jealousy == 0
    end

    test "gossip about a gift to the teller is told as their own good news" do
      state = put_in(Runtime.demo_state().characters["yuna"].traits, [:talkative])

      {_state, outputs} =
        run!(state, [Event.gift_received("user", "yuna", "ribbon"), tick(2)])

      assert [scene] =
               for(
                 %{kind: :gossip, character_id: "yuna"} = scene <-
                   of_type(outputs, :character_interaction),
                 do: scene
               )

      assert scene.text == "Yuna tells Haru about getting a ribbon from you."
      assert Ko.render(scene.context) == "Yuna는 Haru에게 네가 준 리본을 자랑한다."
    end
  end

  describe "speaking up" do
    test "a friend who saw the apology does not protest later, however it fades" do
      # Yuna cares about Haru, but has just written to someone, so she cannot
      # speak up in the same hour; the apology comes before she can.
      state =
        Runtime.demo_state()
        |> State.update_relationship("yuna", "haru", &%{&1 | affinity: 40})
        |> then(&%{&1 | cooldowns: Map.put(&1.cooldowns, "proactive:yuna", 0)})

      insult =
        Event.message_sent("user", "haru", "You're useless.",
          tone: :hostile,
          observed_by: ["yuna"]
        )

      apology =
        Event.apology_offered("user", "haru", "Sorry, that was cruel.", observed_by: ["yuna"])

      protests = fn outputs ->
        for %{reason: :protective} = o <- proactive(outputs, "yuna"), do: o
      end

      # Without the apology she speaks up once she can.
      {_state, outputs} = run!(state, [insult, tick(24)])
      assert [_] = protests.(outputs)

      # With it she never does, even after her memory of the apology fades
      # (sooner than her memory of the insult).
      {after_week, outputs} = run!(state, [insult, apology, tick(24), tick(72)])
      assert [] = protests.(outputs)

      assert Enum.any?(
               after_week.memories,
               &(&1.character_id == "yuna" and &1.data["event"] == "apology_offered" and
                   Aethrion.Memory.faded?(&1))
             )
    end

    test "tension does not stop a friend from speaking up" do
      state =
        Runtime.demo_state()
        |> State.update_relationship("haru", "user", &%{&1 | tension: 30})

      {_state, outputs} =
        run!(state, [
          Event.message_sent("user", "yuna", "Needy.", tone: :hostile, observed_by: ["haru"])
        ])

      assert [%{reason: :protective}] = proactive(outputs, "haru")
    end
  end

  test "Korean reports tell memories in Korean" do
    {:ok, scenario} =
      Aethrion.Scenario.load(
        Enum.find(Aethrion.Scenario.bundled(), &String.ends_with?(&1, "01_the_flower.json"))
      )

    {:ok, result} = Aethrion.Scenario.run(scenario)
    html = result |> Aethrion.Report.html(locale: :ko) |> IO.iodata_to_binary()

    assert html =~ ~s(<span class="memory-kind">직접</span>네가 Mina에게 꽃을 줬다.)
    refute html =~ ~s(</span>user gave mina a flower.)
  end

  describe "review findings" do
    test "being ignored is charged only to whoever was written to" do
      state =
        State.update_relationship(Runtime.demo_state(), "mina", "bob", &%{&1 | affinity: 39})

      {state, outputs} = run!(state, List.duplicate(tick(24), 12))

      # Ignored by the user, Mina turns to Bob; only Bob's own silence costs
      # affinity toward Bob, from her second message to him on.
      to_bob = for %{to: "bob"} = o <- proactive(outputs, "mina"), do: o.text
      assert [first | _] = to_bob
      refute first == "I guess you've been busy. I'll be here whenever you want to talk."

      assert State.get_relationship(state, "mina", "bob").affinity ==
               39 - 2 * (length(to_bob) - 1)
    end

    test "nobody writes while heading out, even when gossip is processed first" do
      state =
        put_in(Runtime.demo_state().characters["mina"].traits, [:talkative])
        |> State.update_relationship("mina", "haru", &%{&1 | trust: 40})

      {:ok, step} =
        Runtime.step(elem(run!(state, [Event.gift_received("user", "mina", "tea")]), 0), tick(24))

      outing =
        for %{kind: :together} = scene <- of_type(step.outputs, :character_interaction),
            id <- [scene.character_id, scene.to],
            do: id

      assert outing != []

      for id <- outing do
        assert [] = for(%{reason: :lonely} = o <- proactive(step.outputs, id), do: o)
      end
    end

    test "a reply gives the benefit of the doubt only when the rules do" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "haru", "Thanks!", tone: :warm),
          Event.message_sent("user", "haru", "You're great.", tone: :warm),
          tick(240),
          Event.message_sent("user", "haru", "Useless.", tone: :hostile)
        ])

      refute List.last(replies(outputs, "haru")).text ==
               "That's not like you. Is something wrong?"
    end

    test "gift and apology replies tell a model what happened, and count repeats" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.gift_received("user", "haru", "tea"),
          Event.apology_offered("user", "haru", "Sorry."),
          Event.apology_offered("user", "haru", "Sorry again.")
        ])

      [gift, _first, second] = replies(outputs, "haru")

      assert Aethrion.Expression.Prompt.render_context(gift.context) =~
               ~s(Listener just gave the speaker: "tea")

      assert Aethrion.Expression.Prompt.render_context(second.context) =~
               ~s(Listener just apologized: "Sorry again.")

      assert second.context.repeats == 2
    end

    test "only someone who felt left out by the giver is reassured, and only once since" do
      watched = Event.gift_received("user", "mina", "flower", observed_by: ["haru"])

      # Haru saw it but never felt left out (not close enough to the user).
      {_state, outputs} =
        run!(Runtime.demo_state(), [watched, Event.gift_received("user", "haru", "tea")])

      assert [%{text: "Thank you for the tea!"}] = replies(outputs, "haru")

      # Yuna got a scarf, later saw a ring go to Mina, then got a cake.
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.gift_received("user", "yuna", "scarf"),
          tick(30),
          Event.gift_received("user", "mina", "ring", observed_by: ["yuna"]),
          Event.gift_received("user", "yuna", "cake"),
          Event.gift_received("user", "yuna", "card")
        ])

      assert [_scarf, %{context: %{reason: :reassurance}} = cake, card] = replies(outputs, "yuna")
      assert cake.text == "For me? ...I thought you'd forgotten about me."
      refute card.context.reason == :reassurance
    end

    test "players' names are kept as given, and saved alike" do
      state = State.new(people: [alex: "Alex"])
      assert State.name(state, "alex") == "Alex"

      {:ok, loaded} =
        state |> State.to_data() |> Jason.encode!() |> Jason.decode!() |> State.parse()

      assert loaded == state

      assert {:error, %{code: :invalid_state}} = State.parse(%{"people" => %{"sam" => ""}})
    end

    test "outings group by what they were, even without event ids" do
      scene = fn from, to ->
        %{
          type: :character_interaction,
          kind: :together,
          character_id: from,
          to: to,
          text: "together"
        }
      end

      gossip = %{
        type: :character_interaction,
        kind: :gossip,
        character_id: "mina",
        to: "haru",
        text: "a secret"
      }

      texts =
        [scene.("haru", "yuna"), gossip, scene.("haru", "yuna")]
        |> Aethrion.Digest.of(Runtime.demo_state())
        |> Enum.map(& &1.text)

      assert texts == ["Haru and Yuna spent time together twice.", "A secret"]
    end

    test "a model prompt says what the rules weighed" do
      hostile = &Event.message_sent("user", "mina", "Go away #{&1}", tone: :hostile)
      {_state, outputs} = run!(Runtime.demo_state(), [hostile.(1), hostile.(2)])
      [_first, second] = replies(outputs, "mina")

      assert Aethrion.Expression.Prompt.render_context(second.context) =~
               "History: The listener has done this 2 times recently (this one included). " <>
                 "The speaker takes it at full weight."
    end

    test "a host-built gift request without an item still renders" do
      request = %Aethrion.Expression.Request{
        kind: :reply,
        reason: :reply,
        tone: :gift,
        speaker: %{id: "mina", name: "Mina", traits: [], mood: :neutral},
        listener: %{id: "user", name: "you"},
        relationship: %{affinity: 0, trust: 0, tension: 0, bond: :neutral}
      }

      assert Aethrion.Expression.Templates.render(request) == "Thank you, I love it!"
      assert Ko.render(request) == "나 주는 거야? 고마워!"
    end
  end

  describe "several players" do
    defp village do
      State.new(
        people: %{"player:alex" => "Alex", "player:sam" => "Sam"},
        characters: [
          %Aethrion.Character{id: "mara", name: "Mara"},
          %Aethrion.Character{id: "tomas", name: "Tomas", traits: [:talkative]},
          %Aethrion.Character{id: "elin", name: "Elin"}
        ],
        relationships: [
          %Aethrion.Relationship{from: "tomas", to: "mara", affinity: 40, trust: 40},
          %Aethrion.Relationship{from: "elin", to: "mara", affinity: 40, trust: 40},
          %Aethrion.Relationship{from: "tomas", to: "elin", affinity: 30, trust: 40},
          %Aethrion.Relationship{from: "mara", to: "player:alex", affinity: 30, trust: 20},
          %Aethrion.Relationship{from: "mara", to: "player:sam", affinity: 30, trust: 20},
          %Aethrion.Relationship{from: "tomas", to: "player:alex", affinity: 30, trust: 20},
          %Aethrion.Relationship{from: "elin", to: "player:alex", affinity: 30, trust: 20},
          %Aethrion.Relationship{from: "elin", to: "player:sam", affinity: 30, trust: 20}
        ]
      )
    end

    test "players are named, and each digest keeps to its own player" do
      {state, outputs} =
        run!(village(), [
          Event.message_sent("player:alex", "mara", "Get lost.",
            tone: :hostile,
            observed_by: ["tomas", "elin"]
          ),
          Event.message_sent("player:sam", "elin", "Morning!", tone: :warm),
          tick(6)
        ])

      texts = Enum.map(Aethrion.Digest.of(outputs, state, you: "player:sam"), & &1.text)
      assert Enum.any?(texts, &(&1 =~ "Alex"))
      refute Enum.any?(texts, &(&1 =~ "player:"))

      mine =
        outputs
        |> Aethrion.Digest.of(state, you: "player:sam", only_you: true)
        |> Enum.map(& &1.text)

      refute Enum.any?(mine, &(&1 =~ "spoke up to Alex"))
      assert Enum.any?(texts, &(&1 =~ "spoke up to Alex"))
    end

    test "another player's digest names the user instead of calling them you" do
      state =
        State.new(
          people: %{"user" => "Jo", "player:sam" => "Sam"},
          characters: [
            %Aethrion.Character{id: "mara", name: "Mara"},
            %Aethrion.Character{id: "tomas", name: "Tomas", traits: [:talkative]},
            %Aethrion.Character{id: "elin", name: "Elin"}
          ],
          relationships: [
            %Aethrion.Relationship{from: "tomas", to: "mara", affinity: 40, trust: 40},
            %Aethrion.Relationship{from: "tomas", to: "elin", affinity: 30, trust: 40},
            %Aethrion.Relationship{from: "tomas", to: "user", affinity: 30, trust: 20}
          ]
        )

      {state, outputs} =
        run!(state, [
          Event.message_sent("user", "mara", "Get lost.", tone: :hostile, observed_by: ["tomas"]),
          tick(6)
        ])

      told = fn opts ->
        outputs
        |> Aethrion.Digest.of(state, opts)
        |> Enum.map(& &1.text)
        |> Enum.find(&(&1 =~ "Get lost"))
      end

      assert told.(you: "user") =~ "what you said to Mara"
      assert told.(you: "player:sam") =~ "what Jo said to Mara"
      assert told.(you: "player:sam", locale: :ko) =~ "Jo가 Mara한테"
    end

    test "another player's own digest leaves out news about what the user did" do
      {state, outputs} = run!(Runtime.demo_state(), [flower_for_mina(), tick(2)])

      everything = Enum.map(Aethrion.Digest.of(outputs, state, you: "player:sam"), & &1.text)
      assert Enum.any?(everything, &(&1 =~ "Yuna tells Haru"))

      mine =
        outputs
        |> Aethrion.Digest.of(state, you: "player:sam", only_you: true)
        |> Enum.map(& &1.text)

      refute Enum.any?(mine, &(&1 =~ "Yuna tells Haru"))
    end

    test "a quoted line stays said to whoever heard it, whoever reads the digest" do
      {state, outputs} = run!(Runtime.demo_state(), [flower_for_mina(), tick(2)])

      told =
        outputs
        |> Aethrion.Digest.of(state, you: "yuna", locale: :ko)
        |> Enum.map(& &1.text)
        |> Enum.find(&(&1 =~ "제법인데"))

      assert told =~ "\"Yuna한테 들었어."
      refute told =~ "너한테 들었어"
    end

    test "witnesses who speak up about the same thing use different words" do
      {_state, outputs} =
        run!(village(), [
          Event.message_sent("player:alex", "mara", "Get lost.",
            tone: :hostile,
            observed_by: ["tomas", "elin"]
          )
        ])

      lines =
        for %{reason: :protective, text: text} <- of_type(outputs, :proactive_message), do: text

      assert length(lines) == 2
      assert length(Enum.uniq(lines)) == 2
    end

    test "harsh words apologized for in front of the teller are not passed on" do
      {_state, outputs} =
        run!(village(), [
          Event.message_sent("player:alex", "mara", "Get lost.",
            tone: :hostile,
            observed_by: ["tomas"]
          ),
          Event.apology_offered("player:alex", "mara", "I'm sorry.", observed_by: ["tomas"]),
          tick(6)
        ])

      refute Enum.any?(
               of_type(outputs, :character_interaction),
               &(&1.kind == :gossip and &1.text =~ "Get lost.")
             )
    end

    test "a month of the same kind words keeps finding new ones" do
      events =
        for _day <- 1..30,
            event <- [
              Event.message_sent("player:alex", "mara", "Morning!", tone: :warm),
              tick(24)
            ],
            do: event

      {_state, outputs} = run!(village(), events)
      texts = for o <- replies(outputs, "mara"), do: o.text
      {_line, most} = texts |> Enum.frequencies() |> Enum.max_by(&elem(&1, 1))
      assert most <= 12
    end
  end

  describe "all together" do
    test "coming back after days away and then talking daily lifts loneliness" do
      morning = Event.message_sent("user", "mina", "morning!", tone: :warm)
      events = [tick(72)] ++ Enum.flat_map(1..6, fn _day -> [morning, tick(24)] end)

      {state, outputs} = run!(Runtime.demo_state(), events)

      assert character_state(state, "mina").mood != :lonely
      quotes = for %{text: "I keep thinking" <> _} <- proactive(outputs, "mina"), do: 1
      assert length(quotes) <= 1
    end

    test "no lonely message right after being brushed off" do
      # Mina wrote and got no reply; a day later the user brushes her off.
      {state, _outputs} = run!(Runtime.demo_state(), [tick(48), tick(26)])

      {:ok, step} =
        Runtime.step(state, Event.message_sent("user", "mina", "stop bothering me", tone: :cold))

      assert [] = proactive(step.outputs, "mina")

      {_state, outputs} = run!(step.state, List.duplicate(tick(1), 12))
      assert [] = proactive(outputs, "mina")
    end

    test "the relief of a kind word after days away follows tuning" do
      state =
        Runtime.demo_state()
        |> Aethrion.Tuning.put(:message, :warm_loneliness, 0)

      {state, _outputs} = run!(state, [tick(72)])
      before = character_state(state, "mina").loneliness

      {state, _outputs} = run!(state, [Event.message_sent("user", "mina", "hi!", tone: :warm)])
      assert character_state(state, "mina").loneliness == before
    end

    test "a week of cold words is noticed, and an apology after it is not waved off" do
      cold = Event.message_sent("user", "yuna", "k.", tone: :cold)
      week = Enum.flat_map(1..5, fn _day -> [cold, tick(24)] end)

      {state, outputs} = run!(Runtime.demo_state(), week)

      assert "You've been short with me lately." in for(o <- replies(outputs, "yuna"), do: o.text)

      {_state, outputs} =
        run!(state, [Event.apology_offered("user", "yuna", "Sorry, I've been cold.")])

      refute List.last(replies(outputs, "yuna")).text ==
               "You don't have to apologize. We're okay."
    end

    test "hearing about an apology is good news, not a question" do
      state =
        State.update_relationship(Runtime.demo_state(), "yuna", "user", &%{&1 | affinity: 40})

      {state, _outputs} =
        run!(state, [
          Event.message_sent("user", "haru", "Useless.", tone: :hostile),
          Event.apology_offered("user", "haru", "Sorry, that was cruel.")
        ])

      {_state, outputs} =
        run!(state, [Event.gossip_shared("haru", "yuna", "memory:haru:apology:e2")])

      assert [%{reason: :curious, text: "Haru told me you apologized. That was good of you."}] =
               proactive(outputs, "yuna")
    end

    test "a player reads their own digest as \"you\"" do
      state =
        State.new(
          people: %{"alex" => "Alex"},
          characters: [
            %Aethrion.Character{id: "mina", name: "Mina"},
            %Aethrion.Character{id: "yuna", name: "Yuna", traits: [:talkative]},
            %Aethrion.Character{id: "haru", name: "Haru"}
          ],
          relationships: [
            %Aethrion.Relationship{from: "yuna", to: "haru", affinity: 30, trust: 40},
            %Aethrion.Relationship{from: "yuna", to: "alex", affinity: 40, trust: 20}
          ]
        )

      {state, outputs} =
        run!(state, [Event.gift_received("alex", "mina", "ring", observed_by: ["yuna"]), tick(2)])

      texts = Enum.map(Aethrion.Digest.of(outputs, state, you: "alex"), & &1.text)
      assert "Yuna tells Haru about the ring you gave Mina." in texts

      ko = Enum.map(Aethrion.Digest.of(outputs, state, you: "alex", locale: :ko), & &1.text)
      assert Enum.any?(ko, &(&1 =~ "네가 Mina한테 준 반지 얘기를 전했다."))
    end
  end

  test "a reply sees the bond the world records, even on a relationship's first change" do
    state =
      State.update_relationship(
        Runtime.demo_state(),
        "mina",
        "user",
        &%{&1 | affinity: 50, trust: 30}
      )

    {:ok, step} = Runtime.step(state, Event.message_sent("user", "mina", "k.", tone: :cold))

    recorded = State.get_relationship(step.state, "mina", "user")
    assert [%{context: %{relationship: %{bond: bond}}}] = replies(step.outputs, "mina")
    assert bond == recorded.bond
    assert bond == Bond.derive(recorded, step.state)
  end

  describe "extreme tuning" do
    test "a wide hysteresis still lets a grudge heal" do
      state = Aethrion.Tuning.put(Runtime.demo_state(), :bond, :hysteresis, 20)
      hostile = Event.message_sent("user", "yuna", "Go away.", tone: :hostile)

      amends =
        Enum.flat_map(1..15, fn day ->
          [
            Event.gift_received("user", "yuna", "gift #{day}"),
            Event.message_sent("user", "yuna", "Thinking of you.", tone: :warm),
            Event.apology_offered("user", "yuna", "Sorry."),
            tick(24)
          ]
        end)

      {state, _outputs} = run!(state, [hostile, hostile, hostile, hostile] ++ amends)

      refute Bond.derive(State.get_relationship(state, "yuna", "user"), state) in [
               :strained,
               :estranged
             ]
    end

    test "settled_tension 0 turns the check off instead of freezing bonds" do
      state = Aethrion.Tuning.put(Runtime.demo_state(), :bond, :settled_tension, 0)

      warm = Event.message_sent("user", "haru", "Thanks!", tone: :warm)
      {_state, outputs} = run!(state, List.duplicate(warm, 8))
      assert [_ | _] = of_type(outputs, :bond_changed)
    end

    test "no tuning makes a character write more than once an hour" do
      state =
        Enum.reduce(
          [
            cooldown_hours: 0,
            min_gap_hours: 0,
            unanswered_hours: 0,
            alone_hours: 0,
            loneliness_threshold: 0
          ],
          Runtime.demo_state(),
          fn {key, value}, state -> Aethrion.Tuning.put(state, :proactive, key, value) end
        )

      events = for i <- 1..6, do: Event.message_sent("user", "haru", "hey #{i}", tone: :neutral)
      {_state, outputs} = run!(state, [tick(1) | events])

      assert length(proactive(outputs, "mina")) <= 1
    end
  end

  test "misspelled expectations are errors, not silent passes" do
    for expectation <- [
          %{"output" => "proactive_mesage", "count" => 0},
          %{"output" => "reply", "speaker" => "mina", "count" => 0},
          %{"memory" => %{"knd" => "experienced"}, "count" => 0},
          %{"output" => "bond_changed", "after" => "estrangd", "count" => 0}
        ] do
      assert {:error, %{code: :invalid_scenario, message: message}} =
               Aethrion.Scenario.from_data(%{"name" => "typo", "expect" => [expectation]})

      assert message =~ ~r/unknown|is not a/
    end
  end

  describe "the LLM boundary" do
    defmodule Chatty do
      @behaviour Aethrion.LLM.Adapter
      def render(_request, opts), do: {:ok, Keyword.fetch!(opts, :say)}
      def interpret(_request, _opts), do: {:error, :unsupported}
    end

    test "silence stays silent, lines stay one line, and rambling falls back" do
      hostile = &Event.message_sent("user", "mina", "Go away #{&1}", tone: :hostile)
      {_state, outputs} = run!(Runtime.demo_state(), Enum.map(1..4, hostile))
      silent = List.last(replies(outputs, "mina"))
      assert silent.text == "..."

      render = fn output, say ->
        Aethrion.Expression.render_output(output, adapter: Chatty, adapter_opts: [say: say])
      end

      assert %{text: "...", expression: %{reason: :silence}} = render.(silent, "I am so upset!")

      [first | _] = replies(outputs, "mina")

      assert %{text: "Hello, there.", expression: %{status: :ok}} =
               render.(first, ~s("Hello,\nthere."))

      assert %{expression: %{reason: :too_long}} = render.(first, String.duplicate("word ", 200))
    end

    test "prompts say how long it has been and how old each memory is" do
      {_state, outputs} = run!(Runtime.demo_state(), [tick(24)])
      [message | _] = proactive(outputs, "mina")
      prompt = Aethrion.Expression.Prompt.render_context(message.context)

      assert prompt =~
               "The listener has not talked to the speaker in the 24 hours this world has run."
    end

    test "news of kindness travels as kindness" do
      {state, _outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "yuna", "You did great.", tone: :warm)
        ])

      {_state, outputs} =
        run!(state, [Event.gossip_shared("yuna", "haru", "memory:yuna:message:e1")])

      assert [%{kind: :gossip, text: "Yuna tells Haru how kind you were to Yuna."} = scene] =
               of_type(outputs, :character_interaction)

      assert Ko.render(scene.context) == "Yuna는 Haru에게 네가 자기한테 다정하게 대해 줬다고 전한다."
    end

    test "unnamed player ids read as names, but never as someone else's" do
      assert State.name(Runtime.demo_state(), "player:alex") == "Alex"
      assert State.name(Runtime.demo_state(), "sam") == "sam"
      assert State.name(Runtime.demo_state(), "player:alex:2") == "Alex:2"
      # "npc:mina" would read as the character Mina.
      assert State.name(Runtime.demo_state(), "npc:mina") == "npc:mina"
    end

    test "a line of nothing but quotes falls back" do
      {_state, outputs} =
        run!(Runtime.demo_state(), [Event.message_sent("user", "mina", "hi", tone: :warm)])

      [reply] = replies(outputs, "mina")

      assert %{expression: %{status: :fallback, reason: :empty_response}} =
               Aethrion.Expression.render_output(reply,
                 adapter: Chatty,
                 adapter_opts: [say: ~s("""")]
               )
    end

    test "hearing that someone was comforted is kind news too" do
      {state, _outputs} =
        run!(Runtime.demo_state(), [Event.comfort_offered("user", "yuna")])

      {_state, outputs} =
        run!(state, [Event.gossip_shared("yuna", "haru", "memory:yuna:comfort:e1")])

      assert [%{reason: :curious} = message] = proactive(outputs, "haru")
      assert message.text == "Yuna told me you were there for them. That was kind of you."
      assert Ko.render(message.context) == "Yuna한테 들었어. 걔 곁에 있어 줬다며? 고마워."
    end
  end

  test "a digest tells what a belief holds now, not when it first formed" do
    warm = Event.message_sent("user", "mina", "Morning!", tone: :warm)

    {state, outputs} =
      run!(Runtime.demo_state(), Enum.flat_map(1..14, fn _ -> [warm, tick(24)] end))

    count =
      Enum.find_value(state.memories, fn
        %{kind: :impression, data: %{"pattern" => "warm", "from" => "user"}} = memory
        when memory.character_id == "mina" ->
          memory.data["count"]

        _other ->
          nil
      end)

    assert count > 2

    assert Enum.any?(
             Aethrion.Digest.of(outputs, state),
             &(&1.text == "Mina remembers you being warm #{count} times.")
           )
  end

  defp tick(hours), do: Event.time_tick("t", hours: hours)
end
