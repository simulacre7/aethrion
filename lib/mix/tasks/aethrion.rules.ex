defmodule Mix.Tasks.Aethrion.Rules do
  @shortdoc "Prints the default rule pipeline"

  @moduledoc """
  Prints which rules run for each event type, in order, with their
  descriptions.

      mix aethrion.rules
  """

  use Mix.Task

  alias Aethrion.Pipeline

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    for {type, rules} <- Pipeline.describe(Pipeline.default()) do
      heading =
        if type == :reactive,
          do: "after every event (reactive)",
          else: to_string(type)

      Mix.shell().info(IO.ANSI.format([:bright, heading], true) |> IO.chardata_to_string())

      rules
      |> Enum.with_index(1)
      |> Enum.each(fn {{id, description}, index} ->
        Mix.shell().info("  #{index}. #{String.pad_trailing(to_string(id), 14)} #{description}")
      end)

      Mix.shell().info("")
    end
  end
end
