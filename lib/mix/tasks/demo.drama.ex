defmodule Mix.Tasks.Demo.Drama do
  @moduledoc "Runs the scripted Aethrion drama demo."
  @shortdoc "Runs the scripted Aethrion drama demo"

  use Mix.Task

  alias Aethrion.{Event, Runtime}

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Aethrion (에이트리온 / ay-three-on)")
    Mix.shell().info("A shared social layer for persistent AI characters.\n")

    state = Runtime.demo_state()
    print_characters(state)

    events = [
      Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "demo:t1"),
      Event.time_tick("demo:t2", hours: 2)
    ]

    Enum.reduce(events, state, fn event, state ->
      Mix.shell().info("")
      Mix.shell().info(format_event(event))

      {:ok, state, outputs, log} = Runtime.dispatch(state, event)

      Enum.each(log, fn line -> Mix.shell().info(line) end)
      print_outputs(outputs)

      state
    end)

    :ok
  end

  defp print_characters(state) do
    names =
      state.characters
      |> Map.values()
      |> Enum.map(& &1.name)
      |> Enum.join(", ")

    Mix.shell().info("[World] Characters loaded: #{names}")
  end

  defp print_outputs(outputs) do
    Enum.each(outputs, fn
      %{type: :proactive_message, character_id: character_id, reason: reason} ->
        Mix.shell().info(
          "[Structured Output] proactive_message character=#{character_id} reason=#{reason}"
        )

      %{type: :relationship_changed, from: from, to: to, delta: delta} ->
        Mix.shell().info(
          "[Structured Output] relationship_changed #{from}->#{to} #{inspect(delta)}"
        )

      %{type: :memory_created, memory: memory} ->
        Mix.shell().info("[Structured Output] memory_created id=#{memory.id}")
    end)
  end

  defp format_event(%{type: :gift_received, from: from, to: to, item: item}) do
    "[Event] #{from} gives #{to} a #{item}"
  end

  defp format_event(%{type: :time_tick, hours: hours}) do
    "[Event] time_tick +#{hours}h"
  end
end
