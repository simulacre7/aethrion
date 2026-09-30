defmodule Aethrion.ScenarioTest do
  use ExUnit.Case, async: true

  alias Aethrion.Scenario

  test "Aethrion ships scenarios" do
    assert length(Scenario.bundled()) >= 5
  end

  for path <- Path.wildcard(Path.expand("../../priv/scenarios/*.json", __DIR__)) do
    @path path
    test "bundled scenario #{Path.basename(path)} meets its expectations" do
      assert {:ok, scenario} = Scenario.load(@path)
      assert {:ok, result} = Scenario.run(scenario)

      failures =
        for check <- result.checks, not check.passed?, do: {check.description, check.actual}

      assert failures == []
      assert result.checks != []
    end
  end

  test "custom worlds, expectations, and failures" do
    data = %{
      "name" => "Tiny",
      "world" => %{
        "characters" => [%{"id" => "a", "name" => "A"}, %{"id" => "b", "name" => "B"}],
        "relationships" => [%{"from" => "a", "to" => "b", "trust" => 10}]
      },
      "events" => [
        %{"type" => "message_sent", "from" => "b", "to" => "a", "text" => "hi", "tone" => "warm"}
      ],
      "expect" => [
        %{"relationship" => ["a", "b"], "field" => "trust", "equals" => 12},
        %{"character" => "a", "field" => "joy", "at_least" => 8},
        %{"character" => "a", "field" => "active", "equals" => true},
        %{"output" => "reply"},
        %{"character" => "a", "field" => "mood", "equals" => "happy"}
      ]
    }

    assert {:ok, scenario} = Scenario.from_data(data)
    assert {:ok, result} = Scenario.run(scenario)

    assert [true, true, true, false, false] = Enum.map(result.checks, & &1.passed?)
    refute Scenario.passed?(result)

    assert Enum.map(result.checks, & &1.description) == [
             "a->b.trust == 12",
             "a.joy >= 8",
             "a.active == true",
             "reply count >= 1",
             "a.mood == happy"
           ]
  end

  test "invalid events stop the run with their index" do
    data = %{
      "events" => [%{"type" => "time_tick", "hours" => 1}, %{"type" => "time_tick", "hours" => 0}]
    }

    assert {:ok, scenario} = Scenario.from_data(data)
    assert {:error, {1, %{code: :invalid_event}}} = Scenario.run(scenario)
  end

  test "malformed scenarios are rejected" do
    assert {:error, {:invalid_event, 0, {:unsupported_event, "dance"}}} =
             Scenario.from_data(%{"events" => [%{"type" => "dance"}]})

    assert {:error, {:invalid_expectation, %{"nope" => 1}}} =
             Scenario.from_data(%{"expect" => [%{"nope" => 1}]})

    assert {:error, {:invalid_world, "mars"}} = Scenario.from_data(%{"world" => "mars"})
    assert {:error, :enoent} = Scenario.load("/nonexistent.json")
  end

  test "recorded sessions replay as passing scenarios" do
    alias Aethrion.{Event, Runtime}

    events = [
      Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "t1"),
      Event.message_sent("user", "haru", "thanks for being around", tone: :warm, at: "t2"),
      Event.time_tick("t3", hours: 2)
    ]

    {:ok, final, steps} = Runtime.run(Runtime.demo_state(), events)
    outputs = Enum.flat_map(steps, & &1.outputs)

    data =
      "demo"
      |> Scenario.record(Enum.map(steps, & &1.event), final, outputs, name: "Replay me")
      |> Jason.encode!()
      |> Jason.decode!()

    assert data["name"] == "Replay me"
    refute Enum.any?(data["events"], &Map.has_key?(&1, "id"))

    assert %{"character" => "yuna", "field" => "mood"} =
             Enum.find(data["expect"], &(&1["character"] == "yuna"))

    assert {:ok, scenario} = Scenario.from_data(data)
    assert {:ok, result} = Scenario.run(scenario)
    assert Scenario.passed?(result)
    assert result.state == final
  end

  test "sessions that started from a loaded world record that world" do
    alias Aethrion.{Event, Runtime}

    {:ok, origin, _steps} =
      Runtime.run(Runtime.demo_state(), [Event.gift_received("user", "mina", "flower")])

    {:ok, final, steps} = Runtime.run(origin, [Event.time_tick("t", hours: 1)])

    data =
      Scenario.record(
        origin,
        Enum.map(steps, & &1.event),
        final,
        Enum.flat_map(steps, & &1.outputs)
      )
      |> Jason.encode!()
      |> Jason.decode!()

    assert {:ok, scenario} = Scenario.from_data(data)
    assert {:ok, result} = Scenario.run(scenario)
    assert Scenario.passed?(result)
    assert result.state == final
  end

  describe "branches" do
    defp branching(branches) do
      {:ok, scenario} =
        Scenario.from_data(%{
          "events" => [
            %{
              "type" => "gift_received",
              "from" => "user",
              "to" => "mina",
              "item" => "flower",
              "observed_by" => ["yuna"]
            }
          ],
          "branches" => branches
        })

      scenario
    end

    test "every branch starts from the shared state and is checked on its own outputs" do
      scenario =
        branching([
          %{
            "name" => "ignore",
            "events" => [%{"type" => "time_tick", "hours" => 2}],
            "expect" => [%{"output" => "proactive_message", "character" => "yuna", "count" => 1}]
          },
          %{
            "name" => "apologize",
            "events" => [
              %{
                "type" => "apology_offered",
                "from" => "user",
                "to" => "yuna",
                "reason" => "sorry"
              },
              %{"type" => "time_tick", "hours" => 2}
            ],
            "expect" => [%{"output" => "proactive_message", "count" => 0}]
          }
        ])

      assert {:ok, result} = Scenario.run(scenario)
      assert [%{name: "ignore"} = ignore, %{name: "apologize"} = apologize] = result.branches
      assert Scenario.passed?(result)

      # Branches do not see each other's events, and both continue from e1.
      assert [%{event: %{id: "e2"}}] = ignore.steps
      assert [%{event: %{id: "e2"}}, %{event: %{id: "e3"}}] = apologize.steps
      assert result.state.clock == 0
      assert ignore.state.clock == 2

      assert ["ignore", "apologize"] = Enum.map(Scenario.all_checks(result), & &1.branch)
      assert Aethrion.Report.html(result) =~ "<h2>Branches</h2>"
    end

    test "a failing branch expectation fails the scenario" do
      scenario =
        branching([
          %{
            "name" => "wrong",
            "events" => [%{"type" => "time_tick", "hours" => 1}],
            "expect" => [%{"clock" => 99}]
          }
        ])

      assert {:ok, result} = Scenario.run(scenario)
      refute Scenario.passed?(result)
    end

    test "invalid branch events and definitions are reported" do
      scenario =
        branching([%{"name" => "bad", "events" => [%{"type" => "time_tick", "hours" => 0}]}])

      assert {:error, {{"bad", 0}, %{code: :invalid_event}}} = Scenario.run(scenario)

      assert {:error, {:invalid_branch, 0, :not_an_object}} =
               Scenario.from_data(%{"branches" => ["x"]})

      assert {:error, {:invalid_branch, 0, {:invalid_event, 0, _}}} =
               Scenario.from_data(%{"branches" => [%{"events" => [%{"type" => "dance"}]}]})
    end
  end
end
