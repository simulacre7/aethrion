defmodule Aethrion.CLI.Display do
  @moduledoc """
  ANSI presentation helpers for demo CLI output.
  """

  def banner do
    [
      [:bright, :cyan, "Aethrion", :reset, :faint, "  early alpha"],
      [:faint, "A shared social layer for persistent AI characters."],
      [:yellow, "LLMs express the drama, but deterministic state creates it."],
      ""
    ]
    |> print_lines()
  end

  def help do
    print_lines([
      [:bright, "Commands"],
      "  gift <from> <to> <item>",
      "  gift <from> <to> <item> observed_by <character_id[,character_id]>",
      "  tick <hours>",
      "  status",
      "  memories",
      "  help",
      "  quit"
    ])
  end

  def prompt do
    IO.ANSI.format([:bright, :cyan, "aethrion", :reset, :faint, "> "], true)
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

    state
  end

  def memories([]) do
    print_section("Memories")
    print([:faint, "  none"])
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
  end

  def event(%{type: :gift_received, from: from, to: to, item: item}) do
    print_tagged("EVENT", :blue, "#{from} gives #{to} a #{item}")
  end

  def event(%{type: :time_tick, hours: hours}) do
    print_tagged("EVENT", :blue, "time passes +#{hours}h")
  end

  def log(line) do
    cond do
      String.starts_with?(line, "[Rule]") ->
        print_tagged("RULE", :magenta, trim_tag(line))

      String.starts_with?(line, "[State]") ->
        print_tagged("STATE", :yellow, trim_tag(line))

      String.starts_with?(line, "[Memory]") ->
        print_tagged("MEMORY", :green, trim_tag(line))

      String.starts_with?(line, "[Output]") ->
        print_tagged("OUTPUT", :cyan, trim_tag(line))

      true ->
        print(line)
    end
  end

  def output(%{type: :proactive_message, character_id: character_id, reason: reason}) do
    print_tagged("EFFECT", :cyan, "proactive_message #{character_id}->user reason=#{reason}")
  end

  def output(%{type: :relationship_changed, from: from, to: to, delta: delta}) do
    print_tagged("EFFECT", :cyan, "relationship_changed #{from}->#{to} #{inspect(delta)}")
  end

  def output(%{type: :memory_created, memory: memory}) do
    print_tagged("EFFECT", :cyan, "memory_created #{memory.id}")
  end

  def error(error) do
    print([:red, :bright, "ERROR", :reset, " #{error.code}: #{error.message}"])
  end

  def message(message), do: print(message)

  defp print_section(title) do
    print(["\n", :bright, title])
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

  defp trim_tag(line) do
    String.replace(line, ~r/^\[[^\]]+\]\s*/, "")
  end

  defp pad(value, width) do
    value <> String.duplicate(" ", max(width - String.length(value), 1))
  end
end
