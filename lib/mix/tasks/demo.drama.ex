defmodule Mix.Tasks.Demo.Drama do
  @moduledoc "Runs the scripted Aethrion drama demo."
  @shortdoc "Runs the scripted Aethrion drama demo"

  use Mix.Task

  alias Aethrion.CLI.Display
  alias Aethrion.{Event, Runtime}

  @impl Mix.Task
  def run(_args) do
    Display.banner()

    state = Runtime.demo_state()
    print_characters(state)

    events = [
      Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "demo:t1"),
      Event.time_tick("demo:t2", hours: 2)
    ]

    Enum.reduce(events, state, fn event, state ->
      Display.event(event)

      {:ok, state, outputs, log} = Runtime.dispatch(state, event)

      Enum.each(log, &Display.log/1)
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

    Display.message("World: #{names}")
  end

  defp print_outputs(outputs) do
    Enum.each(outputs, &Display.output/1)
  end
end
