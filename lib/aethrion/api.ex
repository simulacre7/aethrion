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
  - `:allow_hosts` - names besides this machine's that may reach the server
    without a token, such as a Docker Compose service name (`["aethrion"]`)
  - `:intent` - options for interpreting `say` text (`:adapter`,
    `:adapter_opts`), default `Aethrion.LLM.FakeAdapter`
  - `:render_timeout` (ms, default 15_000)
  - `:max_body` (bytes, default 65_536)
  - `:max_text` (characters, default 2_000) - the longest `say` text; each
    one may become a model call
  - `:locale` (`:en` or `:ko`) - the language of combat lines
  - `:card_name` (default `"Aethrion"`) - the name of the card
    `GET /casts/card` exports when the request gives none
  - `:card_image` - a PNG file the card goes into for
    `GET /casts/card?format=png`
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
      bind: bind,
      token: Keyword.get(opts, :token),
      allow_hosts: opts |> Keyword.get(:allow_hosts, []) |> Enum.map(&String.downcase/1),
      intent: Keyword.get(opts, :intent, []),
      interpreter: Keyword.get(opts, :interpreter, Aethrion.Interpreter.Rules),
      interpreter_opts: Keyword.get(opts, :interpreter_opts, []),
      cast: Keyword.get(opts, :cast),
      model: Keyword.get(opts, :model),
      render_timeout: Keyword.get(opts, :render_timeout, 15_000),
      max_text: Keyword.get(opts, :max_text, 2_000),
      locale: Keyword.get(opts, :locale, :en),
      card_name: Keyword.get(opts, :card_name, "Aethrion"),
      card_image: Keyword.get(opts, :card_image),
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
      {:ok, 200, :streamed} -> {200, :streamed, nil}
      result -> result |> respond() |> then(fn {status, json} -> {status, :json_v1, json} end)
    end
  end

  def handle(config, method, path, query, headers, body) do
    with :ok <- authorize(config, headers),
         {:ok, route} <- route(method, path),
         :ok <- small_enough(body, config, route) do
      run(config, route, query, body)
    end
    |> case do
      {:ok, 200, {:png, png}} -> {200, :png, png}
      result -> respond(result)
    end
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

  # Without a token, only this machine reaches the server: the request must
  # name it (a site whose name was rebound to 127.0.0.1 names itself), and
  # a page from another site must not drive it (browsers send its Origin,
  # even where CORS lets nothing back). With a token, the token keeps them
  # out.
  defp authorize(%{token: nil} = config, headers) do
    origin = Map.get(headers, "origin")
    host = Map.get(headers, "host")

    cond do
      host != nil and not local_name?(host, config) ->
        {:error, 403,
         Error.new(
           :forbidden_host,
           "without a token, the server answers only to this machine's names"
         )}

      origin != nil and origin not in ["http://#{host}", "https://#{host}"] ->
        {:error, 403,
         Error.new(:forbidden_origin, "requests from other sites need the server to have a token")}

      true ->
        :ok
    end
  end

  defp authorize(%{token: token}, headers) do
    # Compared as digests, so the time taken says nothing about the token.
    given = Map.get(headers, "authorization", "")

    if :crypto.hash(:sha256, given) == :crypto.hash(:sha256, "Bearer " <> token),
      do: :ok,
      else: {:error, 401, Error.new(:unauthorized, "missing or wrong bearer token")}
  end

  @key ~r/^[A-Za-z0-9_\-.:@]{1,128}$/

  @local_names ["localhost", "127.0.0.1", "::1", "host.docker.internal"]

  # 127.0.0.2 is this machine; 127.attacker.example is a name.
  defp loopback?(name),
    do: match?({:ok, {127, _, _, _}}, :inet.parse_ipv4strict_address(String.to_charlist(name)))

  defp address(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp address(ip), do: to_string(ip)

  defp local_name?(host, config) do
    name = URI.parse("http://" <> host).host || ""

    name in @local_names or String.ends_with?(name, ".localhost") or
      loopback?(name) or name == address(Map.get(config, :bind)) or
      String.downcase(name) in Map.get(config, :allow_hosts, [])
  end

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
      [name: Map.get(query, "name", Map.get(config, :card_name, "Aethrion"))] ++
        if(g = query["greeting"], do: [greeting: g], else: [])

    card = Aethrion.Card.from_cast(config.cast, opts)

    with "png" <- query["format"],
         path when is_binary(path) <- Map.get(config, :card_image),
         {:ok, image} <- File.read(path),
         {:ok, png} <- Aethrion.Card.to_png(card, image) do
      {:ok, 200, {:png, png}}
    else
      _json -> {:ok, 200, card}
    end
  end

  defp run(config, :openai_models, _query, _body) do
    ids =
      for model <- ["aethrion", "aethrion-plain"],
          character <- [nil | Enum.map(talkers(config.cast || %State{}), & &1.id)],
          do: if(character, do: model <> ":" <> character, else: model)

    # The cast read from the card in each request.
    ids = ids ++ ["aethrion-auto", "aethrion-auto-plain"]

    {:ok, 200,
     %{object: "list", data: Enum.map(ids, &%{id: &1, object: "model", owned_by: "aethrion"})}}
  end

  defp run(config, :openai_chat, _query, body) do
    with {:ok, data} <- decode(body),
         {:ok, messages} <- chat_messages(data),
         {:ok, adapter, adapter_opts} <- generator(config) do
      # What this turn reads and reaches is kept only once its reply has
      # gone out: a turn that was answered then replays the same, whatever
      # the model would read now, and a failed one leaves nothing behind.
      staged =
        for name <- [
              Aethrion.Bridge.Readings,
              Aethrion.Bridge.Checkpoints,
              Aethrion.Bridge.Casts
            ],
            do: Aethrion.Bridge.Store.staged(name)

      [readings, checkpoints, casts] = Enum.map(staged, &elem(&1, 0))

      try do
        with {:ok, cast} <-
               bridge_cast(config, data, messages, {adapter, adapter_opts}, %{
                 casts: casts,
                 checkpoints: checkpoints
               }),
             {:ok, to, status?} <-
               bridge_model(cast, data["model"], auto_model?(data["model"])) do
          bridge_turn(config, data, messages, cast, %{
            to: to,
            status?: status?,
            generator: {adapter, adapter_opts},
            readings: readings,
            checkpoints: checkpoints,
            commit: fn -> Enum.each(staged, &elem(&1, 1).()) end
          })
        end
      after
        # Whatever was not committed (a failed reply, an error) is dropped.
        Enum.each(staged, &elem(&1, 2).())
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

      with {:ok, cast} <- into(data["into"], cast) do
        {:ok, 200, %{cast: cast, notes: notes}}
      end
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

  # The cast a card is added to must itself be a cast, and so must the result.
  defp into(into, cast) do
    with {:ok, _state} <- State.parse(into || %{}),
         merged = if(into, do: Aethrion.Card.merge(into, cast), else: cast),
         {:ok, _state} <- State.parse(merged) do
      {:ok, merged}
    else
      {:error, error} ->
        {:error, 400, Error.new(:invalid_cast, "into: " <> reason(error))}
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

  # The cast a request plays: the server's, or for `aethrion-auto` the one
  # read from the card in the request (`Aethrion.Bridge.AutoCast`), once
  # for each card.
  defp bridge_cast(config, data, messages, generator, stores) do
    cond do
      auto_model?(data["model"]) ->
        card_cast(messages, generator, stores)

      match?(%State{}, config.cast) ->
        {:ok, config.cast}

      true ->
        {:error, 400, Error.new(:no_cast, "start the server with --cast to use it as a model")}
    end
  end

  defp card_cast(messages, {adapter, adapter_opts}, stores) do
    {all, chat} = Aethrion.Bridge.transcript(messages)
    card = Aethrion.Bridge.AutoCast.card(all, chat)

    case Aethrion.Bridge.AutoCast.find(chat, card, stores) do
      %State{} = cast -> {:ok, cast}
      nil -> read_card(card, stores.casts, adapter, adapter_opts ++ [max_tokens: 1_500])
    end
  end

  defp read_card(card, casts, adapter, opts) do
    started = System.monotonic_time(:millisecond)

    case Aethrion.Bridge.AutoCast.read(card, casts, adapter, opts) do
      {:ok, cast} ->
        names =
          case State.sorted_characters(cast) do
            [] -> "no one yet"
            people -> Enum.map_join(people, ", ", & &1.name)
          end

        took = seconds(System.monotonic_time(:millisecond) - started)
        Logger.info("Aethrion read a new card: #{names} · #{took}")
        {:ok, cast}

      {:error, reason} ->
        {:error, 502,
         Error.new(:model_failed, "the model could not read the card: #{inspect(reason)}")}
    end
  end

  # A chat app's settings field may capitalize what is typed into it
  # ("Aethrion-auto"), so the name is matched whatever its case.
  defp auto_model?(model) when is_binary(model),
    do:
      model
      |> String.split(":", parts: 2)
      |> hd()
      |> String.downcase()
      |> String.starts_with?("aethrion-auto")

  defp auto_model?(_model), do: false

  defp generator(%{intent: intent}) when is_list(intent) do
    case Keyword.get(intent, :adapter) do
      nil ->
        {:error, 400, Error.new(:no_model, "start the server with --llm: it writes the replies")}

      adapter ->
        {:ok, adapter, Keyword.get(intent, :adapter_opts, [])}
    end
  end

  defp bridge_turn(config, data, messages, cast, turn_opts) do
    locale = if config.locale == :ko, do: :ko, else: :en
    {all, chat} = Aethrion.Bridge.transcript(messages)
    {adapter, adapter_opts} = turn_opts.generator

    read =
      Aethrion.Bridge.reader(
        [
          interpreter: config.interpreter,
          interpreter_opts: config.interpreter_opts,
          intent: config.intent
        ],
        turn_opts.readings
      )

    started = System.monotonic_time(:millisecond)

    # A cast read from a card: the story may bring people in.
    auto? = auto_model?(data["model"])

    with {:ok, {before, now, turn}} <-
           replay_chat(cast, chat, read, turn_opts.to, turn_opts.checkpoints, auto?) do
      replayed = System.monotonic_time(:millisecond)
      # A card read on the way in keeps its own status window.
      note = %{
        "role" => "system",
        "content" =>
          Aethrion.Bridge.note(before, now, turn, locale, card_status: auto?, scene: auto?)
      }

      messages = all ++ [note]
      opts = adapter_opts ++ generation_opts(data)

      status =
        if turn_opts.status? and turn.line != nil,
          do: Aethrion.Bridge.status(now, turn, locale, before, scene: auto?)

      # A turn is kept once the model has answered.
      finish = fn replied ->
        if match?({:ok, _text}, replied), do: turn_opts.commit.()

        log_turn(
          turn,
          replied,
          replayed - started,
          System.monotonic_time(:millisecond) - replayed
        )
      end

      if data["stream"] == true and is_function(config[:emit], 1) do
        stream_turn(config.emit, data, {adapter, messages, opts}, {status, locale, auto?}, finish)
      else
        replied = Aethrion.LLM.chat(adapter, messages, opts)
        finish.(replied)
        reply(data, replied, status, auto?)
      end
    end
  end

  defp reply(data, replied, status, scene?) do
    case replied do
      # A reply to a request to continue one adds to it: no new turn, no
      # second status block.
      {:ok, text} when status != nil ->
        {text, scene} = scene(text, scene?)
        completion(data, String.trim(text) <> "\n\n" <> Aethrion.Bridge.Scene.mark(status, scene))

      {:ok, text} ->
        {text, _scene} = scene(text, scene?)
        completion(data, String.trim(text))

      {:error, reason} ->
        {:error, 502, Error.new(:model_failed, "the model did not answer: #{inspect(reason)}")}
    end
  end

  # The line the model ends its reply with for a cast read from a card
  # (who is with the player), taken out of the reply.
  defp scene(text, true), do: Aethrion.Bridge.Scene.take(text)
  defp scene(text, false), do: {text, nil}

  # The reply as server-sent events while the model writes it, the status
  # block last. Once the first event is out, a failing model can only be
  # told as an error event: the status code has gone.
  defp stream_turn(emit, data, {adapter, messages, opts}, {status, locale, scene?}, done) do
    chunk = sse_chunker(data)
    emit.(:start)
    emit.({:chunk, chunk.(%{role: "assistant", content: ""}, nil)})

    # Leading blank lines are left out, as a whole reply is trimmed.
    started = :atomics.new(1, [])

    send_delta = fn delta ->
      delta = if :atomics.get(started, 1) == 0, do: String.trim_leading(delta), else: delta

      if delta != "" do
        :atomics.put(started, 1, 1)
        emit.({:chunk, chunk.(%{content: delta}, nil)})
      end
    end

    # The scene line is held back from the player.
    {on_delta, flush} =
      if scene?,
        do: Aethrion.Bridge.Scene.filter(send_delta),
        else: {send_delta, fn -> :ok end}

    replied = Aethrion.LLM.stream_chat(adapter, messages, opts, on_delta)
    flush.()
    done.(replied)

    case replied do
      {:ok, text} ->
        {_text, scene} = scene(text, scene?)
        status = status && Aethrion.Bridge.Scene.mark(status, scene)
        if status, do: emit.({:chunk, chunk.(%{content: "\n\n" <> status}, nil)})
        emit.({:chunk, chunk.(%{}, "stop") <> "data: [DONE]\n\n"})

      {:error, reason} ->
        error = %{
          error: %{code: "model_failed", message: "the model did not answer: #{inspect(reason)}"}
        }

        # Chat apps such as RisuAI skip an error event, so the reply says it too.
        emit.({:chunk, chunk.(%{content: stream_failed(locale)}, "stop")})
        emit.({:chunk, "data: " <> Jason.encode!(error) <> "\n\ndata: [DONE]\n\n"})
    end

    emit.(:done)
    {:ok, 200, :streamed}
  end

  defp stream_failed(:ko),
    do: "\n\n(Aethrion: 모델이 답하지 않았습니다. 이번 턴은 반영되지 않았으니 다시 생성해 주세요.)"

  defp stream_failed(_en),
    do:
      "\n\n(Aethrion: the model did not answer. This turn was not applied; regenerate to try again.)"

  defp sse_chunker(data) do
    id = "chatcmpl-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    model = to_string(data["model"] || "aethrion")
    created = System.system_time(:second)

    fn delta, finish ->
      "data: " <>
        Jason.encode!(%{
          id: id,
          object: "chat.completion.chunk",
          created: created,
          model: model,
          choices: [%{index: 0, delta: delta, finish_reason: finish}]
        }) <> "\n\n"
    end
  end

  # One line per turn on the server's console, so a player can see that the
  # app reached Aethrion and where the time went.
  defp log_turn(turn, replied, read_ms, model_ms) do
    line = if turn.line, do: inspect(String.slice(turn.line, 0, 60)), else: "(continue)"
    outcome = if match?({:ok, _}, replied), do: "replied", else: "model failed"

    Logger.info(
      "Aethrion turn: #{line} · rules #{seconds(read_ms)} · model #{seconds(model_ms)} · #{outcome}"
    )
  end

  defp seconds(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  # At most this many lines are replayed in one request (with a model
  # reading them, each new one is a call).
  @max_replay 300

  defp replay_chat(cast, chat, read, to, checkpoints, scenes?) do
    case Aethrion.Bridge.replay(cast, chat, read,
           to: to,
           checkpoints: checkpoints,
           max_lines: @max_replay,
           scenes: scenes?
         ) do
      {:error, :too_many_lines} ->
        {:error, 400,
         Error.new(
           :too_many_lines,
           "more than #{@max_replay} lines to replay; send a shorter chat, or one with the status blocks of earlier replies"
         )}

      replayed ->
        {:ok, replayed}
    end
  end

  # The characters one talks to: not the foes.
  defp talkers(cast),
    do: Enum.filter(State.sorted_characters(cast), &(State.stat(cast, &1.id, "enemy") == 0))

  # Whom a model name without a character talks to: the one who greets the
  # player on the card (Aethrion.Card picks the same), else the first who is
  # not a foe.
  @doc false
  def default_talker(cast) do
    talkers = talkers(cast)

    case Enum.find(talkers, &(&1.greeting not in [nil, ""])) || List.first(talkers) do
      nil -> nil
      talker -> talker.id
    end
  end

  # "aethrion" or "aethrion-plain" (no status block), optionally
  # ":character" for whom the player talks to; by default the one who
  # greets on the card.
  defp bridge_model(_cast, model, _auto?) when not is_binary(model) and model != nil,
    do: {:error, 400, Error.new(:invalid_request, "model must be a string")}

  defp bridge_model(cast, model, auto?) do
    {base, character} =
      case String.split(model || "aethrion", ":", parts: 2) do
        [base, character] -> {base, character}
        [base] -> {base, nil}
      end

    to = character || default_talker(cast)

    # A cast read from a card may have no one in it yet, and whoever is
    # named may only come in later.
    if not auto? and (to == nil or not State.character?(cast, to)) do
      {:error, 400,
       Error.new(
         :invalid_request,
         "model names a character the cast does not have: #{inspect(model)}"
       )}
    else
      {:ok, to || "", not String.ends_with?(String.downcase(base), "-plain")}
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
      chunk = sse_chunker(data)

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
      config = Map.put(config, :emit, emitter(request, segments, config))

      {status, content_type, json} = answer(config, method, segments, query, headers, body)

      if content_type == :streamed do
        {:break, [response: {:already_sent, status, 0}]}
      else
        respond(request, segments, config, status, content_type, json)
      end
    end

    defp answer(config, method, segments, query, headers, body) do
      config
      |> Aethrion.API.handle(method, segments, query, headers, body)
      |> typed()
    rescue
      exception ->
        require Logger

        Logger.error(
          "Aethrion.API request failed: " <> Exception.format(:error, exception, __STACKTRACE__)
        )

        # Mid-stream, the status has gone: end the stream instead.
        if Process.get(:aethrion_streaming) do
          config.emit.(
            {:chunk, ~s(data: {"error":{"code":"internal","message":"internal error"}}\n\n)}
          )

          config.emit.(:done)
          {500, :streamed, nil}
        else
          {500, ~c"application/json",
           ~s({"error":{"code":"internal","message":"internal error"}})}
        end
    end

    defp typed({status, :streamed, nil}), do: {status, :streamed, nil}
    defp typed({status, :html, html}), do: {status, ~c"text/html; charset=utf-8", html}
    defp typed({status, :png, png}), do: {status, ~c"image/png", png}
    defp typed({status, :json_v1, json}), do: {status, ~c"application/json", json}
    defp typed({status, :sse, events}), do: {status, ~c"text/event-stream", events}
    defp typed({status, :preflight, ""}), do: {status, ~c"text/plain", ""}
    defp typed({status, json}), do: {status, ~c"application/json", json}

    defp respond(_request, segments, config, status, content_type, json) do
      {:break,
       [
         response:
           {:response,
            [
              code: status,
              content_type: content_type,
              content_length: Integer.to_charlist(byte_size(json))
            ] ++ cors(segments, config), :erlang.binary_to_list(json)}
       ]}
    end

    # Sends a streamed answer as it is written: the headers, then chunks.
    # HTTP/1.0 clients get the bytes as they come and a closed connection.
    defp emitter(request, segments, config) do
      chunked? = mod(request, :http_version) == ~c"HTTP/1.1"
      disable? = not chunked?

      fn
        :start ->
          Process.put(:aethrion_streaming, true)

          :httpd_response.send_header(
            request,
            200,
            [
              {~c"content-type", ~c"text/event-stream"},
              {~c"cache-control", ~c"no-cache"}
            ] ++
              if(chunked?,
                do: [{~c"transfer-encoding", ~c"chunked"}],
                else: [{~c"connection", ~c"close"}]
              ) ++ cors(segments, config)
          )

        {:chunk, data} ->
          :httpd_response.send_chunk(request, data, disable?)

        :done ->
          Process.delete(:aethrion_streaming)
          :httpd_response.send_final_chunk(request, disable?)
      end
    end

    # Only the OpenAI-compatible routes answer other origins (a chat app in
    # a browser), and only with a token: otherwise any site the user opens
    # could use the server, and the model behind it.
    defp cors(["v1" | _], %{token: token}) when is_binary(token) and token != "",
      do: [
        "access-control-allow-origin": ~c"*",
        "access-control-allow-headers": ~c"authorization, content-type",
        "access-control-allow-methods": ~c"GET, POST, OPTIONS",
        # A web app on a public site reaching this server on the user's machine.
        "access-control-allow-private-network": ~c"true"
      ]

    defp cors(_segments, _config), do: []
  end
end
