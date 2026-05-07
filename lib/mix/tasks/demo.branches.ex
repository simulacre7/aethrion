defmodule Mix.Tasks.Demo.Branches do
  @moduledoc "Runs a branched Aethrion scenario demo."
  @shortdoc "Runs a branched Aethrion scenario demo"

  use Mix.Task

  alias Aethrion.CLI.Display
  alias Aethrion.{Event, Runtime, State}

  @impl Mix.Task
  def run(_args) do
    Display.banner()
    Display.message("Branch demo: the same setup diverges after the user's next choice.")

    Display.message("\nShared setup")

    {base_state, _setup_outputs} =
      Runtime.demo_state()
      |> dispatch_and_print(
        Event.gift_received("user", "mina", "flower",
          observed_by: ["yuna"],
          at: "branch:setup"
        )
      )

    ignored_branch =
      run_branch(
        "Branch A: user ignores Yuna",
        base_state,
        [Event.time_tick("branch:ignored:t1", hours: 2)]
      )

    apology_branch =
      run_branch(
        "Branch B: user apologizes to Yuna",
        base_state,
        [
          Event.apology_offered("user", "yuna", "I should have checked in with you too.",
            at: "branch:apology:t1"
          ),
          Event.time_tick("branch:apology:t2", hours: 2)
        ]
      )

    print_summary(ignored_branch, apology_branch)

    :ok
  end

  defp run_branch(title, state, events) do
    Display.message("\n#{title}")

    Enum.reduce(events, {state, []}, fn event, {state, all_outputs} ->
      {state, outputs} = dispatch_and_print(state, event)
      {state, all_outputs ++ outputs}
    end)
  end

  defp dispatch_and_print(state, event) do
    Display.event(event)

    {:ok, state, outputs, log} = Runtime.dispatch(state, event)

    Enum.each(log, &Display.log/1)
    Enum.each(outputs, &Display.output/1)

    {state, outputs}
  end

  defp print_summary({ignored_state, ignored_outputs}, {apology_state, apology_outputs}) do
    ignored_yuna = ignored_state.characters["yuna"].state
    apology_yuna = apology_state.characters["yuna"].state

    ignored_message? = Enum.any?(ignored_outputs, &(&1.type == :proactive_message))
    apology_message? = Enum.any?(apology_outputs, &(&1.type == :proactive_message))

    Display.message("\nBranch result")

    Display.message(
      "Ignored: Yuna jealousy=#{ignored_yuna.jealousy}, loneliness=#{ignored_yuna.loneliness}, proactive_message=#{ignored_message?}"
    )

    Display.message(
      "Apology: Yuna jealousy=#{apology_yuna.jealousy}, loneliness=#{apology_yuna.loneliness}, proactive_message=#{apology_message?}"
    )

    Display.message(
      "Yuna trust toward user: #{State.get_relationship(apology_state, "yuna", "user").trust}"
    )
  end
end
