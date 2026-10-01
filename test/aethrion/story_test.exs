defmodule Aethrion.StoryTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Event, Explain, Runtime, State, Story}

  @story %{
    "deadline" => 48,
    "activities" => %{
      "study" => %{"intelligence" => 5, "stress" => 10},
      "rest" => %{"stress" => -30}
    },
    "endings" => [
      %{
        "id" => "close",
        "title" => "Close",
        "when" => [
          %{"bond" => ["mina", "user"], "at_least" => "friendly"},
          %{"relationship" => ["mina", "user"], "field" => "affinity", "at_least" => 60}
        ]
      },
      %{
        "id" => "smart",
        "title" => "Smart",
        "when" => [%{"stat" => ["mina", "intelligence"], "at_least" => 20}]
      },
      %{"id" => "ordinary", "title" => "Ordinary", "when" => []}
    ]
  }

  defp world(extra \\ %{}) do
    {:ok, state} =
      Runtime.demo_state()
      |> State.to_data()
      |> Map.put("story", @story)
      |> Map.merge(extra)
      |> State.parse()

    state
  end

  defp run(state, events) do
    Enum.reduce(events, {state, []}, fn event, {state, outputs} ->
      {:ok, step} = Runtime.step(state, event)
      {step.state, outputs ++ step.outputs}
    end)
  end

  test "activities change stats and feelings, and are explained" do
    {:ok, step} = Runtime.step(world(), Event.activity("mina", "study"))

    assert State.stat(step.state, "mina", "intelligence") == 5
    assert step.state.characters["mina"].state.stress == 10
    assert [%{before: 0, after: 5}] = Explain.stat([step], "mina", "intelligence")

    assert {:error, %{code: :invalid_event, details: %{field: :activity}}} =
             Runtime.step(world(), Event.activity("mina", "juggle"))

    # Stats do not go below zero; feelings stay within 0..100.
    {state, _} = run(world(), [Event.activity("mina", "rest")])
    assert state.characters["mina"].state.stress == 0
  end

  test "the first ending whose conditions hold, with progress toward the others" do
    {state, _} = run(world(), List.duplicate(Event.activity("mina", "study"), 4))

    assert {:ok, %{id: "smart", because: ["mina intelligence 20 (needs at least 20)"]}} =
             Story.ending(state)

    assert [close, smart, ordinary] = Story.progress(state)
    assert %{id: "close", met: 1, total: 2, missing: [missing]} = close
    assert missing =~ "mina -> user affinity 40 (needs at least 60)"
    assert close.closeness > 0.5 and close.closeness < 1
    assert %{met: 1, total: 1, closeness: 1.0} = smart
    assert %{total: 0} = ordinary
  end

  test "the ending is reached once, at the deadline" do
    state = world()
    {state, outputs} = run(state, [Event.time_tick("day 1", hours: 24)])
    assert [] = for(%{type: :ending_reached} = o <- outputs, do: o)

    {state, outputs} =
      run(state, [Event.time_tick("day 2", hours: 24), Event.time_tick("day 3", hours: 24)])

    assert [%{ending: "ordinary", title: "Ordinary", because: []}] =
             for(%{type: :ending_reached} = o <- outputs, do: o)

    # Saved and loaded, the story, stats, and the decision stay.
    {:ok, loaded} =
      state |> State.to_data() |> Jason.encode!() |> Jason.decode!() |> State.parse()

    assert loaded == state
  end

  test "story mistakes are errors with a path" do
    for {story, message} <- [
          {%{"endings" => [%{"id" => "a", "when" => [%{"stat" => ["mina", "x"]}]}]}, "at_least"},
          {%{"endings" => [%{"id" => "a"}, %{"id" => "a"}]}, "more than once"},
          {%{
             "endings" => [
               %{"id" => "a", "when" => [%{"bond" => ["mina", "user"], "is" => "lovers"}]}
             ]
           }, "bond name"},
          {%{"deadline" => -1}, "positive"},
          {%{"activities" => %{"study" => %{"iq" => "high"}}}, "whole numbers"},
          {%{"endings" => [%{"id" => "a"}], "decide_whne" => []}, "unknown key \"decide_whne\""},
          {%{"endings" => [%{"id" => "a", "tilte" => "A"}]}, "unknown key \"tilte\""},
          {%{
             "endings" => [
               %{"id" => "a", "when" => [%{"stat" => ["mina", "art"], "at_leats" => 3}]}
             ]
           }, "at_least"},
          {%{
             "endings" => [
               %{
                 "id" => "a",
                 "when" => [%{"stat" => ["mina", "art"], "at_least" => 3, "at_most" => 9}]
               }
             ]
           }, "compares one way"},
          {%{
             "endings" => [
               %{"id" => "a", "when" => [%{"stat" => ["mnia", "art"], "at_least" => 3}]}
             ]
           }, "\"mnia\", who is not in this cast"},
          {%{
             "endings" => [
               %{
                 "id" => "a",
                 "when" => [%{"character" => "user", "field" => "joy", "at_least" => 3}]
               }
             ]
           }, "not a character"},
          {%{"endings" => [%{"id" => "always"}, %{"id" => "never"}]},
           "\"never\" can never be reached"},
          {%{"deadline" => 24}, "needs endings"}
        ] do
      data = Runtime.demo_state() |> State.to_data() |> Map.put("story", story)
      assert {:error, %{code: :invalid_state, message: got}} = State.parse(data)
      assert got =~ message
    end
  end

  test "with no ending matching yet, the story stays open until one does" do
    story = %{
      "activities" => @story["activities"],
      "decide_when" => [%{"stat" => ["mina", "intelligence"], "at_least" => 10}],
      "endings" => [
        %{
          "id" => "smart",
          "when" => [
            %{"stat" => ["mina", "intelligence"], "at_least" => 10},
            %{"relationship" => ["mina", "user"], "field" => "trust", "at_least" => 50}
          ]
        }
      ]
    }

    state = world(%{"story" => story})
    {:ok, step} = Runtime.step(state, Event.activity("mina", "study"))
    {:ok, step} = Runtime.step(step.state, Event.activity("mina", "study"))
    assert [] = for(%{type: :ending_reached} = o <- step.outputs, do: o)
    assert Enum.any?(step.log, &(&1 =~ "no ending matched yet"))
    refute Aethrion.Rules.Ending.reached?(step.state)

    trusting = State.update_relationship(step.state, "mina", "user", &%{&1 | trust: 60})
    {:ok, step} = Runtime.step(trusting, Event.activity("mina", "study"))
    assert [%{ending: "smart"}] = for(%{type: :ending_reached} = o <- step.outputs, do: o)
  end

  test "the summer cast: each daily routine reaches its own ending, and the story then closes" do
    {:ok, world} = "priv/casts/summer.json" |> File.read!() |> Jason.decode!() |> State.parse()
    say = &Event.message_sent("user", "seoyun", &1, tone: &2)
    act = &Event.activity("seoyun", &1)
    every = fn d, n, yes, no -> if rem(d, n) == 0, do: yes, else: no end

    routines = %{
      "family" => fn d ->
        [say.("오늘도 고생했어. 네 그림 정말 좋아.", :warm), act.(every.(d, 3, "휴식", "그림"))] ++
          every.(d, 6, [Event.gift_received("user", "seoyun", "물감")], [])
      end,
      "painter" => fn d ->
        [act.(every.(d, 4, "휴식", "그림"))] ++ every.(d, 5, [say.("멋지다.", :warm)], [])
      end,
      "scholar" => fn d -> [act.(every.(d, 3, "휴식", "공부"))] end,
      "burnout" => fn _d -> [act.("공부")] end,
      "apart" => fn d ->
        [every.(d, 2, say.("또 그림이야? 한심하다.", :hostile), say.("알아서 해.", :cold)), act.("휴식")]
      end,
      "ordinary" => fn d -> [act.(Enum.at(["공부", "그림", "휴식", "산책"], rem(d, 4)))] end
    }

    for {expected, routine} <- routines do
      {_state, reached} =
        Enum.reduce_while(1..30, {world, nil}, fn d, {state, nil} ->
          {state, reached} =
            Enum.reduce(routine.(d) ++ [Event.time_tick("day #{d}", hours: 24)], {state, nil}, fn
              event, {state, reached} ->
                {:ok, step} = Runtime.step(state, event)
                {step.state, reached || Enum.find(step.outputs, &(&1.type == :ending_reached))}
            end)

          if reached, do: {:halt, {state, reached}}, else: {:cont, {state, nil}}
        end)

      assert %{ending: ^expected} = reached
    end

    # Pushed past breaking, she stops before the deadline; after that the
    # days are not spent anymore.
    {state, _} = run(world, List.duplicate(act.("공부"), 12))
    assert Aethrion.Rules.Ending.reached(state).id == "burnout"

    assert {:error, %{message: "the story has reached its ending"}} =
             Runtime.step(state, act.("휴식"))
  end
end
