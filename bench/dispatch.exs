# mix run bench/dispatch.exs [characters] [hours]
#
# Builds a world with N characters in a ring of trust, lets them watch gifts and
# talk for a while, then reports dispatch timings. Deterministic: the same
# arguments always build the same world.

alias Aethrion.{Character, CharacterState, Event, Relationship, Runtime, State}

{characters, hours} =
  case System.argv() do
    [n, h] -> {String.to_integer(n), String.to_integer(h)}
    [n] -> {String.to_integer(n), 48}
    [] -> {50, 48}
  end

ids = for i <- 1..characters, do: "c#{i}"

cast =
  for {id, i} <- Enum.with_index(ids) do
    traits = if rem(i, 3) == 0, do: [:talkative], else: [:sensitive]
    %Character{id: id, name: String.upcase(id), traits: traits, state: %CharacterState{loneliness: rem(i * 7, 40)}}
  end

relationships =
  for {id, i} <- Enum.with_index(ids), offset <- [1, 2, 5] do
    other = Enum.at(ids, rem(i + offset, characters))
    %Relationship{from: id, to: other, affinity: 30, trust: 35 + offset}
  end ++ (for id <- ids, do: %Relationship{from: id, to: "user", affinity: 35, trust: 20})

state = State.new(characters: cast, relationships: relationships)

events =
  Enum.flat_map(1..hours, fn hour ->
    receiver = Enum.at(ids, rem(hour * 13, characters))
    observers = for k <- 1..3, do: Enum.at(ids, rem(hour * 13 + k, characters))
    talker = Enum.at(ids, rem(hour * 17, characters))

    [
      Event.gift_received("user", receiver, "gift#{hour}", observed_by: observers, at: "h#{hour}"),
      Event.message_sent("user", talker, "hello", tone: Enum.at([:warm, :neutral, :cold], rem(hour, 3)), at: "h#{hour}"),
      Event.time_tick("h#{hour}", hours: 1)
    ]
  end)

{micros, {state, timings, processed}} =
  :timer.tc(fn ->
    Enum.reduce(events, {state, [], 0}, fn event, {state, timings, processed} ->
      {t, {:ok, step}} = :timer.tc(fn -> Runtime.step(state, event) end)
      {step.state, [{event.type, t} | timings], processed + length(step.events)}
    end)
  end)

by_type = Enum.group_by(timings, &elem(&1, 0), &elem(&1, 1))

IO.puts("characters: #{characters}, simulated hours: #{hours}")
IO.puts("host events: #{length(events)}, processed (with cascades): #{processed}")
IO.puts("memories at end: #{length(state.memories)}")
IO.puts("total: #{Float.round(micros / 1000, 1)} ms")

for {type, ts} <- Enum.sort(by_type) do
  sorted = Enum.sort(ts)
  p50 = Enum.at(sorted, div(length(sorted), 2))
  p99 = Enum.at(sorted, min(length(sorted) - 1, div(length(sorted) * 99, 100)))
  IO.puts("  #{String.pad_trailing(to_string(type), 14)} p50 #{Float.round(p50 / 1000, 2)} ms   p99 #{Float.round(p99 / 1000, 2)} ms")
end
