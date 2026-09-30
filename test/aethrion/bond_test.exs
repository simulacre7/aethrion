defmodule Aethrion.BondTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Relationship, Runtime, State, Tuning}
  alias Aethrion.Rules.Bond

  defp rel(values), do: struct(Relationship, [from: "a", to: "b"] ++ values)

  test "bonds follow the documented priority" do
    assert Bond.derive(rel([])) == :neutral
    assert Bond.derive(rel(affinity: 25, trust: 15)) == :friendly
    assert Bond.derive(rel(affinity: 60, trust: 50)) == :close
    assert Bond.derive(rel(affinity: 60, trust: 50, tension: 20)) == :strained
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
end
