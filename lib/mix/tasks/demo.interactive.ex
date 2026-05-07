defmodule Mix.Tasks.Demo.Interactive do
  @moduledoc "Runs the interactive Aethrion CLI demo."
  @shortdoc "Runs the interactive Aethrion CLI demo"

  use Mix.Task

  alias Aethrion.CLI.Display
  alias Aethrion.CLI.CommandParser
  alias Aethrion.Runtime

  @impl Mix.Task
  def run(_args) do
    Display.banner()
    Display.message("Type help for commands, quit to exit.")

    Runtime.demo_state()
    |> print_status()
    |> loop()
  end

  defp loop(state) do
    case IO.gets(Display.prompt()) do
      :eof ->
        :ok

      {:error, reason} ->
        Display.message("Input error: #{inspect(reason)}")

      line ->
        line
        |> CommandParser.parse()
        |> handle_command(state)
    end
  end

  defp handle_command({:ok, :noop}, state), do: loop(state)

  defp handle_command({:ok, :quit}, _state) do
    Display.message("bye")
    :ok
  end

  defp handle_command({:ok, :help}, state) do
    Display.help()

    loop(state)
  end

  defp handle_command({:ok, :status}, state) do
    state
    |> print_status()
    |> loop()
  end

  defp handle_command({:ok, :memories}, state) do
    print_memories(state)
    loop(state)
  end

  defp handle_command({:ok, event}, state) when is_map(event) do
    case Runtime.dispatch(state, event) do
      {:ok, state, outputs, log} ->
        Enum.each(log, &Display.log/1)
        print_outputs(outputs)
        print_status(state)
        loop(state)

      {:error, error} ->
        Display.error(error)
        loop(state)
    end
  end

  defp handle_command({:error, message}, state) do
    Display.message("ERROR #{message}")
    loop(state)
  end

  defp print_status(state) do
    Display.status(state)
  end

  defp print_memories(state) do
    Display.memories(state.memories)
  end

  defp print_outputs(outputs) do
    Enum.each(outputs, &Display.output/1)
  end
end
