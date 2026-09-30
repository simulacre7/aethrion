defmodule Aethrion.CLI.Display do
  @moduledoc """
  ANSI presentation helpers for demo CLI output.
  """

  def banner do
    [
      [:bright, :cyan, "Aethrion", :reset, :faint, "  early alpha"],
      [:faint, "A shared social layer for persistent AI characters."],
      [:yellow, "LLMs generate expression; deterministic rules drive the simulation."],
      ""
    ]
    |> print_lines()
  end

  def help do
    print_lines([
      [:bright, "Commands"],
      "  gift <from> <to> <item>",
      "  gift <from> <to> <item> observed_by <character_id[,character_id]>",
      "  apologize <from> <to> <reason>",
      "  tick <hours>",
      "  status",
      "  memories",
      "  help",
      "  quit"
    ])
  end

  def prompt do
    IO.ANSI.format([:bright, :green, "user", :reset, :faint, "> "], true)
    |> IO.chardata_to_string()
  end

  def status(state) do
    print_section("Characters")

    print_lines([
      [:faint, "  name       mood       lonely  jealous"],
      [:faint, "  ---------  ---------  ------  -------"]
    ])

    state.characters
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.each(fn character ->
      print([
        "  ",
        pad(character.name, 9),
        pad(to_string(character.state.mood), 11),
        pad(to_string(character.state.loneliness), 8),
        to_string(character.state.jealousy)
      ])
    end)

    print_section("Relationships")

    print_lines([
      [:faint, "  edge         affinity  trust  tension"],
      [:faint, "  -----------  --------  -----  -------"]
    ])

    state.relationships
    |> Map.values()
    |> Enum.sort_by(&{&1.from, &1.to})
    |> Enum.each(fn relationship ->
      print([
        "  ",
        pad("#{relationship.from}->#{relationship.to}", 13),
        pad(to_string(relationship.affinity), 10),
        pad(to_string(relationship.trust), 7),
        to_string(relationship.tension)
      ])
    end)

    print("")

    state
  end

  def memories([]) do
    print_section("Memories")
    print([:faint, "  none"])
    print("")
  end

  def memories(memories) do
    print_section("Memories")

    memories
    |> Enum.reverse()
    |> Enum.each(fn memory ->
      print([
        "  ",
        :bright,
        memory.character_id,
        :reset,
        " remembers ",
        inspect(memory.content),
        :faint,
        " importance=#{memory.importance}"
      ])
    end)

    print("")
  end

  def event(event) do
    print_tagged("EVENT", :blue, Aethrion.Event.describe(event))
  end

  @log_tags %{
    "Rule" => {"RULE", :magenta},
    "State" => {"STATE", :yellow},
    "Relation" => {"RELATION", :yellow},
    "Mood" => {"MOOD", :light_yellow},
    "Memory" => {"MEMORY", :green},
    "Output" => {"OUTPUT", :cyan},
    "Scene" => {"SCENE", :light_magenta},
    "Event" => {"EVENT", :light_blue},
    "Cascade" => {"CASCADE", :red}
  }

  def log(line) do
    with [_, tag, message] <- Regex.run(~r/^\[([^\]]+)\]\s*(.*)$/s, line),
         {label, color} <- Map.get(@log_tags, tag) do
      print_tagged(label, color, message)
    else
      _ -> print(line)
    end
  end

  def output(%{type: :proactive_message, character_id: character_id, reason: reason}) do
    print_tagged("EFFECT", :cyan, "proactive_message #{character_id}->user reason=#{reason}")
  end

  def output(%{type: :reply, character_id: character_id, to: to}) do
    print_tagged("EFFECT", :cyan, "reply #{character_id}->#{to}")
  end

  def output(%{type: :character_interaction, kind: kind, from: from, to: to}) do
    print_tagged("EFFECT", :cyan, "character_interaction #{kind} #{from}->#{to}")
  end

  def output(%{type: :mood_changed, character_id: character_id, to: mood}) do
    print_tagged("EFFECT", :cyan, "mood_changed #{character_id} #{mood}")
  end

  def output(%{type: :relationship_changed, from: from, to: to, delta: delta}) do
    print_tagged("EFFECT", :cyan, "relationship_changed #{from}->#{to} #{inspect(delta)}")
  end

  def output(%{type: :memory_created, memory: memory}) do
    print_tagged("EFFECT", :cyan, "memory_created #{memory.id}")
  end

  def output(%{type: type}) do
    print_tagged("EFFECT", :cyan, to_string(type))
  end

  def error(error) do
    print([:red, :bright, "ERROR", :reset, " #{error.code}: #{error.message}"])
  end

  def message(message), do: print(message)

  defp print_section(title) do
    print(["\n\n", :bright, title])
  end

  defp print_tagged(tag, color, message) do
    print([color, :bright, pad(tag, 9), :reset, message])
  end

  defp print_lines(lines), do: Enum.each(lines, &print/1)

  defp print(chardata) do
    chardata
    |> IO.ANSI.format(true)
    |> IO.puts()
  end

  defp pad(value, width) do
    value <> String.duplicate(" ", max(width - String.length(value), 1))
  end
end
