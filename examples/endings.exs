# mix run examples/endings.exs
#
# Thirty days with Mina, decided by the numbers, the way a raising sim
# decides its endings. Each player keeps a different daily routine; the
# same routine always reaches the same ending, and halfway through the
# story can say how close each ending is and what is missing.

alias Aethrion.{Event, Runtime, State, Story}

story = %{
  "deadline" => 30 * 24,
  "activities" => %{
    "study" => %{"intelligence" => 3, "stress" => 6, "joy" => -2},
    "paint" => %{"art" => 3, "joy" => 4, "stress" => 2},
    "rest" => %{"stress" => -15, "energy" => 10}
  },
  "endings" => [
    %{
      "id" => "lovers",
      "title" => "Together",
      "description" => "Mina asks you to stay. You do.",
      "when" => [
        %{"relationship" => ["mina", "user"], "field" => "affinity", "at_least" => 80},
        %{"relationship" => ["mina", "user"], "field" => "trust", "at_least" => 70},
        %{"bond" => ["mina", "user"], "is" => "close"}
      ]
    },
    %{
      "id" => "painter",
      "title" => "The painter",
      "description" => "Mina's first exhibition opens. Your name is on the dedication.",
      "when" => [
        %{"stat" => ["mina", "art"], "at_least" => 70},
        %{"relationship" => ["mina", "user"], "field" => "affinity", "at_least" => 40}
      ]
    },
    %{
      "id" => "scholar",
      "title" => "The scholar",
      "description" => "Mina leaves for the academy, a little lonelier and very proud.",
      "when" => [%{"stat" => ["mina", "intelligence"], "at_least" => 70}]
    },
    %{
      "id" => "parted",
      "title" => "Parting ways",
      "description" => "Mina stops answering. It was not one thing; it was every day.",
      "when" => [%{"bond" => ["mina", "user"], "at_most" => "strained"}]
    },
    %{"id" => "ordinary", "title" => "An ordinary summer", "when" => []}
  ]
}

{:ok, world} =
  Runtime.demo_state()
  |> State.to_data()
  |> Map.put("story", story)
  |> Map.put("stats", %{"mina" => %{"intelligence" => 10, "art" => 10}})
  |> State.parse(pipeline: Story.pipeline())

pipeline = Story.pipeline()
say = fn text, tone -> Event.message_sent("user", "mina", text, tone: tone) end
activity = fn name -> Event.activity("mina", name) end
day = Event.time_tick("the next day", hours: 24)

routines = %{
  "devoted" => fn d ->
    [say.("Good morning! I made you breakfast.", :warm), activity.("paint")] ++
      if rem(d, 5) == 0, do: [Event.gift_received("user", "mina", "flower")], else: []
  end,
  "tutor" => fn d -> [activity.("study")] ++ if(rem(d, 4) == 0, do: [activity.("rest")], else: []) end,
  "art school" => fn d ->
    [activity.("paint"), say.("How is the painting going?", :neutral)] ++
      if rem(d, 6) == 0, do: [say.("That one is beautiful.", :warm)], else: []
  end,
  "careless" => fn d ->
    if rem(d, 3) == 0, do: [say.("You're so annoying.", :hostile)], else: [say.("whatever", :cold)]
  end
}

run = fn routine, days, state ->
  Enum.reduce(1..days, {state, nil}, fn d, {state, ending} ->
    Enum.reduce(routine.(d) ++ [day], {state, ending}, fn event, {state, ending} ->
      {:ok, step} = Runtime.step(state, event, pipeline: pipeline)

      case Enum.find(step.outputs, &(&1.type == :ending_reached)) do
        nil -> {step.state, ending}
        reached -> {step.state, reached}
      end
    end)
  end)
end

for {name, routine} <- Enum.sort(routines) do
  {halfway, _} = run.(routine, 15, world)
  {final, ending} = run.(routine, 30, world)

  IO.puts("== #{name}")

  closest =
    halfway
    |> Story.progress()
    |> Enum.filter(&(&1.total > 0))
    |> Enum.max_by(& &1.closeness)

  IO.puts("  day 15: closest to \"#{closest.title}\" (#{round(closest.closeness * 100)}% there)")
  for missing <- closest.missing, do: IO.puts("    missing: #{missing}")

  IO.puts("  day 30: #{ending.title} - #{ending.description}")
  for reason <- ending.because, do: IO.puts("    because #{reason}")

  rel = State.get_relationship(final, "mina", "user")
  IO.puts("    (affinity #{rel.affinity}, trust #{rel.trust}, art #{State.stat(final, "mina", "art")}, intelligence #{State.stat(final, "mina", "intelligence")})\n")
end
