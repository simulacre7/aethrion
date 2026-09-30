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

    test "an unanswered lonely message is followed by three days of silence" do
      {_state, outputs} = run!(Runtime.demo_state(), List.duplicate(tick(24), 7))

      sent = for %{type: :proactive_message, character_id: "mina"} = o <- outputs, do: o.event_id
      # Days 1 and 4 and 7: 72 hours apart once unanswered.
      assert length(sent) == 3
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
    test "each remembered apology halves what the next repairs" do
      insult = Event.message_sent("user", "mina", "Go away.", tone: :hostile)
      sorry = Event.apology_offered("user", "mina", "Sorry.")

      trust = fn state -> State.get_relationship(state, "mina", "user").trust end

      {state, _} = run!(Runtime.demo_state(), [insult])
      {after_one, _} = run!(state, [sorry])
      {state, _} = run!(after_one, [insult])
      {after_two, _} = run!(state, [sorry])

      assert trust.(after_one) == 25 - 6 + 8
      assert trust.(after_two) == trust.(after_one) - 6 + 4
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

      assert Ko.render(reply.context) == "고마워. 나도 챙겨 줬으면 했을 뿐이야."
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
      {_state, outputs} =
        run!(Runtime.demo_state(), [
          Event.message_sent("user", "yuna", "You're so needy.", tone: :hostile),
          tick(24),
          tick(24)
        ])

      assert [] = for(%{to: "user"} = o <- proactive(outputs, "yuna"), do: o)
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
      state =
        Runtime.demo_state()
        |> State.update_relationship("haru", "user", &%{&1 | affinity: 40})
        |> State.update_relationship("haru", "yuna", &%{&1 | trust: 50})

      {_state, outputs} =
        run!(state, [
          Event.message_sent("user", "mina", "Not now.", tone: :hostile, observed_by: ["yuna"]),
          tick(3)
        ])

      for %{reason: :curious} = message <- proactive(outputs, "haru") do
        assert Ko.render(message.context) =~ "네가 Mina한테 그런 말 했다며?"
      end
    end
  end

  defp tick(hours), do: Event.time_tick("t", hours: hours)
end
