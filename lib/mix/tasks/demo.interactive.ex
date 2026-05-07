defmodule Mix.Tasks.Demo.Interactive do
  @moduledoc "Runs the interactive Aethrion CLI demo."
  @shortdoc "Runs the interactive Aethrion CLI demo"

  use Mix.Task

  alias Aethrion.CLI.CommandParser
  alias Aethrion.Runtime

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("Aethrion interactive demo")
    Mix.shell().info("Type help for commands, quit to exit.\n")

    Runtime.demo_state()
    |> print_status()
    |> loop()
  end

  defp loop(state) do
    case IO.gets("> ") do
      :eof ->
        :ok

      {:error, reason} ->
        Mix.shell().error("Input error: #{inspect(reason)}")

      line ->
        line
        |> CommandParser.parse()
        |> handle_command(state)
    end
  end

  defp handle_command({:ok, :noop}, state), do: loop(state)

  defp handle_command({:ok, :quit}, _state) do
    Mix.shell().info("bye")
    :ok
  end

  defp handle_command({:ok, :help}, state) do
    Mix.shell().info("""
    Commands:
      gift <from> <to> <item>
      gift <from> <to> <item> observed_by <character_id[,character_id]>
      tick <hours>
      status
      memories
      help
      quit
    """)

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
        Enum.each(log, fn line -> Mix.shell().info(line) end)
        print_outputs(outputs)
        print_status(state)
        loop(state)

      {:error, error} ->
        Mix.shell().error("[Error] #{error.code}: #{error.message}")
        loop(state)
    end
  end

  defp handle_command({:error, message}, state) do
    Mix.shell().error("[Error] #{message}")
    loop(state)
  end

  defp print_status(state) do
    Mix.shell().info("[Status]")

    state.characters
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.each(fn character ->
      Mix.shell().info(
        "  #{character.name}: mood=#{character.state.mood} loneliness=#{character.state.loneliness} jealousy=#{character.state.jealousy}"
      )
    end)

    Mix.shell().info("[Relationships]")

    state.relationships
    |> Map.values()
    |> Enum.sort_by(&{&1.from, &1.to})
    |> Enum.each(fn relationship ->
      Mix.shell().info(
        "  #{relationship.from}->#{relationship.to}: affinity=#{relationship.affinity} trust=#{relationship.trust} tension=#{relationship.tension}"
      )
    end)

    state
  end

  defp print_memories(state) do
    Mix.shell().info("[Memories]")

    if state.memories == [] do
      Mix.shell().info("  none")
    else
      state.memories
      |> Enum.reverse()
      |> Enum.each(fn memory ->
        Mix.shell().info(
          "  #{memory.character_id}: #{memory.content} importance=#{memory.importance}"
        )
      end)
    end
  end

  defp print_outputs(outputs) do
    Enum.each(outputs, fn
      %{type: :proactive_message, character_id: character_id, reason: reason, text: text} ->
        Mix.shell().info("[Output] #{character_id} -> user reason=#{reason}: \"#{text}\"")

      %{type: :relationship_changed, from: from, to: to, delta: delta} ->
        Mix.shell().info("[Output] relationship_changed #{from}->#{to} #{inspect(delta)}")

      %{type: :memory_created, memory: memory} ->
        Mix.shell().info("[Output] memory_created #{memory.id}")
    end)
  end
end
