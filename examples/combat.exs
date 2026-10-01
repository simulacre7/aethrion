# mix run examples/combat.exs
#
# A fight with the wolf king (priv/casts/quest.json), played five ways.
# Hp, damage, and who falls are decided by the numbers and replay exactly;
# so is how the companions come to feel about you, and the ending the
# story reaches the moment the fight is settled.

alias Aethrion.{Combat, Event, Runtime, State}

{:ok, quest} =
  "priv/casts/quest.json" |> File.read!() |> Jason.decode!() |> State.parse()

party = ["ria", "kael"]

# Each round, what the player does. The companions (party members) fight
# beside a player they trust, and hold back from one they do not.
insult = fn who -> Event.message_sent("user", who, "Stay out of my way.", tone: :hostile) end
strike = Event.attack("user", "wolf", skill: "sword")

playthroughs = %{
  "together" => fn _state, round ->
    if round == 2,
      do: [Event.message_sent("user", "ria", "Thank you, Ria. Stay behind me.", tone: :warm), strike],
      else: [strike]
  end,
  "kael insulted" => fn _state, round -> if round == 1, do: [insult.("kael"), strike], else: [strike] end,
  "lone wolf" => fn state, round ->
    hurt? = State.stat(state, "user", "hp") < 14 and State.stat(state, "user", "potions") > 0

    cond do
      round == 1 -> [insult.("kael"), insult.("ria"), strike]
      hurt? -> [Combat.action(state, "user", nil, "물약을 들이켠다")]
      true -> [strike]
    end
  end,
  "retreat" => fn state, round ->
    if round < 2,
      do: [strike],
      else: [Combat.action(state, "user", nil, "등을 돌려 도망친다!")]
  end,
  "reckless" => fn _state, round ->
    if round == 1,
      do: [insult.("kael"), insult.("ria"), Combat.action(quest, "user", "wolf", "I charge at the wolf king!")],
      else: [Combat.action(quest, "user", "wolf", "I charge at the wolf king!")]
  end
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
