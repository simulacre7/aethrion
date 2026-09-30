defmodule Mix.Tasks.Aethrion.Rules do
  @shortdoc "Prints the default rule pipeline"

  @moduledoc """
  Prints which rules run for each event type, in order, with their
  descriptions and tunable parameters (see `Aethrion.Tuning`).

      mix aethrion.rules
  """

  use Mix.Task

  alias Aethrion.Pipeline

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    params = Map.new(Aethrion.Tuning.describe(Aethrion.State.new()))

    for {type, rules} <- Pipeline.describe(Pipeline.default()) do
      heading =
        if type == :reactive,
          do: "after every event (reactive)",
          else: to_string(type)

      Mix.shell().info(
        IO.ANSI.format([:bright, heading], Aethrion.CLI.Display.color?())
        |> IO.chardata_to_string()
      )

      rules
      |> Enum.with_index(1)
      |> Enum.each(fn {{id, description}, index} ->
        Mix.shell().info("  #{index}. #{String.pad_trailing(to_string(id), 14)} #{description}")

        case Map.get(params, id) do
          nil ->
            :ok

          values ->
            line =
              Enum.map_join(values, ", ", fn {key, default, _current} -> "#{key}=#{default}" end)

            Mix.shell().info(
              IO.ANSI.format([:faint, "     params: ", line], Aethrion.CLI.Display.color?())
              |> IO.chardata_to_string()
            )
        end
      end)

      Mix.shell().info("")
    end
  end
end
