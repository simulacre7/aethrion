# mix run examples/combat.exs
#
# A fight with the wolf king (priv/casts/quest.json), played three ways.
# Hp, damage, and who falls are decided by the numbers and replay exactly;
# so is how the companions come to feel about you, and the ending the
# story reaches the moment the fight is settled.

alias Aethrion.{Combat, Event, Runtime, State}

{:ok, quest} =
  "priv/casts/quest.json" |> File.read!() |> Jason.decode!() |> State.parse()

party = ["ria", "kael"]
hp = fn state, id -> State.stat(state, id, "hp") end

# Each round: what the player does, then what the companions do.
playthroughs = %{
  "together" => fn state, round ->
    player =
      if rem(round, 4) == 0,
        do: Event.message_sent("user", "ria", "Thank you, Ria. Stay behind me.", tone: :warm),
        else: Event.attack("user", "wolf", skill: "sword", observed_by: party)

    companions =
      [Event.attack("kael", "wolf", observed_by: ["ria"])] ++
        if hp.(state, "user") < 18, do: [Event.heal("ria", "user")], else: []

    [player | companions]
  end,
  "alone" => fn _state, round ->
    insult =
      if round == 1,
        do: [Event.message_sent("user", "kael", "Stay out of my way.", tone: :hostile, observed_by: ["ria"])],
        else: []

    # Kael fights anyway; he is paid to.
    insult ++ [Event.attack("user", "wolf"), Event.attack("kael", "wolf")]
  end,
  "reckless" => fn _state, _round -> [Combat.action(quest, "user", "wolf", "I charge at the wolf king!")] end
}

play = fn routine ->
  Enum.reduce_while(1..30, {quest, []}, fn round, {state, told} ->
    {state, told, ending} =
      Enum.reduce(routine.(state, round), {state, told, nil}, fn event, {state, told, ending} ->
        case Runtime.step(state, event) do
          {:ok, step} ->
            lines = for %{type: :combat} = o <- step.outputs, do: Combat.describe(o, step.state, :ko)
            reached = Enum.find(step.outputs, &(&1.type == :ending_reached))
            {step.state, told ++ lines, ending || reached}

          # A fighter already down cannot act; the others carry on.
          {:error, _down} ->
            {state, told, ending}
        end
      end)

    if ending, do: {:halt, {state, told, ending}}, else: {:cont, {state, told}}
  end)
end

for {name, routine} <- Enum.sort(playthroughs) do
  {state, told, ending} = play.(routine)

  IO.puts("== #{name}")
  for line <- Enum.take(told, 4), do: IO.puts("  #{line}")
  IO.puts("  ...")
  for line <- Enum.take(told, -2), do: IO.puts("  #{line}")
  IO.puts("  ★ #{ending.title}: #{ending.description}")
  for reason <- ending.because, do: IO.puts("    because #{reason}")

  for id <- party do
    rel = State.get_relationship(state, id, "user")
    IO.puts("    #{State.name(state, id)} -> you: affinity #{rel.affinity}, trust #{rel.trust}")
  end

  IO.puts("")
end
