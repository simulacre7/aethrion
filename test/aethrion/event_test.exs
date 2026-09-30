defmodule Aethrion.EventTest do
  use ExUnit.Case, async: true

  alias Aethrion.Event

  test "events round-trip through JSON-style data" do
    events = [
      Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "t1"),
      Event.time_tick("t2", hours: 3),
      Event.apology_offered("user", "yuna", "sorry", at: "t3"),
      Event.message_sent("user", "haru", "hey", tone: :cold, at: "t4"),
      Event.gossip_shared("yuna", "haru", "memory:yuna:observed:e1", at: "t5"),
      Event.comfort_offered("haru", "yuna", at: "t6")
    ]

    for event <- events do
      data = event |> Event.to_data() |> Jason.encode!() |> Jason.decode!()
      assert {:ok, ^event} = Event.from_data(data)
    end
  end

  test "unknown event types are rejected without creating atoms" do
    assert {:error, {:unsupported_event, "summon_dragon"}} =
             Event.from_data(%{"type" => "summon_dragon"})

    assert {:error, {:invalid_event, %{}}} = Event.from_data(%{})
  end

  test "unknown tones stay strings so validation can reject them" do
    assert {:ok, %{tone: "smug"}} =
             Event.from_data(%{
               "type" => "message_sent",
               "from" => "user",
               "to" => "mina",
               "text" => "hi",
               "tone" => "smug"
             })
  end

  test "describe renders one-line summaries" do
    names = &String.capitalize/1

    assert Event.describe(
             Event.gift_received("user", "mina", "flower", observed_by: ["yuna"]),
             names
           ) ==
             "User gives Mina a flower (seen by Yuna)"

    assert Event.describe(Event.time_tick("t", hours: 2)) == "time passes +2h"
    assert Event.describe(Event.comfort_offered("haru", "yuna"), names) == "Haru comforts Yuna"
  end
end
