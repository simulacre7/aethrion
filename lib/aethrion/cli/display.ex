defmodule Aethrion.CLI.Display do
  @moduledoc false
  # ANSI presentation helpers for the demo and scenario CLIs.

  alias Aethrion.{Event, Memory, State, Trace}
  alias Aethrion.Expression.Prompt

  @log_tags %{
    "Rule" => {"RULE", :magenta},
    "State" => {"STATE", :yellow},
    "Relation" => {"RELATION", :yellow},
    "Mood" => {"MOOD", :light_yellow},
    "Bond" => {"BOND", :light_yellow},
    "Memory" => {"MEMORY", :green},
    "Output" => {"SAYS", :cyan},
    "Scene" => {"SCENE", :light_magenta},
    "Event" => {"CASCADE", :light_blue},
    "Cascade" => {"DROPPED", :red},
    "Intent" => {"INTENT", :light_cyan},
    "LLM" => {"LLM", :light_cyan}
  }

  def banner do
    [
      [:bright, :cyan, "Aethrion", :reset, :faint, "  early alpha"],
      [:faint, "A shared social layer for persistent AI characters."],
      [:yellow, "LLMs generate expression; deterministic rules drive the simulation."],
      ""
    ]
    |> print_lines()
  end

  def heading(title, description \\ "") do
    print(["\n", :bright, :cyan, title])
    if description != "", do: print([:faint, wrap(description, 96)])
    print("")
  end

  def help do
    print_lines([
      [:bright, "Talk and act"],
      "  say <character> <text>                      free text; intent is interpreted, then dispatched",
      "  message <from> <to> <tone> <text> [observed_by a,b]",
      "                                              tone: warm | neutral | cold | hostile",
      "  gift <from> <to> <item> [observed_by a,b]",
      "  apologize <from> <to> <reason>",
      "  comfort <from> <to>",
      "  tick <hours>",
      "",
      [:bright, "Inspect"],
      "  status                                      characters and relationships",
      "  memories [character]                        what characters remember (faded ones dimmed)",
      "  why <character>                             every traced change to a character, by rule",
      "  why <character> <field>                     how one value got here, e.g. why yuna jealousy",
      "  why <from>-><to> <field>                    the same for a relationship, e.g. why yuna->haru trust",
      "  context <character>                         what an LLM would see for a proactive line",
      "  timeline                                    events dispatched this session",
      "  rules                                       the rule pipeline",
      "",
      [:bright, "Session"],
      "  undo                                        revert the last command",
      "  save <path> | load <path>                   world state as JSON",
      "  record <path>                               this session as a replayable scenario",
      "  report <path>                               this session as an HTML report",
      "  help | quit"
    ])
  end

  def prompt do
    IO.ANSI.format([:bright, :green, "user", :reset, :faint, "> "], true)
    |> IO.chardata_to_string()
  end

  def status(%State{} = state) do
    print_section("Characters", "clock #{state.clock}h")

    print_lines([
      [:faint, "  name       mood      lonely  jealous  joy  stress"],
      [:faint, "  ---------  --------  ------  -------  ---  ------"]
    ])

    state
    |> State.sorted_characters()
    |> Enum.each(fn character ->
      cs = character.state

      print([
        "  ",
        pad(character.name, 11),
        mood_color(cs.mood),
        pad(to_string(cs.mood), 10),
        :reset,
        pad(to_string(cs.loneliness), 8),
        pad(to_string(cs.jealousy), 9),
        pad(to_string(cs.joy), 5),
        to_string(cs.stress),
        flags(cs)
      ])
    end)

    print_section("Relationships")

    print_lines([
      [:faint, "  edge            affinity  trust  tension  bond"],
      [:faint, "  --------------  --------  -----  -------  ---------"]
    ])

    state.relationships
    |> Map.values()
    |> Enum.sort_by(&{&1.from, &1.to})
    |> Enum.each(fn relationship ->
      print([
        "  ",
        pad("#{relationship.from}->#{relationship.to}", 16),
        pad(to_string(relationship.affinity), 10),
        pad(to_string(relationship.trust), 7),
        pad(to_string(relationship.tension), 9),
        to_string(Aethrion.Rules.Bond.derive(relationship, state))
      ])
    end)

    print("")
    state
  end

  def memories(%State{} = state, character_id \\ nil) do
    print_section("Memories", "newest first")

    memories =
      Enum.filter(state.memories, &(is_nil(character_id) or &1.character_id == character_id))

    if memories == [] do
      print([:faint, "  none"])
    else
      Enum.each(memories, fn memory ->
        style = if Memory.faded?(memory), do: :faint, else: :normal
        source = if memory.source, do: " from #{State.name(state, memory.source)}", else: ""

        print([
          style,
          "  ",
          pad(State.name(state, memory.character_id), 8),
          pad("#{memory.kind}#{source}", 18),
          inspect(memory.content),
          :faint,
          "  strength #{memory.strength}/#{memory.importance}",
          if(Memory.faded?(memory), do: " (faded)", else: "")
        ])
      end)
    end

    print("")
  end

  def event(event, state \\ nil) do
    names = if state, do: &State.name(state, &1), else: &Function.identity/1
    print_tagged("EVENT", :blue, Event.describe(event, names))
  end

  def log(line) do
    with [_, tag, message] <- Regex.run(~r/^\[([^\]]+)\]\s*(.*)$/s, line),
         {label, color} <- Map.get(@log_tags, tag) do
      print_tagged(label, color, message)
    else
      _ -> print(line)
    end
  end

  def output(%{type: type} = output) do
    detail =
      case output do
        %{type: :relationship_changed, from: from, to: to, delta: delta} ->
          "#{from}->#{to} #{inspect(delta)}"

        %{type: :memory_created, memory: memory} ->
          memory.id

        %{type: :mood_changed, character_id: id, after: mood} ->
          "#{id} #{mood}"

        %{type: :bond_changed, from: from, to: to, after: bond} ->
          "#{from}->#{to} #{bond}"

        %{type: :character_interaction, kind: kind, character_id: id, to: to} ->
          "#{kind} #{id}->#{to}"

        %{character_id: id, to: to} ->
          "#{id}->#{to}" <> if(output[:reason], do: " reason=#{output.reason}", else: "")

        _ ->
          ""
      end

    print_tagged("EFFECT", :cyan, String.trim("#{type} #{detail}"))
  end

  @doc "Prints an output rendered by an expression adapter."
  def expressed(%{text: text, expression: expression} = output, label \\ "LLM") do
    speaker = output.character_id
    status = if expression.status == :ok, do: inspect(expression.adapter), else: "fallback"
    print_tagged(label, :light_cyan, "#{speaker}: \"#{text}\"" <> faint(" (#{status})"))
  end

  def explain(entries, character_id) do
    print_section("Why", "every traced change concerning #{character_id}")

    case Enum.filter(entries, &Trace.concerns?(&1, character_id)) do
      [] ->
        print([:faint, "  nothing yet"])

      entries ->
        entries
        |> Enum.reject(&(&1.kind == :output or &1.field == :last_active_at))
        |> Enum.each(&print(["  ", Trace.describe(&1)]))
    end

    print("")
  end

  def explain_value(label, changes, names) do
    print_section("Why", label)

    case Aethrion.Explain.describe(changes, names) do
      [] -> print([:faint, "  unchanged this session"])
      lines -> Enum.each(lines, &print(["  ", &1]))
    end

    print("")
  end

  def context(request) do
    print_section("Expression context", "the read-only snapshot an adapter receives")
    request |> Prompt.render_context() |> String.split("\n") |> Enum.each(&print(["  ", &1]))
    print("")
  end

  def timeline([]), do: print([:faint, "  no events yet"])

  def timeline(events) do
    print_section("Timeline")

    Enum.each(events, fn event ->
      print(["  ", :faint, pad(event.id, 5), :reset, Event.describe(event)])
    end)

    print("")
  end

  def rules(description) do
    Enum.each(description, fn {type, rules} ->
      print([:bright, if(type == :reactive, do: "after every event", else: to_string(type))])
      Enum.each(rules, fn {id, text} -> print(["  ", pad(to_string(id), 14), :faint, text]) end)
    end)

    print("")
  end

  def checks(checks) do
    print_section("Expectations")

    Enum.each(checks, fn check ->
      if check.passed? do
        print(["  ", :green, "pass ", :reset, check.description])
      else
        print([
          "  ",
          :red,
          "FAIL ",
          :reset,
          check.description,
          :faint,
          "  actual: #{inspect(check.actual)}"
        ])
      end
    end)

    passed = Enum.count(checks, & &1.passed?)
    color = if passed == length(checks), do: :green, else: :red
    print(["\n  ", color, :bright, "#{passed}/#{length(checks)} expectations met"])
    print("")
  end

  def error(error) do
    print([:red, :bright, "ERROR", :reset, " #{error.code}: #{Aethrion.Error.format(error)}"])
  end

  def message(message), do: print(message)

  defp print_section(title, note \\ nil) do
    print(["\n", :bright, title, :reset, :faint, if(note, do: "  #{note}", else: "")])
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

  defp faint(text), do: IO.ANSI.format([:faint, text], true) |> IO.chardata_to_string()

  defp mood_color(:happy), do: :green
  defp mood_color(:jealous), do: :red
  defp mood_color(:lonely), do: :blue
  defp mood_color(:upset), do: :magenta
  defp mood_color(_mood), do: :normal

  defp flags(cs) do
    [if(cs.blocked?, do: " blocked"), if(not cs.active?, do: " inactive")]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      flags -> IO.ANSI.format([:faint | flags], true) |> IO.chardata_to_string()
    end
  end

  defp wrap(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce([""], fn word, [line | rest] ->
      if String.length(line) + String.length(word) + 1 > width,
        do: [word, line | rest],
        else: [String.trim_leading(line <> " " <> word) | rest]
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  defp pad(value, width) do
    value <> String.duplicate(" ", max(width - String.length(value), 1))
  end
end
