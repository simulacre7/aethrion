defmodule Mix.Tasks.Aethrion.Serve do
  @shortdoc "Serves worlds over a JSON HTTP API"

  @moduledoc """
  Runs `Aethrion.Worlds` behind `Aethrion.API`, so a game or chat backend in
  any language can use Aethrion over HTTP. Each world key (a user, a save
  slot) gets its own world, started from the cast and journaled under
  `--data`, so worlds survive restarts.

      mix aethrion.serve
      mix aethrion.serve --cast priv/casts/cafe.json --data data/worlds --port 4848
      AETHRION_TOKEN=secret mix aethrion.serve --llm anthropic --locale ko

  Then, for example:

      curl -s localhost:4848/worlds/alice/say -H 'content-type: application/json' \\
        -d '{"to": "mina", "text": "Good morning!"}'

  Options:

  - `--cast FILE` - the starting world, as state data (`characters`,
    `relationships`, `people`; the format `Aethrion.State.to_data/1` writes);
    default: the demo cast
  - `--data DIR` - where each world's journal is kept (default `tmp/worlds`)
  - `--port N` (default 4848), `--bind ADDRESS` (default `127.0.0.1`)
  - `--token TOKEN` - require `Authorization: Bearer TOKEN` (default: the
    `AETHRION_TOKEN` environment variable; none when unset)
  - `--llm anthropic|openai` - phrase lines and interpret free text with a
    model (configured as for `mix demo.interactive`)
  - `--locale ko` - lines in Korean: with `--llm` the model writes them,
    otherwise the built-in Korean templates do
  - `--idle MINUTES` - stop worlds unused for this long (default 30)

  See `Aethrion.API` for the endpoints.
  """

  use Mix.Task

  alias Aethrion.LLM.{Anthropic, OpenAICompatible}

  @switches [
    cast: :string,
    data: :string,
    port: :integer,
    bind: :string,
    token: :string,
    llm: :string,
    locale: :string,
    idle: :integer
  ]

  @usage "mix aethrion.serve [--cast FILE] [--data DIR] [--port N] [--bind ADDRESS] " <>
           "[--token TOKEN] [--llm anthropic|openai] [--locale ko] [--idle MINUTES]"

  @impl Mix.Task
  def run(args) do
    {opts, _paths} = Aethrion.CLI.TaskArgs.parse!(args, @switches, @usage, 0)
    Mix.Task.run("app.start")

    cast = cast!(opts[:cast])
    data = opts[:data] || "tmp/worlds"
    File.mkdir_p!(data)
    adapter = adapter!(opts[:llm])
    adapter_opts = if opts[:locale] == "ko", do: [language: "Korean"], else: []
    expression = expression(adapter, adapter_opts, opts[:locale])

    {:ok, _worlds} =
      Aethrion.Worlds.start_link(
        name: Aethrion.Serve.Worlds,
        idle_after: :timer.minutes(opts[:idle] || 30),
        world: fn key ->
          [
            initial_state: cast,
            journal: Path.join(data, Aethrion.Worlds.file_name(key) <> ".jsonl")
          ] ++
            expression
        end
      )

    token = opts[:token] || System.get_env("AETHRION_TOKEN")

    {:ok, api} =
      Aethrion.API.start_link(
        worlds: Aethrion.Serve.Worlds,
        port: Keyword.get(opts, :port, 4848),
        bind: opts[:bind] || "127.0.0.1",
        token: token,
        intent: if(adapter, do: [adapter: adapter, adapter_opts: adapter_opts], else: [])
      )

    notes =
      ["#{map_size(cast.characters)} characters", "journals in #{data}"] ++
        if(token, do: ["bearer token required"], else: []) ++
        if(adapter, do: ["lines by #{inspect(adapter)}"], else: [])

    Mix.shell().info(
      "Aethrion API on http://#{opts[:bind] || "127.0.0.1"}:#{Aethrion.API.port(api)} " <>
        "(#{Enum.join(notes, ", ")})"
    )

    unless iex_running?(), do: Process.sleep(:infinity)
  end

  # A model when given; Korean templates for --locale ko without one.
  defp expression(nil, _adapter_opts, "ko"),
    do: [expression: [adapter: Aethrion.LLM.FakeAdapter, adapter_opts: [locale: :ko]]]

  defp expression(nil, _adapter_opts, _locale), do: []

  defp expression(adapter, adapter_opts, _locale),
    do: [expression: [adapter: adapter, adapter_opts: adapter_opts]]

  defp cast!(nil), do: Aethrion.Runtime.demo_state()

  defp cast!(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json),
         {:ok, state} <- Aethrion.State.parse(data) do
      state
    else
      {:error, %Aethrion.Error{} = error} -> Mix.raise("#{path}: #{Aethrion.Error.format(error)}")
      {:error, %Jason.DecodeError{} = error} -> Mix.raise("#{path}: #{Exception.message(error)}")
      {:error, reason} -> Mix.raise("could not read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp adapter!(nil), do: nil

  defp adapter!(name) do
    adapter =
      case name do
        "anthropic" -> Anthropic
        "openai" -> OpenAICompatible
        other -> Mix.raise("unknown --llm #{inspect(other)}; use anthropic or openai")
      end

    unless adapter.configured?(),
      do:
        Mix.raise(
          "#{inspect(adapter)} is not configured; see its module docs for environment variables"
        )

    adapter
  end

  # Under `iex -S mix aethrion.serve` the shell keeps the VM up.
  defp iex_running?, do: Code.ensure_loaded?(IEx) and apply(IEx, :started?, [])
end
