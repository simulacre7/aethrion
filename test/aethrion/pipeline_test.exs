defmodule Aethrion.PipelineTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Pipeline, Runtime, Transition}

  defmodule Rivalry do
    use Aethrion.Rule, id: :rivalry, description: "Haru grows tense toward gift receivers."

    @impl true
    def apply(%Transition{event: event} = transition) do
      Transition.adjust_relationship(transition, "haru", event.to, :tension, 5)
    end
  end

  defmodule Festival do
    use Aethrion.Rule, id: :festival, description: "Everyone cheers up at the festival."

    @impl true
    def apply(%Transition{} = transition) do
      transition.state
      |> Aethrion.State.sorted_characters()
      |> Enum.reduce(transition, &Transition.adjust_character(&2, &1.id, :joy, 30))
      |> Transition.note("The festival lifts everyone's spirits")
    end
  end

  test "the default pipeline maps every built-in event type" do
    assert Pipeline.event_types(Pipeline.default()) == Enum.sort(Event.types())
  end

  test "custom rules can be appended to an event type" do
    pipeline = Pipeline.append(Pipeline.default(), :gift_received, Rivalry)

    assert Pipeline.rules_for(pipeline, :gift_received) |> Enum.take(4) ==
             [Aethrion.Rules.Gift, Aethrion.Rules.Reply, Aethrion.Rules.Observation, Rivalry]

    {state, outputs} = dispatch!(Runtime.demo_state(), flower_for_mina(), pipeline: pipeline)

    assert Aethrion.State.get_relationship(state, "haru", "mina").tension == 5
    assert Enum.any?(outputs, &(&1.rule == :rivalry))
  end

  test "custom event types run through reactive rules" do
    pipeline = Pipeline.append(Pipeline.default(), :festival, Festival)
    {:ok, step} = Runtime.step(Runtime.demo_state(), %{type: :festival}, pipeline: pipeline)

    assert character_state(step.state, "mina").mood == :happy
    assert "[Rule] The festival lifts everyone's spirits" in step.log
    assert Enum.any?(step.outputs, &(&1.type == :mood_changed and &1.rule == :mood))

    assert {:error, %{code: :unsupported_event}} =
             Runtime.dispatch(Runtime.demo_state(), %{type: :festival})
  end

  test "prepend, remove, and add_reactive edit the pipeline" do
    pipeline =
      Pipeline.default()
      |> Pipeline.prepend(:gift_received, Rivalry)
      |> Pipeline.remove(Aethrion.Rules.Proactive)
      |> Pipeline.add_reactive(Festival)

    assert [Rivalry | _] = pipeline.event_rules.gift_received
    # Custom reactive rules run before Bond, so their relationship changes are announced.
    assert pipeline.reactive_rules == [
             Aethrion.Rules.Mood,
             Festival,
             Aethrion.Rules.Bond,
             Aethrion.Rules.Milestone,
             Aethrion.Rules.Ending
           ]
  end

  test "describe lists rules with ids and descriptions" do
    description = Pipeline.describe(Pipeline.default())

    assert {:gift_received, [{:gift, _}, {:reply, _}, {:observation, _}]} =
             List.keyfind(description, :gift_received, 0)

    assert {:reactive, [{:mood, _}, {:proactive, _}, {:bond, _}, {:milestone, _}, {:ending, _}]} =
             List.last(description)
  end

  test "transition helpers reject unknown fields" do
    transition = Transition.new(Runtime.demo_state(), %{type: :test, id: "e1"})

    assert_raise ArgumentError, fn ->
      Transition.adjust_character(transition, "mina", :mood, 1)
    end

    assert_raise ArgumentError, fn ->
      Transition.adjust_relationship(transition, "mina", "user", :love, 1)
    end
  end
end
