defmodule Aethrion.BondTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Relationship, Runtime, State, Tuning}
  alias Aethrion.Rules.Bond

  defp rel(values), do: struct(Relationship, [from: "a", to: "b"] ++ values)

  test "bonds follow the documented priority" do
    assert Bond.derive(rel([])) == :neutral
    assert Bond.derive(rel(affinity: 25, trust: 15)) == :friendly
    assert Bond.derive(rel(affinity: 50, trust: 30)) == :close
    assert Bond.derive(rel(affinity: 50, trust: 29)) == :friendly
    assert Bond.derive(rel(affinity: 50, trust: 30, tension: 20)) == :strained
    assert Bond.derive(rel(affinity: 60, trust: -10)) == :strained
    assert Bond.derive(rel(affinity: 80, trust: 80, tension: 50)) == :estranged
    assert Bond.derive(rel(affinity: -30)) == :estranged
  end

  test "changes are announced once, with a note and a log line" do
    {:ok, step} =
      Runtime.step(
        Runtime.demo_state(),
        Event.message_sent("user", "mina", "go away", tone: :hostile)
      )

    {:ok, step} =
      Runtime.step(step.state, Event.message_sent("user", "mina", "I said go", tone: :hostile))

    assert [
             %{
               type: :bond_changed,
               from: "mina",
               to: "user",
               before: :friendly,
               after: :strained,
               rule: :bond
             }
           ] =
             of_type(step.outputs, :bond_changed)

    assert "[Bond] Mina toward user: friendly -> strained" in step.log

    assert [%{rule: :bond, before: :friendly, after: :strained, event_id: "e2"}] =
             Aethrion.Explain.relationship([step], "mina", "user", :bond)

    assert {:ok, {:why, {"mina", "user"}, :bond}} =
             Aethrion.CLI.CommandParser.parse("why mina->user bond")
  end

  test "untouched relationships never announce, even if their bond is stale" do
    state =
      State.new(
        characters: [character("mina")],
        relationships: [relationship("mina", "user", affinity: 90, trust: 90)]
      )

    {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 1))
    assert of_type(step.outputs, :bond_changed) == []
  end

  test "thresholds are tunable" do
    state =
      Runtime.demo_state()
      |> Tuning.put(:bond, :close_affinity, 45)
      |> Tuning.put(:bond, :close_trust, 20)

    {:ok, step} = Runtime.step(state, Event.gift_received("user", "mina", "flower"))

    assert [%{before: :friendly, after: :close}] =
             step.outputs |> of_type(:bond_changed) |> Enum.filter(&(&1.from == "mina"))
  end

  test "requests and prompts carry the bond" do
    request =
      Aethrion.Expression.build_request(Runtime.demo_state(), :proactive_message, "mina", "user",
        reason: :lonely
      )

    assert request.relationship.bond == :friendly
    {_system, context} = Aethrion.Expression.Prompt.render_parts(request)
    assert context =~ "Speaker toward listener: friendly; affinity 40"
  end

  test "scenarios can expect bonds and bond changes" do
    data = %{
      "events" => [
        %{
          "type" => "message_sent",
          "from" => "user",
          "to" => "mina",
          "text" => "a",
          "tone" => "hostile"
        },
        %{
          "type" => "message_sent",
          "from" => "user",
          "to" => "mina",
          "text" => "b",
          "tone" => "hostile"
        }
      ],
      "expect" => [
        %{"relationship" => ["mina", "user"], "field" => "bond", "equals" => "strained"},
        %{"output" => "bond_changed", "from" => "mina", "after" => "strained", "count" => 1}
      ]
    }

    {:ok, scenario} = Aethrion.Scenario.from_data(data)
    {:ok, result} = Aethrion.Scenario.run(scenario)
    assert Aethrion.Scenario.passed?(result)
  end

  describe "replies" do
    defp reply_for(values, tone) do
      state =
        State.new(
          characters: [character("haru")],
          relationships: [relationship("haru", "user", values)]
        )

      {:ok, step} = Runtime.step(state, Event.message_sent("user", "haru", "hi", tone: tone))
      [reply] = of_type(step.outputs, :reply)
      {reply.text, Aethrion.Expression.Templates.Ko.render(reply.context)}
    end

    test "when the mood has nothing to say, the bond does" do
      assert reply_for([affinity: 60, trust: 40], :warm) ==
               {"You always know how to make my day.", "역시 너밖에 없어. 고마워."}

      assert reply_for([affinity: 30, trust: 20, tension: 25], :warm) ==
               {"...Thanks, I guess.", "...그래, 고마워."}

      assert reply_for([tension: 60], :neutral) ==
               {"I don't really want to talk.", "별로 얘기하고 싶지 않아."}

      assert reply_for([affinity: 30, trust: 20], :warm) == {"That's sweet of you.", "다정하네."}
    end

    test "a mood still speaks first" do
      state =
        State.new(
          characters: [character("haru", state: [loneliness: 80])],
          relationships: [relationship("haru", "user", affinity: 60, trust: 40)]
        )

      {:ok, step} = Runtime.step(state, Event.message_sent("user", "haru", "hi", tone: :warm))
      assert [%{text: "I really needed to hear that today."}] = of_type(step.outputs, :reply)
    end
  end
end
