defmodule Mix.Tasks.Demo.Interactive do
  @moduledoc """
  Runs the interactive Aethrion CLI demo.

      mix demo.interactive
      mix demo.interactive --llm anthropic
      mix demo.interactive --llm openai
      mix demo.interactive --effects

  Options:

  - `--llm anthropic|openai` - render character lines and interpret `say`
    through a real model (see `Aethrion.LLM.Anthropic` and
    `Aethrion.LLM.OpenAICompatible` for configuration). Without it, the
    deterministic fake adapter is used. The simulation is identical either way.
  - `--locale ko` - also show every character line rendered with the Korean
    templates, and describe events in Korean; with `--llm`, the model writes
    in Korean. The simulation is identical in every language.
  - `--effects` - also print every structured output.
  - `--no-status` - do not print the status tables after every event (use
    `status` to see them).

  `here haru,yuna` puts characters in the room: they witness every gift,
  message, and apology that does not name its own witnesses (`here none` clears it).
  """
  @shortdoc "Runs the interactive Aethrion CLI demo"

  use Mix.Task

  alias Aethrion.CLI.{CommandParser, Display}
  alias Aethrion.{Expression, Intent, Pipeline, Runtime, Scenario, State}
  alias Aethrion.LLM.{Anthropic, FakeAdapter, OpenAICompatible}
  alias Aethrion.Persistence.JsonFile

  @switches [llm: :string, effects: :boolean, status: :boolean, locale: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _paths} =
      Aethrion.CLI.TaskArgs.parse!(
        args,
        @switches,
        "mix demo.interactive [--llm anthropic|openai] [--locale ko] [--no-status] [--effects]",
        0
      )

    # Read and write UTF-8 even when the shell's locale does not say so, so
    # Korean (or any non-ASCII) input is not mangled.
    :io.setopts(:standard_io, encoding: :unicode)

    Display.banner()

    session = %{
      state: Runtime.demo_state(),
      origin: "demo",
      undo: [],
      trace: [],
      events: [],
      host_events: [],
      outputs: [],
      adapter: adapter(opts[:llm]),
      locale: locale(opts[:locale]),
      present: [],
      digested: 0,
      hinted?: false,
      effects?: Keyword.get(opts, :effects, false),
      status?: Keyword.get(opts, :status, true)
    }

    Display.message(
      if session.locale == :ko,
        do: "help로 명령어 보기, quit으로 종료. 이렇게 해 보세요: say yuna 잊어서 미안해",
        else: "Type help for commands, quit to exit. Try: say yuna sorry I forgot about you"
    )

    if session.status?, do: Display.status(session.state)
    loop(session)
  end

  # A real model writes in the session's language.
  defp adapter_opts(%{locale: :ko}), do: [language: "Korean"]
  defp adapter_opts(_session), do: []

  defp locale(nil), do: nil
  defp locale("ko"), do: :ko
  defp locale("en"), do: nil
  defp locale(other), do: Mix.raise("unknown --locale #{inspect(other)}; use ko or en")

  defp adapter(nil), do: nil

  defp adapter(name) do
    module =
      case name do
        "anthropic" -> Anthropic
        "openai" -> OpenAICompatible
        other -> Mix.raise("unknown --llm #{inspect(other)}; use anthropic or openai")
      end

    if module.configured?() do
      Display.message("Expression adapter: #{inspect(module)}")
      module
    else
      Display.message(
        "#{inspect(module)} is not configured; using the deterministic fake adapter. " <>
          "See its module docs for environment variables."
      )

      nil
    end
  end

  defp loop(session) do
    case IO.gets(Display.prompt()) do
      :eof ->
        :ok

      {:error, reason} ->
        Display.message("Input error: #{inspect(reason)}")

      line ->
        line
        |> CommandParser.parse(&resolve(session.state, &1))
        |> handle(session)
    end
  end

  defp handle({:ok, :noop}, session), do: loop(session)

  defp handle({:ok, :quit}, _session) do
    Display.message("bye")
    :ok
  end

  defp handle({:ok, :help}, session) do
    Display.help(session.locale || :en)
    loop(session)
  end

  defp handle({:ok, :status}, session) do
    Display.status(session.state)
    loop(session)
  end

  defp handle({:ok, {:memories, character}}, session) when is_binary(character) do
    with_character(session, character, fn -> Display.memories(session.state, character) end)
  end

  defp handle({:ok, {:memories, nil}}, session) do
    Display.memories(session.state, nil)
    loop(session)
  end

  defp handle({:ok, {:why, character}}, session) do
    with_character(session, character, fn -> Display.explain(session.trace, character) end)
  end

  defp handle({:ok, {:why, {from, _to}, _field} = command}, session) do
    with_character(session, from, fn -> why(command, session) end)
  end

  defp handle({:ok, {:why, character, _field} = command}, session) do
    with_character(session, character, fn -> why(command, session) end)
  end

  defp handle({:ok, {:context, character}}, session) do
    case State.character(session.state, character) do
      nil ->
        unknown_character(session.state, [character])

      found ->
        reason = if found.state.mood == :jealous, do: :jealous, else: :lonely

        session.state
        |> Expression.build_request(:proactive_message, character, "user", reason: reason)
        |> Display.context()
    end

    loop(session)
  end

  defp handle({:ok, {:opinion, character, other}}, session) do
    if State.character?(session.state, character),
      do: Display.opinion(session.state, character, other),
      else: unknown_character(session.state, [character])

    loop(session)
  end

  defp handle({:ok, :digest}, session) do
    since = Enum.drop(session.outputs, session.digested)

    since
    |> Aethrion.Digest.of(session.state, locale: session.locale || :en)
    |> Display.digest(
      if(session.locale == :ko,
        do: "지난 요약 이후 달라진 것",
        else: "what changed since the last digest"
      ),
      session.locale || :en
    )

    loop(%{session | digested: length(session.outputs)})
  end

  defp handle({:ok, :timeline}, session) do
    Display.timeline(Enum.reverse(session.events))
    loop(session)
  end

  defp handle({:ok, :rules}, session) do
    Display.rules(Pipeline.describe(Pipeline.default()))
    loop(session)
  end

  defp handle({:ok, :undo}, %{undo: []} = session) do
    Display.message("nothing to undo")
    loop(session)
  end

  defp handle({:ok, :undo}, %{undo: [previous | rest]} = session) do
    Display.message("undone")
    if session.status?, do: Display.status(previous.state)

    # What was already digested stays digested.
    digested = min(session.digested, length(previous.outputs))
    session |> Map.merge(previous) |> Map.merge(%{undo: rest, digested: digested}) |> loop()
  end

  defp handle({:ok, {:save, path}}, session) do
    case JsonFile.save(session.state, path: path) do
      :ok -> Display.message("saved to #{path}")
      {:error, error} -> show_error(session.state, error)
    end

    loop(session)
  end

  defp handle({:ok, {:record, path}}, session) do
    data = Scenario.record(session.origin, session.host_events, session.state, session.outputs)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(data, pretty: true)) do
      Display.message(
        "recorded #{count(length(session.host_events), "event")} and " <>
          "#{count(length(data["expect"]), "expectation")} to #{path}. " <>
          "Replay with: mix aethrion.scenario #{path}"
      )
    else
      {:error, reason} -> Display.message("ERROR could not record: #{:file.format_error(reason)}")
    end

    loop(session)
  end

  defp handle({:ok, {:report, path}}, session) do
    data =
      Scenario.record(session.origin, session.host_events, session.state, session.outputs,
        name: "Interactive session",
        description: "#{length(session.host_events)} events from mix demo.interactive."
      )

    with {:ok, scenario} <- Scenario.from_data(Jason.decode!(Jason.encode!(data))),
         {:ok, result} <- Scenario.run(scenario),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Aethrion.Report.html(result, locale: session.locale || :en)) do
      Display.message("wrote #{path}")
    else
      {:error, %Aethrion.Error{} = error} -> show_error(session.state, error)
      {:error, reason} -> Display.message("ERROR could not write report: #{:file.format_error(reason)}")
    end

    loop(session)
  end

  defp handle({:ok, {:load, path}}, session) do
    case JsonFile.load(path: path) do
      {:ok, %State{characters: characters}} when map_size(characters) == 0 ->
        Display.message(
          "ERROR #{path} has no characters. If it is a recorded scenario, replay it with: " <>
            "mix aethrion.scenario #{path}"
        )

        loop(session)

      {:ok, state} ->
        Display.message("loaded #{path}")
        if session.status?, do: Display.status(state)

        loop(%{
          remember(session)
          | state: state,
            origin: state,
            trace: [],
            events: [],
            host_events: [],
            outputs: [],
            digested: 0
        })

      {:error, error} ->
        show_error(session.state, error)
        loop(session)
    end
  end

  defp handle({:ok, {:say, to, text}}, session) do
    case Intent.interpret(session.state, text,
           to: to,
           at: "interactive:say",
           adapter: session.adapter || FakeAdapter
         ) do
      {:ok, event, meta} ->
        source = if meta.status == :ok, do: inspect(meta.adapter), else: "fallback"

        Display.log(
          "[Intent] #{inspect(text)} -> #{event.type}" <>
            if(event[:tone], do: " (#{event.tone})", else: "") <> " via #{source}"
        )

        # The fake adapter only guesses from keywords; say so once.
        if is_nil(session.adapter) and event.type == :message_sent and not session.hinted? do
          Display.message(
            if session.locale == :ko,
              do:
                "  (키워드로 추측한 말투입니다. 정확히 정하려면: message user #{to} <warm|neutral|cold|hostile> <말>)",
              else:
                "  (a keyword guess; for an exact tone use: message user #{to} <warm|neutral|cold|hostile> <text>)"
          )
        end

        dispatch(%{session | hinted?: session.hinted? or event.type == :message_sent}, event)

      {:error, error} ->
        show_error(session.state, error)
        loop(session)
    end
  end

  defp handle({:ok, {:here, :show}}, session) do
    Display.message(present_line(session.state, session.present))
    loop(session)
  end

  defp handle({:ok, {:here, characters}}, session) do
    case Enum.reject(characters, &State.character?(session.state, &1)) do
      [] ->
        present = Enum.uniq(characters)
        Display.message(present_line(session.state, present))
        loop(%{session | present: present})

      unknown ->
        unknown_character(session.state, unknown)
        loop(session)
    end
  end

  defp handle({:ok, event}, session) when is_map(event), do: dispatch(session, event)

  defp handle({:error, message}, session) do
    Display.message("ERROR #{message}")
    loop(session)
  end

  defp why({:why, target, field}, session) do
    events = Enum.reverse(session.events)
    names = &State.name(session.state, &1)

    {label, changes} =
      case target do
        {from, to} ->
          {"#{from}->#{to}.#{field}",
           Aethrion.Explain.relationship(session.trace, events, from, to, field)}

        character ->
          {"#{character}.#{field}",
           Aethrion.Explain.character(session.trace, events, character, field)}
      end

    Display.explain_value(label, changes, names)
  end

  defp with_character(session, id, show) do
    if State.character?(session.state, id),
      do: show.(),
      else: unknown_character(session.state, [id])

    loop(session)
  end

  # Names are matched without case, by id or display name, and the demo cast
  # answers to its Korean names too.
  @korean_names %{"미나" => "mina", "유나" => "yuna", "하루" => "haru"}

  defp resolve(state, typed) do
    key = String.downcase(typed)
    korean = @korean_names[typed]

    cond do
      State.character?(state, typed) -> typed
      id = Enum.find(Map.keys(state.characters), &(String.downcase(&1) == key)) -> id
      id = by_name(state, key) -> id
      State.character?(state, korean) -> korean
      true -> typed
    end
  end

  defp by_name(state, key) do
    Enum.find_value(state.characters, fn {id, character} ->
      if String.downcase(character.name) == key, do: id
    end)
  end

  defp show_error(state, %Aethrion.Error{code: :unknown_character, details: %{character_id: id}})
       when is_binary(id),
       do: unknown_character(state, [id])

  defp show_error(_state, error), do: Display.error(error)

  defp unknown_character(state, names) do
    ids = state.characters |> Map.keys() |> Enum.sort()

    guess =
      names
      |> Enum.flat_map(fn name ->
        ids
        |> Enum.filter(&(String.jaro_distance(&1, String.downcase(name)) >= 0.75))
        |> Enum.take(1)
      end)

    hint = if guess == [], do: "", else: " Did you mean #{Enum.join(guess, ", ")}?"

    Display.message(
      "ERROR unknown character #{Enum.map_join(names, ", ", &inspect/1)}." <>
        hint <> " Characters: #{Enum.join(ids, ", ")}."
    )
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  defp present_line(_state, []), do: "nobody else is here"

  defp present_line(state, present) do
    "present: #{Enum.map_join(present, ", ", &State.name(state, &1))} " <>
      "(they witness what is said and given)"
  end

  # Characters who are present witness gifts and messages that do not name
  # their own witnesses.
  defp with_witnesses(%{type: type} = event, [_ | _] = present)
       when type in [:gift_received, :message_sent, :apology_offered] do
    case Map.get(event, :observed_by, []) do
      [] -> Map.put(event, :observed_by, present -- [event.from, event.to])
      _named -> event
    end
  end

  defp with_witnesses(event, _present), do: event

  # With --locale ko and no model, each line is followed by its Korean
  # rendering: every expressive output logs one [Output] or [Scene] line, in
  # the same order.
  defp translations(step, %{adapter: nil, locale: locale}) when locale != nil do
    step.outputs
    |> Enum.filter(&Aethrion.Output.expressive?/1)
    |> Expression.render(adapter: FakeAdapter, adapter_opts: [locale: locale])
  end

  defp translations(_step, _session), do: []

  defp log_line(line, [next | rest] = translated) do
    Display.log(line)

    if String.starts_with?(line, ["[Output]", "[Scene]"]) do
      Display.expressed(next, "KO")
      rest
    else
      translated
    end
  end

  defp log_line(line, []) do
    Display.log(line)
    []
  end

  defp dispatch(session, event) do
    event = with_witnesses(event, session.present)

    case Runtime.step(session.state, event) do
      {:ok, step} ->
        Display.event(step.event, session.state, session.locale)
        translated = translations(step, session)
        rest = Enum.reduce(step.log, translated, &log_line/2)
        Enum.each(rest, &Display.expressed(&1, "KO"))
        if session.effects?, do: Enum.each(step.outputs, &Display.output/1)

        if session.adapter do
          step.outputs
          |> Enum.filter(&Aethrion.Output.expressive?/1)
          |> Expression.render(adapter: session.adapter, adapter_opts: adapter_opts(session))
          |> Enum.each(&Display.expressed/1)
        end

        if session.status?, do: Display.status(step.state)

        session
        |> remember()
        |> Map.merge(%{
          state: step.state,
          trace: session.trace ++ step.trace,
          events: Enum.reverse(step.events, session.events),
          host_events: session.host_events ++ [event],
          outputs: session.outputs ++ step.outputs
        })
        |> loop()

      {:error, error} ->
        show_error(session.state, error)
        loop(session)
    end
  end

  defp remember(session) do
    snapshot =
      Map.take(session, [:state, :origin, :trace, :events, :host_events, :outputs])
    %{session | undo: Enum.take([snapshot | session.undo], 50)}
  end
end
