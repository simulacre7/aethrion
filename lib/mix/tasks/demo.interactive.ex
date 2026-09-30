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
  - `--effects` - also print every structured output.
  - `--no-status` - do not print the status tables after every event (use
    `status` to see them).
  """
  @shortdoc "Runs the interactive Aethrion CLI demo"

  use Mix.Task

  alias Aethrion.CLI.{CommandParser, Display}
  alias Aethrion.{Expression, Intent, Pipeline, Runtime, Scenario, State}
  alias Aethrion.LLM.{Anthropic, FakeAdapter, OpenAICompatible}
  alias Aethrion.Persistence.JsonFile

  @switches [llm: :string, effects: :boolean, status: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: @switches)

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
      effects?: Keyword.get(opts, :effects, false),
      status?: Keyword.get(opts, :status, true)
    }

    Display.message(
      "Type help for commands, quit to exit. Try: say yuna sorry I forgot about you"
    )

    if session.status?, do: Display.status(session.state)
    loop(session)
  end

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
        |> CommandParser.parse()
        |> handle(session)
    end
  end

  defp handle({:ok, :noop}, session), do: loop(session)

  defp handle({:ok, :quit}, _session) do
    Display.message("bye")
    :ok
  end

  defp handle({:ok, :help}, session) do
    Display.help()
    loop(session)
  end

  defp handle({:ok, :status}, session) do
    if session.status?, do: Display.status(session.state)
    loop(session)
  end

  defp handle({:ok, {:memories, character}}, session) do
    Display.memories(session.state, character)
    loop(session)
  end

  defp handle({:ok, {:why, character}}, session) do
    Display.explain(session.trace, character)
    loop(session)
  end

  defp handle({:ok, {:context, character}}, session) do
    case State.character(session.state, character) do
      nil ->
        Display.message("ERROR unknown character #{inspect(character)}")

      found ->
        reason = if found.state.mood == :jealous, do: :jealous, else: :lonely

        session.state
        |> Expression.build_request(:proactive_message, character, "user", reason: reason)
        |> Display.context()
    end

    loop(session)
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
    Display.status(previous.state)

    session |> Map.merge(previous) |> Map.put(:undo, rest) |> loop()
  end

  defp handle({:ok, {:save, path}}, session) do
    case JsonFile.save(session.state, path: path) do
      :ok -> Display.message("saved to #{path}")
      {:error, reason} -> Display.message("ERROR could not save: #{inspect(reason)}")
    end

    loop(session)
  end

  defp handle({:ok, {:record, path}}, session) do
    data = Scenario.record(session.origin, session.host_events, session.state, session.outputs)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(data, pretty: true)) do
      Display.message(
        "recorded #{length(session.host_events)} events and #{length(data["expect"])} expectations to #{path}. " <>
          "Replay with: mix aethrion.scenario #{path}"
      )
    else
      {:error, reason} -> Display.message("ERROR could not record: #{inspect(reason)}")
    end

    loop(session)
  end

  defp handle({:ok, {:load, path}}, session) do
    case JsonFile.load(path: path) do
      {:ok, state} ->
        Display.message("loaded #{path}")
        Display.status(state)

        loop(%{
          remember(session)
          | state: state,
            origin: state,
            host_events: [],
            outputs: []
        })

      {:error, reason} ->
        Display.message("ERROR could not load: #{inspect(reason)}")
        loop(session)
    end
  end

  defp handle({:ok, {:say, to, text}}, session) do
    case Intent.interpret(session.state, text, to: to, adapter: session.adapter || FakeAdapter) do
      {:ok, event, meta} ->
        source = if meta.status == :ok, do: inspect(meta.adapter), else: "fallback"

        Display.log(
          "[Intent] #{inspect(text)} -> #{event.type}" <>
            if(event[:tone], do: " (#{event.tone})", else: "") <> " via #{source}"
        )

        dispatch(session, event)

      {:error, error} ->
        Display.error(error)
        loop(session)
    end
  end

  defp handle({:ok, event}, session) when is_map(event), do: dispatch(session, event)

  defp handle({:error, message}, session) do
    Display.message("ERROR #{message}")
    loop(session)
  end

  defp dispatch(session, event) do
    case Runtime.step(session.state, event) do
      {:ok, step} ->
        Display.event(step.event, session.state)
        Enum.each(step.log, &Display.log/1)
        if session.effects?, do: Enum.each(step.outputs, &Display.output/1)

        if session.adapter do
          step.outputs
          |> Enum.filter(&Aethrion.Output.expressive?/1)
          |> Expression.render(adapter: session.adapter)
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
        Display.error(error)
        loop(session)
    end
  end

  defp remember(session) do
    snapshot = Map.take(session, [:state, :origin, :trace, :events, :host_events, :outputs])
    %{session | undo: Enum.take([snapshot | session.undo], 50)}
  end
end
