defmodule Aethrion.CLI.Display do
  @moduledoc false
  # ANSI presentation helpers for the demo and scenario CLIs.

  alias Aethrion.{Event, Memories, Memory, State, Trace}
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

  def help(locale \\ :en)

  def help(:ko) do
    print_lines([
      [:bright, "말하고 행동하기"],
      "  say <캐릭터> <말>                           자유 입력; 의도를 해석해서 이벤트로 보냅니다",
      "  message <누가> <누구에게> <tone> <말> [observed_by a,b]",
      "                                              tone: warm(다정하게) | neutral(담담하게) | cold(차갑게) | hostile(모질게)",
      "  gift <누가> <누구에게> <물건> [observed_by a,b]",
      "  apologize <누가> <누구에게> <이유> [observed_by a,b]",
      "  comfort <누가> <누구를>",
      "  tick <시간>                                 시간을 흘려보냅니다",
      "  here [a,b | none]                           곁에 있는 캐릭터; 당신이 하는 말과 행동을 목격합니다",
      "",
      [:bright, "살펴보기"],
      "  status                                      캐릭터와 관계",
      "  memories [캐릭터]                           캐릭터가 기억하는 것 (희미해진 기억은 흐리게)",
      "  why <캐릭터> [필드]                          값이 어떻게 여기까지 왔는지, 예: why yuna jealousy",
      "  why <누가>-><누구> <필드>                    관계에 대해서도, 예: why yuna->haru trust",
      "  context <캐릭터>                            먼저 연락할 때 LLM이 보게 될 맥락",
      "  opinion <캐릭터> <상대>                      한 사람이 다른 사람을 어떻게 보는지",
      "  timeline                                    이번 세션의 이벤트",
      "  digest                                      지난 요약 이후 달라진 것",
      "  rules                                       규칙 파이프라인",
      "",
      [:bright, "세션"],
      "  undo                                        마지막 명령 되돌리기",
      "  save <경로> | load <경로>                    세계 상태를 JSON으로",
      "  record <경로>                               이 세션을 다시 재생할 수 있는 시나리오로",
      "  report <경로>                               이 세션을 HTML 리포트로",
      "  help | quit (또는 exit)",
      "",
      [:faint, "명령마다 나오는 표를 숨기려면 --no-status로 시작하세요."],
      [:faint, "캐릭터 이름은 대소문자와 상관없이 쓸 수 있고, 데모 캐스트는 한글 이름(미나, 유나, 하루)으로도 부를 수 있습니다."],
      [:faint, "대사·사건·요약은 한국어(KO)로 함께 보여 주고, 규칙 로그와 살펴보기 표는 개발용이라 영어로 둡니다."]
    ])
  end

  def help(_en) do
    print_lines([
      [:bright, "Talk and act"],
      "  say <character> <text>                      free text; intent is interpreted, then dispatched",
      "  message <from> <to> <tone> <text> [observed_by a,b]",
      "                                              tone: warm | neutral | cold | hostile",
      "  gift <from> <to> <item> [observed_by a,b]",
      "  apologize <from> <to> <reason> [observed_by a,b]",
      "  comfort <from> <to>",
      "  tick <hours>",
      "  here [a,b | none]                           who else is present; they witness what you say and do",
      "",
      [:bright, "Inspect"],
      "  status                                      characters and relationships",
      "  memories [character]                        what characters remember (faded ones dimmed)",
      "  why <character>                             every traced change to a character, by rule",
      "  why <character> <field>                     how one value got here, e.g. why yuna jealousy",
      "  why <from>-><to> <field>                    the same for a relationship, e.g. why yuna->haru trust",
      "                                              (field: affinity | trust | tension | bond)",
      "  context <character>                         what an LLM would see for a proactive line",
      "  opinion <character> <other>                 how one sees another: bond, beliefs, memories",
      "  timeline                                    events dispatched this session",
      "  digest                                      what changed socially since the last digest",
      "  rules                                       the rule pipeline",
      "",
      [:bright, "Session"],
      "  undo                                        revert the last command",
      "  save <path> | load <path>                   world state as JSON",
      "  record <path>                               this session as a replayable scenario",
      "  report <path>                               this session as an HTML report",
      "  help | quit (or exit)",
      "",
      [:faint, "Start with --no-status to hide the tables after each command."],
      [:faint, "Character names work in any case, by id or display name."]
    ])
  end

  def prompt do
    IO.ANSI.format([:bright, :green, "user", :reset, :faint, "> "], color?())
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

  def event(event, state \\ nil, locale \\ nil) do
    names = if state, do: &State.name(state, &1), else: &Function.identity/1
    print_tagged("EVENT", :blue, Event.describe(event, names))

    if locale == :ko do
      ko_names = fn
        "user" -> "너"
        id -> names.(id)
      end

      print_tagged(
        "KO",
        :light_cyan,
        Aethrion.Expression.Templates.Ko.describe_event(event, ko_names)
      )
    end
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
    speaker =
      case output do
        %{context: %{speaker: %{name: name}}} when is_binary(name) -> name
        _other -> output.character_id
      end

    status =
      case expression do
        %{status: :ok} -> inspect(expression.adapter)
        %{reason: :silence} -> "silent"
        _fallback -> "fallback"
      end

    # Scenes are narration, not something the speaker says.
    line =
      if Map.get(output, :type) == :character_interaction,
        do: text,
        else: "#{speaker}: \"#{text}\""

    print_tagged(label, :light_cyan, line <> faint(" (#{status})"))
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

  def opinion(%State{} = state, from, to) do
    relationship = State.get_relationship(state, from, to)
    bond = Aethrion.Rules.Bond.derive(relationship, state)

    {beliefs, memories} =
      state |> Memories.about(from, to) |> Enum.split_with(&(&1.kind == :impression))

    print_section("Opinion", "how #{State.name(state, from)} sees #{State.name(state, to)}")

    print([
      "  ",
      pad("bond", 11),
      :bright,
      pad(to_string(bond), 11),
      :reset,
      :faint,
      "affinity #{relationship.affinity}, trust #{relationship.trust}, tension #{relationship.tension}"
    ])

    last_talked =
      case State.hours_since(state, Aethrion.Rules.Reply.contact_key(from, to)) do
        nil -> "never"
        hours -> "#{hours} hours ago"
      end

    print(["  ", pad("#{to} wrote", 11), :faint, last_talked])

    opinion_lines("believes", beliefs, fn memory ->
      scope = if memory.data["event"] == "reputation", do: "reputation", else: "firsthand"
      [memory.content, :faint, "  (#{scope})"]
    end)

    opinion_lines("remembers", Enum.take(memories, 5), fn memory ->
      source = if memory.source, do: " from #{State.name(state, memory.source)}", else: ""
      [memory.content, :faint, "  (#{memory.kind}#{source})"]
    end)

    print("")
  end

  defp opinion_lines(label, [], _line), do: print(["  ", pad(label, 11), :faint, "nothing"])

  defp opinion_lines(label, memories, line) do
    memories
    |> Enum.with_index()
    |> Enum.each(fn {memory, index} ->
      print(["  ", pad(if(index == 0, do: label, else: ""), 11) | line.(memory)])
    end)
  end

  def digest(items, note \\ "what changed since the last digest", locale \\ :en) do
    {title, empty} =
      if locale == :ko,
        do: {"요약", "  이야기할 만한 일이 없었습니다"},
        else: {"Digest", "  nothing worth mentioning"}

    print_section(title, note)

    case items do
      [] -> print([:faint, empty])
      items -> Enum.each(items, &print(["  ", &1.text]))
    end

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
      Enum.each(rules, fn {id, text} -> print(["  ", pad(to_string(id), 16), :faint, text]) end)
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

  @doc """
  Whether to color output: never with `NO_COLOR` set (https://no-color.org),
  always with `FORCE_COLOR` set (for recordings), otherwise only on a
  terminal.
  """
  def color? do
    cond do
      System.get_env("NO_COLOR") not in [nil, ""] -> false
      System.get_env("FORCE_COLOR") not in [nil, "", "0"] -> true
      true -> IO.ANSI.enabled?()
    end
  end

  defp print_section(title, note \\ nil) do
    print(["\n", :bright, title, :reset, :faint, if(note, do: "  #{note}", else: "")])
  end

  defp print_tagged(tag, color, message) do
    print([color, :bright, pad(tag, 9), :reset, message])
  end

  defp print_lines(lines), do: Enum.each(lines, &print/1)

  defp print(chardata) do
    chardata
    |> IO.ANSI.format(color?())
    |> IO.puts()
  end

  defp faint(text), do: IO.ANSI.format([:faint, text], color?()) |> IO.chardata_to_string()

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
      flags -> IO.ANSI.format([:faint | flags], color?()) |> IO.chardata_to_string()
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
