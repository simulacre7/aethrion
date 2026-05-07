Mix.install([
  {:aethrion, path: Path.expand("..", __DIR__)}
])

alias Aethrion.{Event, Runtime}

state = Runtime.demo_state()

{:ok, state, outputs, log} =
  Runtime.dispatch(
    state,
    Event.gift_received("user", "mina", "flower", observed_by: ["yuna"])
  )

Enum.each(log, &IO.puts/1)
IO.inspect(outputs, label: "outputs")

{:ok, _state, outputs, log} = Runtime.dispatch(state, Event.time_tick("example:t2", hours: 2))

Enum.each(log, &IO.puts/1)
IO.inspect(outputs, label: "outputs")
