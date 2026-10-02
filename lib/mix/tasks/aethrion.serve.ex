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

  - `--cast FILE` - the starting world, as state data (`characters` with
    `profile` and `voice`, `relationships`, `people`; the format
    `Aethrion.State.to_data/1` writes); default: the demo cast.
    `priv/casts/cafe.json` is a Korean café cast to start from
  - `--data DIR` - where each world's journal is kept (default `tmp/worlds`)
  - `--port N` (default 4848), `--bind ADDRESS` (default `127.0.0.1`)
  - `--token TOKEN` - require `Authorization: Bearer TOKEN` (default: the
    `AETHRION_TOKEN` environment variable; none when unset)
  - `--allow-host NAMES` - comma-separated names besides this machine's that
    may reach the server without a token, such as a Docker Compose service
    name (default: the `AETHRION_ALLOW_HOSTS` environment variable)
  - `--llm NAME` - the model that reads what each chat line does and writes
    what characters say: `anthropic`, `openai` (any OpenAI-compatible API),
    `ollama`, `lmstudio`, `llamacpp` (a model served on this machine),
    `claude` or `codex` (the CLI on this machine, as signed in); see
    `Aethrion.LLM.Backend`. Without it, keyword rules read the lines and
    templates write them: an offline fallback for testing, not the way to
    play
  - `--model NAME`, `--base-url URL` - for the chosen backend
  - `--read-model NAME` - a model of the same backend for reading what each
    line does (a short choice, so a smaller, faster model does), while
    `--model` narrates (default: the `AETHRION_READ_MODEL` environment
    variable, else `--model`)
  - `--locale ko` - lines in Korean: with `--llm` the model writes them,
    otherwise the built-in Korean templates do
  - `--idle MINUTES` - stop worlds unused for this long (default 30)
  - `--tick-every SECONDS` - let an hour pass in each running world every
    this many seconds, so characters reach out on their own (their lines
    show up when a client polls `conversation`); by default time passes
    only when a client sends a `time_tick`

  With `--llm`, the server is also an OpenAI-compatible model at
  `/v1/chat/completions` for chat apps such as RisuAI (`Aethrion.Bridge`,
  docs/risuai.md); what it remembers for that is kept under `--data`.

  See `Aethrion.API` for the endpoints.
  """

  use Mix.Task

  @switches [
    cast: :string,
    data: :string,
    port: :integer,
    bind: :string,
    token: :string,
    allow_host: :string,
    llm: :string,
    model: :string,
    read_model: :string,
    base_url: :string,
    locale: :string,
    idle: :integer,
    tick_every: :integer
  ]

  @usage "mix aethrion.serve [--cast FILE] [--data DIR] [--port N] [--bind ADDRESS] " <>
           "[--token TOKEN] [--allow-host NAMES] [--read-model NAME] [--llm anthropic|openai] [--locale ko] [--idle MINUTES] [--tick-every SECONDS]"

  @impl Mix.Task
  def run(args) do
    {opts, _paths} = Aethrion.CLI.TaskArgs.parse!(args, @switches, @usage, 0)
    Mix.Task.run("app.start")

    cast = cast!(opts[:cast])
    data = opts[:data] || "tmp/worlds"
    File.mkdir_p!(data)
    {adapter, backend_opts, label} = backend!(opts)
    adapter_opts = backend_opts ++ if(opts[:locale] == "ko", do: [language: "Korean"], else: [])
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
            expression ++ scheduler(opts[:tick_every])
        end
      )

    start_bridge_stores(data)

    # An empty AETHRION_TOKEN (as Compose passes an unset one) means no token.
    token = blank_to_nil(opts[:token] || System.get_env("AETHRION_TOKEN"))

    {:ok, api} =
      Aethrion.API.start_link(
        [
          worlds: Aethrion.Serve.Worlds,
          port: Keyword.get(opts, :port, 4848),
          bind: opts[:bind] || "127.0.0.1",
          token: token,
          allow_hosts: allow_hosts(opts[:allow_host] || System.get_env("AETHRION_ALLOW_HOSTS")),
          locale: if(opts[:locale] == "ko", do: :ko, else: :en),
          cast: cast,
          card_name: card_name(opts[:cast]),
          card_image: card_image(opts[:cast])
        ] ++
          reading(
            adapter,
            adapter_opts,
            backend_opts,
            label,
            blank_to_nil(opts[:read_model] || System.get_env("AETHRION_READ_MODEL"))
          )
      )

    announce(Aethrion.API.port(api), opts[:bind] || "127.0.0.1", cast, data, token, label)

    unless iex_running?(), do: Process.sleep(:infinity)
  end

  # The cast's file name, for the card RisuAI imports: "campfire.json" is
  # "Campfire", "campfire_en.json" "Campfire (EN)".
  defp card_name(nil), do: "Aethrion"

  defp card_name(path) do
    case path |> Path.basename(".json") |> String.split(~r/[_.-]/, trim: true) do
      [name, lang] when byte_size(lang) == 2 ->
        String.capitalize(name) <> " (#{String.upcase(lang)})"

      words ->
        Enum.map_join(words, " ", &String.capitalize/1)
    end
  end

  # A cover image next to the cast file ("campfire.png"), for the card.
  defp card_image(nil), do: nil

  defp card_image(path) do
    image = Path.rootname(path) <> ".png"
    if File.regular?(image), do: image
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp allow_hosts(nil), do: []

  defp allow_hosts(names),
    do:
      names
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  # For the OpenAI-compatible route: what chat lines were read as, and the
  # world after each turn.
  defp start_bridge_stores(data) do
    for {name, file} <- [
          {Aethrion.Bridge.Readings, "bridge-readings.jsonl"},
          {Aethrion.Bridge.Checkpoints, "bridge-checkpoints.jsonl"}
        ] do
      {:ok, _store} = Aethrion.Bridge.Store.start_link(name: name, path: Path.join(data, file))
    end
  end

  defp announce(port, bind, cast, data, token, label) do
    notes =
      ["#{map_size(cast.characters)} characters", "journals in #{data}"] ++
        if(token, do: ["bearer token required"], else: []) ++ [model_note(label)]

    Mix.shell().info("Aethrion API on http://#{bind}:#{port} (#{Enum.join(notes, ", ")})")
    if label, do: chat_app_hint(port, token)
  end

  # How to point a chat app at the server.
  defp chat_app_hint(port, token) do
    Mix.shell().info(
      "RisuAI (desktop app) or SillyTavern: Custom API at http://localhost:#{port}/v1, " <>
        "model \"aethrion\"" <>
        if(token, do: ", the token as the key", else: "") <>
        "; the card and these settings are under RisuAI on http://localhost:#{port}"
    )
  end

  defp scheduler(nil), do: []

  defp scheduler(seconds) when seconds > 0,
    do: [scheduler: [interval_ms: seconds * 1000, tick_hours: 1]]

  defp scheduler(_seconds), do: Mix.raise("--tick-every must be a positive number of seconds")

  @doc false
  # A model when given; Korean templates for --locale ko without one.
  def expression(nil, _adapter_opts, "ko"),
    do: [expression: [adapter: Aethrion.LLM.FakeAdapter, adapter_opts: [locale: :ko]]]

  def expression(nil, _adapter_opts, _locale), do: []

  def expression(adapter, adapter_opts, _locale),
    do: [
      expression: [
        adapter: adapter,
        adapter_opts: adapter_opts,
        timeout: render_timeout(adapter)
      ]
    ]

  # How long a world waits for a model's line, and the API for the world: a
  # CLI takes seconds a call.
  defp render_timeout(Aethrion.LLM.CLI), do: 60_000
  defp render_timeout(_adapter), do: 15_000

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

  @doc false
  # Who reads chat lines and their tone: the model, or the keyword rules.
  def reading(adapter, adapter_opts, backend_opts, label, read_model \\ nil)

  def reading(nil, _adapter_opts, _backend_opts, _label, _read_model),
    do: [interpreter: Aethrion.Interpreter.Rules]

  def reading(adapter, adapter_opts, backend_opts, label, read_model),
    do: [
      render_timeout: render_timeout(adapter),
      intent: [adapter: adapter, adapter_opts: adapter_opts],
      interpreter: Aethrion.Interpreter.LLM,
      interpreter_opts: [
        adapter: adapter,
        adapter_opts:
          if(read_model, do: Keyword.put(backend_opts, :model, read_model), else: backend_opts)
      ],
      model: if(read_model, do: label <> ", reading with #{read_model}", else: label)
    ]

  defp model_note(nil),
    do: "no model: keyword rules only (an offline fallback for testing; pass --llm)"

  defp model_note(label), do: "model: #{label}"

  defp backend!(opts) do
    case opts[:llm] do
      nil ->
        {nil, [], nil}

      name ->
        case Aethrion.LLM.Backend.resolve(name, model: opts[:model], base_url: opts[:base_url]) do
          {:ok, adapter, adapter_opts, label} -> {adapter, adapter_opts, label}
          {:error, message} -> Mix.raise(message)
        end
    end
  end

  # Under `iex -S mix aethrion.serve` the shell keeps the VM up.
  defp iex_running?, do: Code.ensure_loaded?(IEx) and apply(IEx, :started?, [])
end
