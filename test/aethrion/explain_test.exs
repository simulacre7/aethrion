defmodule Aethrion.ExplainTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Explain, Runtime, State}
  alias Aethrion.CLI.CommandParser

  setup do
    {:ok, _state, steps} =
      Runtime.run(Runtime.demo_state(), [flower_for_mina(), Event.time_tick("t2", hours: 2)])

    %{
      trace: Enum.flat_map(steps, & &1.trace),
      events: Enum.flat_map(steps, & &1.events),
      state: List.last(steps).state
    }
  end

  test "explains a character value with the chain of causes", ctx do
    changes = Explain.character(ctx.trace, ctx.events, "yuna", :jealousy)

    assert [
             %{event_id: "e1", rule: :observation, before: 0, after: 15, chain: [%{id: "e1"}]},
             %{
               event_id: "e4",
               rule: :comfort,
               before: 15,
               after: 10,
               chain: [%{id: "e4"}, %{id: "e3"}, %{id: "e2"}]
             }
           ] = changes

    names = &State.name(ctx.state, &1)

    assert Explain.describe(changes, names) == [
             "jealousy 0 -> 15 by observation in e1: user gives Mina a flower (seen by Yuna)",
             "jealousy 15 -> 10 by comfort in e4: Haru comforts Yuna <- Yuna confides in Haru <- time passes +2h"
           ]
  end

  test "explains relationship values and moods", ctx do
    assert [%{rule: :gossip, after: 42}, %{rule: :comfort, after: 47}] =
             Explain.relationship(ctx.trace, ctx.events, "yuna", "haru", :trust)

    assert [%{before: :neutral, after: :jealous}, %{before: :jealous, after: :neutral}] =
             Explain.character(ctx.trace, ctx.events, "yuna", :mood)

    assert [] = Explain.character(ctx.trace, ctx.events, "haru", :jealousy)
  end

  test "the CLI parses value explanations without creating atoms" do
    assert {:ok, {:why, "yuna", :jealousy}} = CommandParser.parse("why yuna jealousy")
    assert {:ok, {:why, {"yuna", "haru"}, :trust}} = CommandParser.parse("why yuna->haru trust")
    assert {:error, "field must be one of: " <> _} = CommandParser.parse("why yuna sparkle")
    assert {:error, _} = CommandParser.parse("why yuna->haru jealousy")
  end
end
