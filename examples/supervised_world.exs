# mix run examples/supervised_world.exs
#
# A long-running world with a scheduler and asynchronous expression rendering.
# The adapter here is deliberately slow; dispatch still returns immediately.

defmodule Example.SlowPoet do
  @behaviour Aethrion.LLM.Adapter

  @impl true
  def render(request, _opts) do
    Process.sleep(200)
    {:ok, "(softly) " <> request.fallback_text}
  end
end

alias Aethrion.{Event, World}

{:ok, _supervisor} =
  Supervisor.start_link(
    [
      {World,
       name: :garden,
       scheduler: [interval_ms: 300, tick_hours: 1],
       expression: [adapter: Example.SlowPoet, timeout: 2_000]}
    ],
    strategy: :one_for_one
  )

:ok = World.subscribe(:garden)

{elapsed, {:ok, _state, _outputs, _log}} =
  :timer.tc(fn ->
    World.dispatch(:garden, Event.gift_received("user", "mina", "flower", observed_by: ["yuna"]))
  end)

IO.puts("dispatch returned in #{div(elapsed, 1000)}ms")

defmodule Example.Listener do
  def listen(until) do
    remaining = until - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {:aethrion, _pid, {:dispatched, step}} ->
          IO.puts("dispatched #{step.event.id} #{Aethrion.Event.describe(step.event)}")

        {:aethrion, _pid, {:expressed, output}} ->
          speaker = output[:character_id] || output[:from]
          IO.puts("  #{speaker}: #{output.text}  [#{output.expression.status}]")
      after
        remaining -> :ok
      end

      listen(until)
    end
  end
end

Example.Listener.listen(System.monotonic_time(:millisecond) + 1_500)
IO.puts("clock: #{World.state(:garden).clock}h, history: #{length(World.history(:garden))} host events")
