defmodule Aethrion.CustomEventsTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Event, Journal, Pipeline, Runtime, RuntimeServer, Scenario, Transition}

  defmodule Tip do
    use Aethrion.Rule,
      id: :tip_test,
      description: "A tip lifts the receiver's joy.",
      params: [joy: 12]

    @impl true
    def apply(%Transition{event: event} = transition) do
      Transition.adjust_character(
        transition,
        event.to,
        :joy,
        Transition.param(transition, :joy) * event.amount
      )
    end
  end

  setup do
    %{pipeline: Pipeline.append(Pipeline.default(), :tip_left_test, Tip)}
  end

  test "custom events are read from JSON only with a pipeline that registers them", %{
    pipeline: pipeline
  } do
    data = %{
      "type" => "tip_left_test",
      "from" => "user",
      "to" => "mina",
      "amount" => 2,
      "unknown_field_xyz_123" => 1
    }

    assert {:error, {:unsupported_event, "tip_left_test"}} = Event.from_data(data)

    assert {:ok, %{type: :tip_left_test, from: "user", to: "mina", amount: 2} = event} =
             Event.from_data(data, pipeline: pipeline)

    refute Enum.any?(Map.keys(event), &is_binary/1)
  end

  test "scenarios can use custom events", %{pipeline: pipeline} do
    data = %{
      "events" => [%{"type" => "tip_left_test", "from" => "user", "to" => "mina", "amount" => 2}],
      "expect" => [%{"character" => "mina", "field" => "joy", "equals" => 24}]
    }

    assert {:error, {:invalid_event, 0, {:unsupported_event, "tip_left_test"}}} =
             Scenario.from_data(data)

    assert {:ok, scenario} = Scenario.from_data(data, pipeline: pipeline)
    assert {:ok, result} = Scenario.run(scenario, pipeline: pipeline)
    assert Scenario.passed?(result)
  end

  test "journals replay custom events with the same pipeline", %{pipeline: pipeline} do
    path =
      Path.join(
        System.tmp_dir!(),
        "aethrion-custom-journal-#{System.unique_integer([:positive])}.jsonl"
      )

    on_exit(fn -> File.rm(path) end)

    {:ok, server} = RuntimeServer.start_link(journal: path, pipeline: pipeline)

    {:ok, state, _outputs, _log} =
      RuntimeServer.dispatch(server, %{type: :tip_left_test, from: "user", to: "mina", amount: 1})

    GenServer.stop(server)

    assert {:error, {:invalid_journal, 2, {:unsupported_event, "tip_left_test"}}} =
             Journal.replay(path)

    assert {:ok, ^state, _steps} = Journal.replay(path, pipeline: pipeline)

    {:ok, restarted} = RuntimeServer.start_link(journal: path, pipeline: pipeline)
    assert RuntimeServer.get_state(restarted) == state
    GenServer.stop(restarted)
  end

  test "built-in events are unaffected by the pipeline option", %{pipeline: pipeline} do
    event = Event.time_tick("t", hours: 2)
    assert {:ok, ^event} = event |> Event.to_data() |> Event.from_data(pipeline: pipeline)

    assert {:ok, _state, _outputs, _log} =
             Runtime.dispatch(Runtime.demo_state(), event, pipeline: pipeline)
  end
end
