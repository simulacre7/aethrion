defmodule Mix.Tasks.Demo.Drama do
  @moduledoc """
  Runs the scripted Aethrion drama demo.

      mix demo.drama
      mix demo.drama --effects

  The host sends two events: a gift Yuna witnesses, and two hours passing.
  Everything after that (Yuna reaching out, confiding in Haru, Haru teasing
  the user, Haru comforting Yuna) is produced by deterministic rules.
  """
  @shortdoc "Runs the scripted Aethrion drama demo"

  use Mix.Task

  alias Aethrion.CLI.Display
  alias Aethrion.{Event, Runtime, State}

  @impl Mix.Task
  def run(args) do
    {opts, _paths} =
      Aethrion.CLI.TaskArgs.parse!(args, [effects: :boolean], "mix demo.drama [--effects]", 0)
    Display.banner()

    state = Runtime.demo_state()

    Display.message(
      "World: #{state |> State.sorted_characters() |> Enum.map_join(", ", & &1.name)}"
    )

    Display.message("The host sends 2 events. Everything else is emergent.\n")

    events = [
      Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: "demo:t1"),
      Event.time_tick("demo:t2", hours: 2)
    ]

    final =
      Enum.reduce(events, state, fn event, state ->
        {:ok, step} = Runtime.step(state, event)

        Display.event(step.event, state)
        Enum.each(step.log, &Display.log/1)
        if opts[:effects], do: Enum.each(step.outputs, &Display.output/1)
        Display.message("")

        step.state
      end)

    Display.message("#{final.seq} events processed from 2 host events.")
    :ok
  end
end
