defmodule Mix.Tasks.Demo.Branches do
  @moduledoc """
  Runs the branched demo: one moment, four possible next moves.

      mix demo.branches

  Yuna has just watched the user give Mina a flower. The demo plays the
  bundled `07_crossroads.json` scenario (say nothing, apologize, kind words,
  or snap), shows what each character says in each branch, and compares
  where Yuna ends up.
  """
  @shortdoc "Runs the branched Aethrion scenario demo"

  use Mix.Task

  alias Aethrion.CLI.Display
  alias Aethrion.{Scenario, State}

  @scenario "07_crossroads.json"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    Aethrion.CLI.TaskArgs.parse!(args, [], "mix demo.branches", 0)
    Display.banner()

    path = Enum.find(Scenario.bundled(), &(Path.basename(&1) == @scenario))
    {:ok, scenario} = Scenario.load(path)
    {:ok, result} = Scenario.run(scenario)

    Display.heading(scenario.name, scenario.description)
    Display.message("Shared setup")
    print_steps(result.steps, scenario.state)

    Enum.each(result.branches, fn branch ->
      Display.heading("Branch: #{branch.name}", branch.description)

      branch.steps
      |> Enum.flat_map(& &1.log)
      |> Enum.filter(&String.match?(&1, ~r/^\[(Output|Scene|Event|Mood)\]/))
      |> Enum.each(&Display.log/1)
    end)

    print_comparison(result)
    :ok
  end

  defp print_steps(steps, initial) do
    Enum.reduce(steps, initial, fn step, before ->
      Display.event(step.event, before)
      Enum.each(step.log, &Display.log/1)
      step.state
    end)
  end

  defp print_comparison(result) do
    Display.heading("Where Yuna ends up")

    Display.message(
      "  " <>
        Enum.map_join(
          ["branch", "jealousy", "lonely", "trust->you", "tension->you", "lines to you"],
          "",
          &String.pad_trailing(&1, 14)
        )
    )

    Enum.each(result.branches, fn branch ->
      yuna = State.character(branch.state, "yuna").state
      to_user = State.get_relationship(branch.state, "yuna", "user")

      lines =
        Enum.count(branch.outputs, fn output ->
          output.type in [:proactive_message, :reply] and output[:character_id] == "yuna"
        end)

      Display.message(
        "  " <>
          Enum.map_join(
            [
              branch.name,
              yuna.jealousy,
              yuna.loneliness,
              to_user.trust,
              to_user.tension,
              lines
            ],
            "",
            &String.pad_trailing(to_string(&1), 14)
          )
      )
    end)
  end
end
