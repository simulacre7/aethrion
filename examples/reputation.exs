# mix run examples/reputation.exs
#
# How someone treats one character reaches the others: a witness judges it on
# the spot, a friend judges it from hearsay, and the details fade into a
# reputation. Bonds name what each relationship has become along the way.
# Finally the whole story goes into a journal, which is compacted.

alias Aethrion.{Event, Journal, Relationship, Runtime, State}
alias Aethrion.Rules.{Bond, Consolidation}

state =
  State.new(
    characters: [
      %Aethrion.Character{id: "ana", name: "Ana", profile: "New on the team."},
      %Aethrion.Character{id: "ben", name: "Ben", profile: "Ana's desk neighbour."},
      %Aethrion.Character{id: "cho", name: "Cho", profile: "Ben's oldest friend."}
    ],
    relationships: [
      %Relationship{from: "ana", to: "user", affinity: 30, trust: 20},
      %Relationship{from: "ben", to: "user", affinity: 30, trust: 25},
      %Relationship{from: "ben", to: "ana", affinity: 35, trust: 30},
      %Relationship{from: "cho", to: "user", affinity: 30, trust: 25},
      %Relationship{from: "cho", to: "ana", affinity: 25, trust: 20},
      %Relationship{from: "ana", to: "cho", affinity: 30, trust: 45}
    ]
  )

show = fn label, state ->
  IO.puts("\n== #{label}")

  for id <- ["ana", "ben", "cho"] do
    r = State.get_relationship(state, id, "user")
    bond = Bond.derive(r, state)
    IO.puts("  #{id} -> user: #{bond} (affinity #{r.affinity}, trust #{r.trust}, tension #{r.tension})")
  end
end

events = [
  # Ben is at the next desk when the user snaps at Ana, twice.
  Event.message_sent("user", "ana", "This is wrong again.", tone: :hostile, observed_by: ["ben"]),
  Event.message_sent("user", "ana", "Nobody asked for your opinion.", tone: :hostile, observed_by: ["ben"]),
  # Ana, upset, tells Cho about the first one; Cho hears it secondhand.
  Event.gossip_shared("ana", "cho", "memory:ana:message:e1"),
  # The user is friendly to Ben the next morning.
  Event.message_sent("user", "ben", "Coffee?", tone: :warm)
]

show.("before", state)
{:ok, after_day, steps} = Runtime.run(state, events)
show.("after the day", after_day)

IO.puts("\n== what happened")

for step <- steps, line <- step.log, String.starts_with?(line, ["[Rule]", "[Bond]", "[Output]"]) do
  IO.puts("  " <> line)
end

# A week later the sightings have faded into what Ben knows about the user.
{:ok, week} = Runtime.step(after_day, Event.time_tick("next week", hours: 120))
ben = Consolidation.reputation_count(week.state, "ben", "hostile", "user")
IO.puts("\n== a week later")
IO.puts("  Ben has seen the user be hostile to others #{ben} times:")

for memory <- week.state.memories, memory.character_id == "ben", memory.kind == :impression do
  IO.puts("  " <> memory.content)
end

# Everything above as a journal, then compacted into a fast-starting one.
path = Path.join(System.tmp_dir!(), "aethrion-reputation-#{System.unique_integer([:positive])}.jsonl")
:ok = Journal.create(path, state)

Enum.reduce(events, state, fn event, state ->
  {:ok, step} = Runtime.step(state, event)
  :ok = Journal.append(path, step.event)
  step.state
end)

{:ok, compacted, count} = Journal.compact(path)
true = compacted == after_day
IO.puts("\n== journal")
IO.puts("  compacted #{count} events; the journal now starts from the end of the day")
File.rm!(path)
