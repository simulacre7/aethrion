defmodule Aethrion.API do
  @moduledoc """
  A JSON HTTP API over `Aethrion.Worlds`, so a game engine or a chat backend
  in any language can run worlds: send what the player did, get back what
  characters say.

      children = [
        {Aethrion.Worlds, name: MyApp.Worlds, world: fn key -> [...] end},
        {Aethrion.API, worlds: MyApp.Worlds, port: 4848, token: System.fetch_env!("AETHRION_TOKEN")}
      ]

  `mix aethrion.serve` starts both from a cast file.

  ## Endpoints

  Every body and response is JSON. Worlds are named by a key in the path
  (letters, digits, and `_ - . : @`, at most 128 characters) and start on
  first use.

  | method | path | does |
  | ------ | ---- | ---- |
  | `POST` | `/worlds/{key}/chat` | `{"to": "seoyun", "text": "오늘은 같이 그림 그리자", "from": "user"}`: one line as a person would type it in a chat, read by `Aethrion.Chat` as a fight action, a story activity, a gift, or talk, and dispatched; `interpreted.as` says which |
  | `POST` | `/worlds/{key}/say` | `{"to": "mina", "text": "...", "from": "user", "observed_by": [...]}`: free text, interpreted (`Aethrion.Intent`) and dispatched |
  | `POST` | `/worlds/{key}/act` | `{"text": "I swing at the goblin", "to": "goblin", "from": "user"}`: a combat action in free words (`Aethrion.Combat.action/4`): attack, guard, heal, or flee |
  | `POST` | `/worlds/{key}/events` | an event, as in a scenario or journal: `{"type": "gift_received", "from": "user", "to": "mina", "item": "tea"}` |
  | `GET` | `/worlds/{key}/conversation?character=mina&person=user&after=e12` | the recent turns between them (after an event, for polling: proactive messages land here too) |
  | `GET` | `/worlds/{key}/characters?person=user` | each character with their mood and how they feel about that person (bond, affinity, trust, tension), for a game's UI |
  | `GET` | `/worlds/{key}/story` | the ending reached (or `null`), how close every ending is with what is missing (`Aethrion.Story`), the story's `activities`, the world's `hour`, and the `deadline` |
  | `GET` | `/worlds/{key}/replies?character=hana&person=user` | two or three replies the person might send, each with its tone (`Aethrion.Replies`), for a messenger-style chat; send one as a `message_sent` event with that tone |
  | `GET` | `/worlds/{key}/state` | the whole state, as `Aethrion.State.to_data/1` |
  | `GET` | `/editor` | a cast editor: characters, relationships, endings, and bond stories in forms, checked as you type, with a route simulator |
  | `GET` | `/casts/card?name=...` | the cast as a narrator character card (V3 JSON) to import into a chat app that uses `/v1` as its model |
  | `GET` | `/casts/current` | the cast this server was started with (`mix aethrion.serve --cast`) |
  | `POST` | `/casts/import-card` | `{"file": base64}` (a PNG, JSON, or CHARX character card) or `{"card": {...}}`, optional `"into"` (a cast to add it to), `"player"`, `"id"`: `{"cast", "notes"}` (`Aethrion.Card`); up to `:max_card` bytes (4 MB) |
  | `POST` | `/casts/check` | `{"cast": {...}}`: `{"ok": true, "summary": ...}` or `{"ok": false, "error": {"message", "path"}}` |
  | `POST` | `/casts/simulate` | `{"cast": {...}, "routes": [{"name", "to", "days", "script"}]}`: where each route ends (`Aethrion.Simulator`); 1 to 8 routes of 1 to 120 days, `to` a character in the cast; at most 2 run at once (429 otherwise), for at most 10 s (503 otherwise) |
  | `GET` | `/health` | `{"ok": true}` |
  | `GET` | `/` | a small chat page for trying a world in a browser (no token needed to load it; its requests send one) |

  `say` and `events` answer with what happened:

  ```json
  {"event_id": "e4",
   "lines": [{"type": "reply", "character_id": "mina", "to": "user", "text": "...", "rendered": true}],
   "outputs": [...],
   "interpreted": {"type": "message_sent", "tone": "warm"}}
  ```

  `lines` are what characters said or did (replies, proactive messages,
  scenes). When the world renders with a model, the response waits for the
  model's lines (up to `:render_timeout`) and `rendered` says whether a line
  is the model's or the deterministic fallback. `outputs` are all outputs of
  the step (state changes included). Errors are `{"error": {"code": ..., "message": ...}}`
  with status 400 (a bad request or event), 401, 404, 405, or 413.

  ## Options

  - `:worlds` (required) - the `Aethrion.Worlds` to serve
  - `:port` (default 4848; 0 picks a free port, see `port/1`)
  - `:bind` (default `"127.0.0.1"`) - the address to listen on
  - `:token` - when set, requests need `Authorization: Bearer <token>`
  - `:intent` - options for interpreting `say` text (`:adapter`,
    `:adapter_opts`), default `Aethrion.LLM.FakeAdapter`
  - `:render_timeout` (ms, default 15_000)
  - `:max_body` (bytes, default 65_536)
  - `:max_text` (characters, default 2_000) - the longest `say` text; each
    one may become a model call
  - `:locale` (`:en` or `:ko`) - the language of combat lines
  """

  alias Aethrion.{Conversation, Error, Event, Intent, Output, State, Worlds}

  require Logger

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.get(opts, :port, 4848)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts the server, linked to the caller."
  def start_link(opts) do
    worlds = Keyword.fetch!(opts, :worlds)
    {:ok, _apps} = Application.ensure_all_started(:inets)
    root = Path.join(System.tmp_dir!(), "aethrion-api")
    File.mkdir_p!(root)

    {:ok, bind} = :inet.parse_address(String.to_charlist(Keyword.get(opts, :bind, "127.0.0.1")))

    port =
      case Keyword.get(opts, :port, 4848) do
        0 -> free_port(bind)
        port -> port
      end

    config = [
      port: port,
      bind_address: bind,
      server_name: ~c"aethrion",
      server_root: String.to_charlist(root),
      document_root: String.to_charlist(root),
      modules: [__MODULE__.Handler],
      # httpd refuses far larger bodies itself; up to that, the API answers
      # with a JSON 413.
      # Card files (POST /casts/import-card) may be larger than other bodies.
      max_body_size:
        max(4 * Keyword.get(opts, :max_body, 65_536), Keyword.get(opts, :max_card, 4_194_304)),
      keep_alive: true
    ]

    # The handler finds its settings by port, so they are in place first.
    :persistent_term.put({__MODULE__, port}, %{
      worlds: worlds,
      token: Keyword.get(opts, :token),
      intent: Keyword.get(opts, :intent, []),
      interpreter: Keyword.get(opts, :interpreter, Aethrion.Interpreter.Rules),
      interpreter_opts: Keyword.get(opts, :interpreter_opts, []),
      cast: Keyword.get(opts, :cast),
      model: Keyword.get(opts, :model),
      render_timeout: Keyword.get(opts, :render_timeout, 15_000),
      max_text: Keyword.get(opts, :max_text, 2_000),
      locale: Keyword.get(opts, :locale, :en),
      max_body: Keyword.get(opts, :max_body, 65_536),
      max_card: Keyword.get(opts, :max_card, 4_194_304)
    })

    with {:ok, pid} <- :inets.start(:httpd, config, :stand_alone) do
      :persistent_term.put({__MODULE__, :port, pid}, port)
      {:ok, pid}
    end
  end

  @doc "The port a running server listens on."
  def port(pid), do: :persistent_term.get({__MODULE__, :port, pid})

  defp free_port(bind) do
    {:ok, socket} = :gen_tcp.listen(0, ip: bind)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  ## Requests, as plain data: the handler turns httpd's records into these.

  @chat_path Path.expand("../../priv/api/chat.html", __DIR__)
  @external_resource @chat_path
  @chat_html File.read!(@chat_path)
  @editor_path Path.expand("../../priv/api/editor.html", __DIR__)
  @external_resource @editor_path
  @editor_html File.read!(@editor_path)

  @doc false
  # The chat page holds no data, so it loads without a token.
  def handle(_config, "GET", [], _query, _headers, _body), do: {200, :html, @chat_html}
  def handle(_config, "GET", ["editor"], _query, _headers, _body), do: {200, :html, @editor_html}

  # Browsers ask before a cross-origin call to the OpenAI-compatible routes.
  def handle(_config, "OPTIONS", ["v1" | _rest], _query, _headers, _body),
    do: {204, :preflight, ""}

  # Health checks come from load balancers that hold no token.
  def handle(config, "GET", ["health"], _query, _headers, _body),
    do: respond({:ok, 200, %{ok: true, model: config.model}})

  def handle(config, method, ["v1" | _] = path, query, headers, body) do
    with :ok <- authorize(config, headers),
         {:ok, route} <- route(method, path),
         :ok <- small_enough(body, config, route) do
      run(config, route, query, body)
    end
    |> case do
      {:ok, 200, {:sse, events}} -> {200, :sse, events}
      result -> result |> respond() |> then(fn {status, json} -> {status, :json_v1, json} end)
    end
  end

  def handle(config, method, path, query, headers, body) do
    with :ok <- authorize(config, headers),
         {:ok, route} <- route(method, path),
         :ok <- small_enough(body, config, route) do
      run(config, route, query, body)
    end
    |> respond()
  end

  defp small_enough(body, %{max_card: max}, :cast_import) when byte_size(body) > max,
    do: {:error, 413, Error.new(:body_too_large, "the card is larger than #{max} bytes")}

  defp small_enough(_body, _config, :cast_import), do: :ok

  # An app's prompt (its card, lorebook, and history) can be long.
  defp small_enough(body, %{max_card: max}, :openai_chat) when byte_size(body) > max,
    do: {:error, 413, Error.new(:body_too_large, "the request is larger than #{max} bytes")}

  defp small_enough(_body, _config, :openai_chat), do: :ok

  defp small_enough(body, %{max_body: max}, _route) when byte_size(body) > max,
    do: {:error, 413, Error.new(:body_too_large, "the body is larger than #{max} bytes")}

  defp small_enough(_body, _config, _route), do: :ok

  defp authorize(%{token: nil}, _headers), do: :ok

  defp authorize(%{token: token}, headers) do
    # Compared as digests, so the time taken says nothing about the token.
    given = Map.get(headers, "authorization", "")

    if :crypto.hash(:sha256, given) == :crypto.hash(:sha256, "Bearer " <> token),
      do: :ok,
      else: {:error, 401, Error.new(:unauthorized, "missing or wrong bearer token")}
  end

  @key ~r/^[A-Za-z0-9_\-.:@]{1,128}$/

  defp route("GET", ["health"]), do: {:ok, :health}
  defp route("GET", ["casts", "current"]), do: {:ok, :cast_current}
  defp route("GET", ["casts", "card"]), do: {:ok, :cast_card}
  defp route("POST", ["casts", "check"]), do: {:ok, :cast_check}
  defp route("POST", ["casts", "simulate"]), do: {:ok, :cast_simulate}
  defp route("POST", ["casts", "import-card"]), do: {:ok, :cast_import}
  defp route("POST", ["v1", "chat", "completions"]), do: {:ok, :openai_chat}
  defp route("GET", ["v1", "models"]), do: {:ok, :openai_models}

  defp route(_method, ["casts", action])
       when action in ["current", "check", "simulate", "import-card", "card"],
       do: {:error, 405, Error.new(:method_not_allowed, "method not allowed")}

  defp route(method, ["worlds", key | rest]) do
    if Regex.match?(@key, key) and not String.contains?(key, "..") do
      world_route(method, rest, key)
    else
      {:error, 400, Error.new(:invalid_key, "world keys are letters, digits, and _ - . : @")}
    end
  end

  defp route(_method, _path), do: not_found()

  defp world_route("POST", ["chat"], key), do: {:ok, {:chat, key}}
  defp world_route("POST", ["say"], key), do: {:ok, {:say, key}}
  defp world_route("POST", ["events"], key), do: {:ok, {:event, key}}
  defp world_route("POST", ["act"], key), do: {:ok, {:act, key}}
  defp world_route("GET", ["conversation"], key), do: {:ok, {:conversation, key}}
  defp world_route("GET", ["state"], key), do: {:ok, {:state, key}}
  defp world_route("GET", ["characters"], key), do: {:ok, {:characters, key}}
  defp world_route("GET", ["story"], key), do: {:ok, {:story, key}}
  defp world_route("GET", ["replies"], key), do: {:ok, {:replies, key}}

  defp world_route(_method, route, _key)
       when route in [
              ["chat"],
              ["say"],
              ["events"],
              ["act"],
              ["conversation"],
              ["state"],
              ["characters"],
              ["story"],
              ["replies"]
            ],
       do: {:error, 405, Error.new(:method_not_allowed, "method not allowed")}

  defp world_route(_method, _route, _key), do: not_found()

  defp not_found, do: {:error, 404, Error.new(:not_found, "no such endpoint")}

  defp run(_config, :health, _query, _body), do: {:ok, 200, %{ok: true}}

  defp run(config, {:state, key}, _query, _body) do
    with {:ok, state} <- Worlds.peek_state(config.worlds, key) do
      {:ok, 200, State.to_data(state)}
    end
  end

  defp run(%{cast: nil}, :cast_current, _query, _body),
    do: {:error, 404, Error.new(:not_found, "this server was started without a cast")}

  defp run(config, :cast_current, _query, _body),
    do: {:ok, 200, %{cast: State.to_data(config.cast)}}

  defp run(%{cast: nil}, :cast_card, _query, _body),
    do: {:error, 404, Error.new(:not_found, "this server was started without a cast")}

  # Non-enemy characters' greetings open the card; ?name= and ?greeting= override.
  defp run(config, :cast_card, query, _body) do
    opts =
      [name: Map.get(query, "name", "Aethrion")] ++
        if(g = query["greeting"], do: [greeting: g], else: [])

    {:ok, 200, Aethrion.Card.from_cast(config.cast, opts)}
  end

  defp run(config, :openai_models, _query, _body) do
    ids =
      for model <- ["aethrion", "aethrion-plain"],
          character <- [nil | Enum.map(State.sorted_characters(config.cast || %State{}), & &1.id)],
          do: if(character, do: model <> ":" <> character, else: model)

    {:ok, 200,
     %{object: "list", data: Enum.map(ids, &%{id: &1, object: "model", owned_by: "aethrion"})}}
  end

  defp run(config, :openai_chat, _query, body) do
    with {:ok, data} <- decode(body),
         {:ok, messages} <- chat_messages(data),
         {:ok, cast} <- bridge_cast(config),
         {:ok, adapter, adapter_opts} <- generator(config),
         {:ok, to, status?} <- bridge_model(cast, data["model"]) do
      locale = if config.locale == :ko, do: :ko, else: :en
      {all, chat} = Aethrion.Bridge.transcript(messages)

      read =
        Aethrion.Bridge.reader(
          to,
          [
            interpreter: config.interpreter,
            interpreter_opts: config.interpreter_opts,
            intent: config.intent
          ],
          Aethrion.Bridge.Readings.cache()
        )

      {before, now, turn} = Aethrion.Bridge.replay(cast, chat, read)
      note = %{"role" => "system", "content" => Aethrion.Bridge.note(before, now, turn, locale)}
      opts = adapter_opts ++ generation_opts(data)

      case Aethrion.LLM.chat(adapter, all ++ [note], opts) do
        {:ok, text} ->
          reply =
            if status?,
              do: String.trim(text) <> "\n\n" <> Aethrion.Bridge.status(now, turn, locale),
              else: String.trim(text)

          completion(data, reply)

        {:error, reason} ->
          {:error, 502, Error.new(:model_failed, "the model did not answer: #{inspect(reason)}")}
      end
    end
  end

  # A character card in, cast data out: `{"file": base64}` (PNG, JSON, or
  # CHARX bytes) or `{"card": {...}}` (card JSON), with an optional
  # `"into"` cast to add it to and `"player"`/`"id"`.
  defp run(_config, :cast_import, _query, body) do
    with {:ok, data} <- decode(body),
         {:ok, card} <- card(data) do
      opts =
        for key <- [:player, :id],
            is_binary(data[to_string(key)]),
            do: {key, data[to_string(key)]}

      {cast, notes} = Aethrion.Card.to_cast(card, opts)
      cast = if is_map(data["into"]), do: Aethrion.Card.merge(data["into"], cast), else: cast
      {:ok, 200, %{cast: cast, notes: notes}}
    end
  end

  defp run(_config, :cast_check, _query, body) do
    with {:ok, data} <- decode(body) do
      case State.parse(Map.get(data, "cast")) do
        {:ok, state} ->
          {:ok, 200, %{ok: true, summary: cast_summary(state)}}

        {:error, error} ->
          {:ok, 200, %{ok: false, error: %{message: reason(error), path: path(error)}}}
      end
    end
  end

  defp run(config, :cast_simulate, _query, body) do
    with {:ok, data} <- decode(body),
         {:ok, state} <- cast_state(data),
         {:ok, routes} <- routes(data, state) do
      opts = [
        locale: if(config.locale == :ko, do: :ko, else: :en),
        interpreter: config.interpreter,
        interpreter_opts: config.interpreter_opts
      ]

      case Aethrion.Simulator.run_limited(state, routes, opts) do
        {:ok, results} ->
          {:ok, 200, %{routes: results}}

        {:error, :busy} ->
          {:error, 429, Error.new(:busy, "simulations are already running; try again shortly")}

        {:error, :timeout} ->
          {:error, 503,
           Error.new(:timeout, "the simulation took too long; try fewer days or routes")}
      end
    end
  end

  defp run(config, {:replies, key}, query, _body) do
    with {:ok, state} <- Worlds.peek_state(config.worlds, key),
         {:ok, character} <- required(query, "character"),
         :ok <- known_character(state, character) do
      locale = if config.locale == :ko, do: :ko, else: :en
      person = Map.get(query, "person", "user")
      {:ok, 200, %{replies: Aethrion.Replies.suggest(state, character, person, locale)}}
    end
  end

  defp run(config, {:story, key}, _query, _body) do
    with {:ok, state} <- Worlds.peek_state(config.worlds, key) do
      reached =
        case Aethrion.Rules.Ending.reached(state) do
          nil -> nil
          ending -> Map.take(ending, [:id, :title, :description])
        end

      {:ok, 200,
       %{
         reached: reached,
         endings: Aethrion.Story.progress(state, if(config.locale == :ko, do: :ko, else: :en)),
         activities: state.story |> Map.get(:activities, %{}) |> Map.keys() |> Enum.sort(),
         hour: state.clock,
         deadline: Map.get(state.story, :deadline)
       }}
    end
  end

  defp run(config, {:characters, key}, query, _body) do
    with {:ok, state} <- Worlds.peek_state(config.worlds, key) do
      person = Map.get(query, "person", "user")

      characters =
        for character <- State.sorted_characters(state) do
          relationship = State.get_relationship(state, character.id, person)

          %{
            id: character.id,
            name: character.name,
            profile: character.profile,
            mood: Aethrion.Rules.Mood.derive(character.state, state),
            toward: %{
              id: person,
              bond: Aethrion.Rules.Bond.derive(relationship, state),
              affinity: relationship.affinity,
              trust: relationship.trust,
              tension: relationship.tension
            }
          }
        end

      {:ok, 200, %{characters: characters}}
    end
  end

  # One character's thread with a person, or, without `character`, every
  # thread of that person, so a client polls once for all of them.
  defp run(config, {:conversation, key}, query, _body) do
    person = Map.get(query, "person", "user")

    with {:ok, after_event} <- after_param(query),
         {:ok, state} <- Worlds.peek_state(config.worlds, key),
         {:ok, characters} <- conversation_characters(state, query) do
      turns =
        characters
        |> Enum.flat_map(&Conversation.recent(state, &1, person))
        |> Enum.filter(&(event_index(&1.event_id) > after_event))
        # Within one event, what the person did comes before the reactions.
        |> Enum.sort_by(&{event_index(&1.event_id), if(&1.from == person, do: 0, else: 1)})

      {:ok, 200,
       %{turns: Enum.map(turns, &Map.take(&1, [:from, :to, :text, :kind, :tone, :event_id, :at]))}}
    end
  end

  defp run(config, {:event, key}, _query, body) do
    with {:ok, data} <- decode(body),
         {:ok, event} <- Event.from_data(data) do
      dispatch(config, key, event, %{})
    end
  end

  defp run(config, {:act, key}, _query, body) do
    with {:ok, data} <- decode(body),
         {:ok, text} <- required(data, "text"),
         :ok <- short_enough(text, config.max_text),
         {:ok, state} <- Worlds.peek_state(config.worlds, key) do
      case Aethrion.Combat.action(state, Map.get(data, "from", "user"), data["to"], text) do
        nil ->
          {:error,
           Error.new(
             :unclear_action,
             "could not tell what that does in a fight: say how you attack, guard, heal, or flee",
             %{text: text}
           )}

        event ->
          dispatch(config, key, event, %{
            interpreted: %{type: event.type, to: Map.get(event, :to)}
          })
      end
    end
  end

  defp run(config, {:say, key}, _query, body) do
    with {:ok, data} <- decode(body),
         {:ok, to} <- required(data, "to"),
         {:ok, text} <- required(data, "text"),
         :ok <- observers_list(data),
         :ok <- short_enough(text, config.max_text) do
      talk(config, key, data, to, text)
    end
  end

  defp run(config, {:chat, key}, _query, body) do
    with {:ok, data} <- decode(body),
         {:ok, to} <- required(data, "to"),
         {:ok, text} <- required(data, "text"),
         :ok <- observers_list(data),
         :ok <- short_enough(text, config.max_text),
         {:ok, state} <- Worlds.peek_state(config.worlds, key),
         :ok <- known_character(state, to) do
      {:ok, readings, meta} =
        Aethrion.Interpreter.read(state, Map.get(data, "from", "user"), to, text,
          interpreter: config.interpreter,
          interpreter_opts: config.interpreter_opts,
          intent: config.intent
        )

      Enum.reduce_while(readings, nil, fn reading, said ->
        case chat_step(config, key, data, reading, meta) do
          {:ok, status, body} -> {:cont, merge_said(said, {:ok, status, body})}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp chat_step(config, key, data, %{as: as, event: event}, meta) do
    event =
      if as == :talk and is_list(data["observed_by"]),
        do: Map.put(event, :observed_by, data["observed_by"]),
        else: event

    dispatch(config, key, event, %{
      interpreted: %{
        as: as,
        type: event.type,
        to: Map.get(event, :to),
        tone: Map.get(event, :tone),
        status: meta.status
      }
    })
  end

  # A line that both talks and acts answers with both steps' lines, in
  # order, and how its last part was read.
  defp merge_said(nil, result), do: result

  defp merge_said({:ok, _status, first}, {:ok, status, second}),
    do: {:ok, status, Map.update(second, :lines, [], &(Map.get(first, :lines, []) ++ &1))}

  defp talk(config, key, data, to, text) do
    with {:ok, state} <- Worlds.get_state(config.worlds, key),
         {:ok, event, meta} <-
           Intent.interpret(state, text,
             to: to,
             from: Map.get(data, "from", "user"),
             observed_by: Map.get(data, "observed_by"),
             adapter: Keyword.get(config.intent, :adapter, Aethrion.LLM.FakeAdapter),
             adapter_opts: Keyword.get(config.intent, :adapter_opts, [])
           ) do
      interpreted = %{
        as: :talk,
        type: event.type,
        tone: Map.get(event, :tone),
        status: meta.status
      }

      dispatch(config, key, event, %{interpreted: interpreted})
    end
  end

  defp card(%{"file" => file}) when is_binary(file) do
    with {:ok, bytes} <- file |> Base.decode64(ignore: :whitespace) |> card_bytes() do
      bytes |> Aethrion.Card.read() |> card_error()
    end
  end

  defp card(%{"card" => card}), do: card |> Aethrion.Card.normalize() |> card_error()

  defp card(_data),
    do: {:error, 400, Error.new(:invalid_request, ~s(send {"file": base64} or {"card": {...}}))}

  defp card_bytes({:ok, bytes}), do: {:ok, bytes}
  defp card_bytes(:error), do: {:error, 400, Error.new(:invalid_request, "file must be base64")}

  defp card_error({:ok, card}), do: {:ok, card}

  defp card_error({:error, reason}),
    do: {:error, 400, Error.new(:invalid_card, "not a character card (#{inspect(reason)})")}

  defp chat_messages(%{"messages" => [_ | _] = messages}) do
    if Enum.all?(messages, &(is_map(&1) and is_binary(&1["role"]))),
      do: {:ok, messages},
      else: {:error, 400, Error.new(:invalid_request, "messages must be objects with a role")}
  end

  defp chat_messages(_data),
    do: {:error, 400, Error.new(:invalid_request, "messages is required")}

  defp bridge_cast(%{cast: %State{} = cast}), do: {:ok, cast}

  defp bridge_cast(_config),
    do: {:error, 400, Error.new(:no_cast, "start the server with --cast to use it as a model")}

  defp generator(%{intent: intent}) when is_list(intent) do
    case Keyword.get(intent, :adapter) do
      nil ->
        {:error, 400, Error.new(:no_model, "start the server with --llm: it writes the replies")}

      adapter ->
        {:ok, adapter, Keyword.get(intent, :adapter_opts, [])}
    end
  end

  # "aethrion" or "aethrion-plain" (no status block), optionally
  # ":character" for whom the player talks to; by default the first character.
  defp bridge_model(cast, model) do
    {base, character} =
      case String.split(to_string(model || "aethrion"), ":", parts: 2) do
        [base, character] -> {base, character}
        [base] -> {base, nil}
      end

    to = character || cast |> State.sorted_characters() |> List.first() |> then(&(&1 && &1.id))

    if to == nil or not State.character?(cast, to) do
      {:error, 400,
       Error.new(
         :invalid_request,
         "model names a character the cast does not have: #{inspect(model)}"
       )}
    else
      {:ok, to, base != "aethrion-plain"}
    end
  end

  defp generation_opts(data) do
    [
      max_tokens:
        if(is_integer(data["max_tokens"]),
          do: min(max(data["max_tokens"], 16), 8_000),
          else: 1_200
        ),
      temperature: if(is_number(data["temperature"]), do: data["temperature"], else: nil)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # The OpenAI shape: a completion, or for stream: true, server-sent events
  # (the whole reply as one chunk; it is written before it is sent).
  defp completion(data, reply) do
    id = "chatcmpl-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    model = to_string(data["model"] || "aethrion")
    created = System.system_time(:second)

    if data["stream"] == true do
      chunk = fn delta, finish ->
        "data: " <>
          Jason.encode!(%{
            id: id,
            object: "chat.completion.chunk",
            created: created,
            model: model,
            choices: [%{index: 0, delta: delta, finish_reason: finish}]
          }) <>
          "\n\n"
      end

      {:ok, 200,
       {:sse,
        chunk.(%{role: "assistant", content: reply}, nil) <>
          chunk.(%{}, "stop") <> "data: [DONE]\n\n"}}
    else
      {:ok, 200,
       %{
         id: id,
         object: "chat.completion",
         created: created,
         model: model,
         choices: [
           %{index: 0, message: %{role: "assistant", content: reply}, finish_reason: "stop"}
         ]
       }}
    end
  end

  defp cast_summary(state) do
    %{
      characters: Enum.map(State.sorted_characters(state), &%{id: &1.id, name: &1.name}),
      endings: state.story |> Map.get(:endings, []) |> Enum.map(&Map.take(&1, [:id, :title])),
      milestones:
        state.story |> Map.get(:milestones, []) |> Enum.map(&Map.take(&1, [:id, :title])),
      activities: state.story |> Map.get(:activities, %{}) |> Map.keys() |> Enum.sort()
    }
  end

  defp path(%Error{details: %{path: path}}) when is_list(path), do: Enum.map(path, &to_string/1)
  defp path(_error), do: []

  # The problem itself; the path is given apart.
  defp reason(%Error{details: %{reason: reason}}) when is_binary(reason), do: reason
  defp reason(%Error{message: message}), do: message

  defp cast_state(data) do
    case State.parse(Map.get(data, "cast")) do
      {:ok, state} -> {:ok, state}
      {:error, error} -> {:error, 400, error}
    end
  end

  # A few routes of a few months at most: simulation runs on the request.
  defp routes(%{"routes" => routes}, state) when is_list(routes) and length(routes) in 1..8 do
    Enum.reduce_while(routes, {:ok, []}, fn route, {:ok, acc} ->
      case sim_route(route, state) do
        {:ok, route} -> {:cont, {:ok, acc ++ [route]}}
        {:error, message} -> {:halt, {:error, 400, Error.new(:invalid_request, message)}}
      end
    end)
  end

  defp routes(_data, _state),
    do: {:error, 400, Error.new(:invalid_request, "routes must be a list of 1 to 8 routes")}

  defp sim_route(%{"to" => to, "script" => script} = route, state)
       when is_binary(to) and is_binary(script) do
    name = Map.get(route, "name", "route")
    days = Map.get(route, "days", 30)

    cond do
      not (is_binary(name) and String.length(name) <= 80) ->
        {:error, "a route's name must be text"}

      not State.character?(state, to) ->
        {:error, "#{inspect(to)} is not a character in this cast"}

      byte_size(script) > 4_000 ->
        {:error, "a route's script is at most 4000 bytes"}

      not (is_integer(days) and days in 1..120) ->
        {:error, "days must be 1 to 120"}

      true ->
        {:ok, %{name: name, to: to, days: days, script: script}}
    end
  end

  defp sim_route(_route, _state), do: {:error, "a route needs to (a character) and script (text)"}

  defp known_character(state, id) do
    if State.character?(state, id),
      do: :ok,
      else: {:error, 400, Error.new(:unknown_character, "unknown character: #{inspect(id)}")}
  end

  defp conversation_characters(state, %{"character" => id}) do
    if State.character?(state, id),
      do: {:ok, [id]},
      else: {:error, 400, Error.new(:unknown_character, "unknown character: #{inspect(id)}")}
  end

  defp conversation_characters(state, _query), do: {:ok, Map.keys(state.characters)}

  defp after_param(%{"after" => value}) do
    case event_index(value) do
      -1 -> {:error, 400, Error.new(:invalid_request, "after must be an event id such as e12")}
      index -> {:ok, index}
    end
  end

  defp after_param(_query), do: {:ok, -1}

  # Subscribed before dispatching, so no rendered line is missed.
  defp dispatch(config, key, event, extra) do
    manager = config.worlds
    :ok = Worlds.subscribe(manager, key)

    try do
      with {:ok, step} <- Worlds.step(manager, key, event) do
        expressive = Enum.filter(step.outputs, &Output.expressive?/1)

        rendered =
          if renders?(manager, key),
            do: await_rendered(manager, key, expressive, config.render_timeout),
            else: expressive

        # Lines in the order things happened: what was said, and blows.
        lines =
          step.outputs
          |> Enum.filter(
            &(Output.expressive?(&1) or &1.type in [:combat, :ending_reached, :milestone_reached])
          )
          |> Enum.map(fn output ->
            Enum.find(
              rendered,
              output,
              &(&1.event_id == output.event_id and same_line?(&1, output))
            )
          end)
          |> Enum.map(&localize(&1, step.state, config.locale))

        {:ok, 200,
         Map.merge(extra, %{
           event_id: step.event.id,
           # The last event this step processed, cascades included: poll
           # the conversation after this one.
           last_event_id: step.events |> List.last() |> Map.get(:id),
           lines: Enum.map(lines, &line/1),
           outputs: Enum.map(step.outputs, &json_safe(Map.delete(&1, :context)))
         })}
      end
    after
      Worlds.unsubscribe(manager, key)
      flush(manager, key)
    end
  end

  defp same_line?(a, b),
    do:
      a.type == b.type and Map.get(a, :character_id) == Map.get(b, :character_id) and
        Map.get(a, :to) == Map.get(b, :to)

  defp localize(%{type: :combat} = output, state, locale),
    do: %{output | text: Aethrion.Combat.describe(output, state, locale)}

  # A line the model did not phrase in time keeps the built-in wording, in
  # the server's language.
  defp localize(%{context: %Aethrion.Expression.Request{} = request} = output, _state, :ko) do
    if match?(%{expression: %{status: :ok}}, output),
      do: output,
      else: %{
        output
        | text:
            request
            |> Aethrion.Expression.Templates.Ko.render()
            |> Aethrion.Expression.Templates.Ko.polite(request)
      }
  end

  defp localize(output, _state, _locale), do: output

  defp renders?(manager, key) do
    case Worlds.Janitor.world_options(manager, key) do
      {:ok, opts} -> Keyword.has_key?(opts, :expression)
      _error -> false
    end
  end

  defp await_rendered(manager, key, outputs, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.map(outputs, fn output ->
      wait = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:aethrion, {^manager, ^key},
         {:expressed, %{event_id: id, character_id: who, to: to} = rendered}}
        when id == output.event_id and who == output.character_id and to == output.to ->
          rendered
      after
        wait -> output
      end
    end)
  end

  defp flush(manager, key) do
    receive do
      {:aethrion, {^manager, ^key}, _payload} -> flush(manager, key)
    after
      0 -> :ok
    end
  end

  # Why a proactive message was sent, which kind of scene, or the tone a
  # reply answers; whichever the line has.
  defp line(%{type: :milestone_reached} = output) do
    output
    |> Map.take([:type, :event_id, :milestone, :title, :description, :character_id, :to, :text])
    |> Map.put(:rendered, false)
  end

  defp line(%{type: :ending_reached} = output) do
    %{
      type: :ending_reached,
      event_id: output.event_id,
      ending: output.ending,
      title: output.title,
      text: output.description,
      because: output.because
    }
  end

  defp line(%{type: :combat} = output) do
    output
    |> Map.take([
      :type,
      :event_id,
      :kind,
      :character_id,
      :to,
      :subject,
      :amount,
      :hp,
      :max_hp,
      :text,
      :d20,
      :d20_rolls,
      :attack_bonus,
      :ac,
      :dice,
      :dice_rolls
    ])
    |> Map.put(:rendered, false)
  end

  defp line(output) do
    %{
      type: output.type,
      event_id: output.event_id,
      character_id: output.character_id,
      to: output.to,
      text: output.text,
      # Phrased by a model; the built-in templates (FakeAdapter) do not count.
      rendered:
        match?(%{expression: %{status: :ok}}, output) and
          output.expression.adapter != Aethrion.LLM.FakeAdapter
    }
    |> Map.merge(Map.take(output, [:reason, :kind, :tone]))
  end

  defp required(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: missing(key), else: {:ok, value}

      nil ->
        missing(key)

      _other ->
        {:error, 400, Error.new(:invalid_request, "#{key} must be a string", %{field: key})}
    end
  end

  defp missing(key) do
    {:error, 400, Error.new(:invalid_request, "#{key} is required", %{field: key})}
  end

  # "e12" is 12; anything else counts as before every event.
  defp event_index("e" <> digits) do
    case Integer.parse(digits) do
      {index, ""} -> index
      _other -> -1
    end
  end

  defp event_index(_none), do: -1

  defp observers_list(%{"observed_by" => observers}) when not is_list(observers),
    do: {:error, 400, Error.new(:invalid_request, "observed_by must be a list of character ids")}

  defp observers_list(_data), do: :ok

  # Counted in characters as people see them, and in bytes, so text made of
  # combining marks cannot pass for a short line.
  defp short_enough(text, max) do
    if String.length(text) <= max and byte_size(text) <= max * 8,
      do: :ok,
      else: {:error, 400, Error.new(:text_too_long, "text is longer than #{max} characters")}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = data} -> {:ok, data}
      _other -> {:error, 400, Error.new(:invalid_json, "the body must be a JSON object")}
    end
  end

  defp respond({:ok, status, body}), do: {status, Jason.encode!(body)}

  defp respond({:error, status, %Error{} = error}), do: {status, error_body(error)}

  # Worlds that cannot start or store are the server's problem: 503, with
  # what went wrong left to the server's logs.
  @unavailable [:world_failed, :world_not_running, :journal_failed, :io_error]

  defp respond({:error, %Error{code: code} = error}) when code in @unavailable do
    Logger.warning("Aethrion.API: #{Error.format(error)} #{inspect(error.details)}")

    {503,
     Jason.encode!(%{
       error: %{code: code, message: "the world is unavailable right now; try again later"}
     })}
  end

  defp respond({:error, %Error{} = error}), do: {400, error_body(error)}

  defp error_body(error),
    do: Jason.encode!(%{error: %{code: error.code, message: Error.format(error)}})

  # Outputs hold structs, tuples, and pids that JSON cannot carry as such.
  defp json_safe(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> json_safe()
  defp json_safe(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, json_safe(v)} end)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(value) when is_tuple(value) or is_pid(value) or is_reference(value),
    do: inspect(value)

  defp json_safe(value) when is_function(value), do: inspect(value)
  defp json_safe(value), do: value

  defmodule Handler do
    @moduledoc false
    # The :httpd callback: turns its request record into plain data.
    require Record
    Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

    def unquote(:do)(request) do
      config_db = mod(request, :config_db)
      port = :httpd_util.lookup(config_db, :port)
      config = :persistent_term.get({Aethrion.API, port})

      # httpd hands over bytes as lists; they are UTF-8, not code points.
      uri = request |> mod(:request_uri) |> :erlang.list_to_binary()
      [path | rest] = String.split(uri, "?", parts: 2)
      query = rest |> List.first("") |> URI.decode_query()
      segments = path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)

      headers =
        Map.new(mod(request, :parsed_header), fn {k, v} ->
          {String.downcase(:erlang.list_to_binary(k)), :erlang.list_to_binary(v)}
        end)

      body =
        case mod(request, :entity_body) do
          body when is_list(body) -> :erlang.list_to_binary(body)
          _none -> ""
        end

      method = request |> mod(:method) |> to_string()

      {status, content_type, json} =
        try do
          case Aethrion.API.handle(config, method, segments, query, headers, body) do
            {status, :html, html} -> {status, ~c"text/html; charset=utf-8", html}
            {status, :json_v1, json} -> {status, ~c"application/json", json}
            {status, :sse, events} -> {status, ~c"text/event-stream", events}
            {status, :preflight, ""} -> {status, ~c"text/plain", ""}
            {status, json} -> {status, ~c"application/json", json}
          end
        rescue
          exception ->
            require Logger

            Logger.error(
              "Aethrion.API request failed: " <>
                Exception.format(:error, exception, __STACKTRACE__)
            )

            {500, ~c"application/json",
             ~s({"error":{"code":"internal","message":"internal error"}})}
        end

      {:break,
       [
         response:
           {:response,
            [
              code: status,
              content_type: content_type,
              content_length: Integer.to_charlist(byte_size(json))
            ] ++ cors(segments), :erlang.binary_to_list(json)}
       ]}
    end

    # Only the OpenAI-compatible routes answer other origins (a chat app in
    # a browser); the rest of the API stays same-origin.
    defp cors(["v1" | _]),
      do: [
        "access-control-allow-origin": ~c"*",
        "access-control-allow-headers": ~c"authorization, content-type",
        "access-control-allow-methods": ~c"GET, POST, OPTIONS"
      ]

    defp cors(_segments), do: []
  end
end
