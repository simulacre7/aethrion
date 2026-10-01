defmodule Aethrion.ConsolidationTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Memories, Memory, Runtime, State}

  defp warm(text), do: Event.message_sent("user", "mina", text, tone: :warm)

  defp impressions(state, character) do
    Enum.filter(state.memories, &(&1.character_id == character and &1.kind == :impression))
  end

  test "a single faded memory is not consolidated" do
    {state, _outputs} = run!(Runtime.demo_state(), [warm("hi"), Event.time_tick("t", hours: 72)])

    assert [] = impressions(state, "mina")
  end

  test "faded memories of the same pattern become one impression" do
    {state, _outputs} =
      run!(Runtime.demo_state(), [warm("a"), warm("b"), Event.time_tick("t", hours: 72)])

    assert [%Memory{} = impression] = impressions(state, "mina")
    assert impression.content == "user has been warm to mina 2 times."
    assert impression.importance == 60
    assert impression.data["count"] == 2
    refute Memory.faded?(impression)

    originals =
      Enum.filter(state.memories, &(&1.kind == :experienced and &1.character_id == "mina"))

    assert Enum.all?(originals, &(&1.consolidated_into == impression.id))
  end

  test "impressions deepen as more memories fade" do
    {state, _outputs} =
      run!(Runtime.demo_state(), [warm("a"), warm("b"), Event.time_tick("t", hours: 72)])

    {state, _outputs} = run!(state, [warm("c"), Event.time_tick("t", hours: 72)])

    assert [impression] = impressions(state, "mina")
    assert impression.content == "user has been warm to mina 3 times."
    assert impression.importance == 70
    # Dated from when the latest memory ("c", created at hour 72) faded.
    assert impression.created_tick == 72 + 46
  end

  test "different patterns and actors stay separate" do
    events = [
      warm("a"),
      warm("b"),
      Event.message_sent("user", "mina", "ugh", tone: :hostile),
      Event.message_sent("user", "mina", "ugh!", tone: :hostile),
      Event.message_sent("haru", "mina", "hey", tone: :warm),
      Event.message_sent("haru", "mina", "hey!", tone: :warm),
      Event.time_tick("t", hours: 200)
    ]

    {state, _outputs} = run!(Runtime.demo_state(), events)

    assert state |> impressions("mina") |> Enum.map(& &1.content) |> Enum.sort() == [
             "haru has been warm to mina 2 times.",
             "user has been hostile to mina 2 times.",
             "user has been warm to mina 2 times."
           ]
  end

  test "impressions are not gossip, and survive persistence" do
    {state, _outputs} =
      run!(Runtime.demo_state(), [warm("a"), warm("b"), Event.time_tick("t", hours: 72)])

    state = State.update_character_state(state, "mina", &%{&1 | jealousy: 20})
    {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 1))

    refute Enum.any?(step.events, &(&1.type == :gossip_shared))

    data = step.state |> State.to_data() |> Jason.encode!() |> Jason.decode!()
    assert State.from_data(data) == step.state
  end

  test "impressions are selected as context once the details have faded" do
    {state, _outputs} =
      run!(Runtime.demo_state(), [warm("a"), warm("b"), Event.time_tick("t", hours: 72)])

    assert [%{kind: :impression} | _] = Memories.relevant(state, "mina", focus: ["user"])
  end

  test "counts only read impressions under their own ids" do
    stray =
      Memory.new(
        id: "seed-1",
        character_id: "mina",
        content: "x",
        importance: 80,
        created_at: "seed",
        kind: :impression,
        topic: "impression:mina:hostile:user",
        data: %{
          "event" => "impression",
          "pattern" => "hostile",
          "from" => "user",
          "to" => "mina",
          "count" => 4
        }
      )

    state = %{Runtime.demo_state() | memories: [stray]}
    assert Aethrion.Rules.Consolidation.counts(state, "mina", "user") == %{}
  end
end
