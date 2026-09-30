# mix run examples/embed_runtime.exs
#
# Dispatch events against the deterministic core and inspect what happened.

alias Aethrion.{Event, Runtime, Trace}

state = Runtime.demo_state()

{:ok, state, outputs, log} =
  Runtime.dispatch(state, Event.gift_received("user", "mina", "flower", observed_by: ["yuna"]))

IO.puts("== gift")
Enum.each(log, &IO.puts/1)
IO.puts("outputs: #{Enum.map_join(outputs, ", ", &to_string(&1.type))}")

# step/3 returns everything: follow-up events, outputs, and the trace.
{:ok, step} = Runtime.step(state, Event.time_tick("example:t2", hours: 2))

IO.puts("\n== two hours later")

for event <- step.events do
  cause = if event[:cause], do: " (caused by #{event.cause})", else: ""
  IO.puts("#{event.id} #{Event.describe(event)}#{cause}")
end

IO.puts("\n== what characters said")

for %{text: text} = output <- step.outputs, Aethrion.Output.expressive?(output) do
  speaker = output.character_id
  IO.puts("#{speaker}: #{text}")
end

IO.puts("\n== why Yuna feels the way she does")

step.trace
|> Enum.filter(&Trace.concerns?(&1, "yuna"))
|> Enum.reject(&(&1.kind == :output))
|> Enum.each(&IO.puts("  " <> Trace.describe(&1)))
