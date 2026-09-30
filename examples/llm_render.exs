# ANTHROPIC_API_KEY=... mix run examples/llm_render.exs
# AETHRION_LLM_BASE_URL=http://localhost:11434/v1 AETHRION_LLM_MODEL=llama3.2 mix run examples/llm_render.exs
#
# Render the demo drama through a real model when one is configured,
# and show that the simulation is identical either way.

alias Aethrion.{Event, Expression, Intent, Runtime}
alias Aethrion.LLM.{Anthropic, FakeAdapter, OpenAICompatible}

adapter =
  cond do
    Anthropic.configured?() -> Anthropic
    OpenAICompatible.configured?() -> OpenAICompatible
    true -> FakeAdapter
  end

IO.puts("adapter: #{inspect(adapter)}\n")

{:ok, state, _outputs, _log} =
  Runtime.dispatch(
    Runtime.demo_state(),
    Event.gift_received("user", "mina", "flower", observed_by: ["yuna"])
  )

{:ok, step} = Runtime.step(state, Event.time_tick("t2", hours: 2))

for output <- Expression.render(step.outputs, adapter: adapter),
    Aethrion.Output.expressive?(output) do
  speaker = output.character_id
  IO.puts("#{speaker} (#{output.expression.status})")
  IO.puts("  fallback: #{output.context.fallback_text}")
  IO.puts("  rendered: #{output.text}\n")
end

{:ok, event, meta} =
  Intent.interpret(step.state, "I'm sorry, I should have noticed you were upset.",
    to: "yuna",
    adapter: adapter
  )

IO.puts("intent: #{event.type} (#{meta.status})")
