defmodule Aethrion.BridgeReviewTest do
  # Regressions from a review of the chat-app bridge and card import.
  use ExUnit.Case, async: false

  alias Aethrion.{API, Bridge, Card, State, Worlds}
  alias Aethrion.Bridge.Store

  defmodule Narrator do
    @behaviour Aethrion.LLM.Adapter
    @impl true
    def render(_request, _opts), do: {:ok, "..."}
    @impl true
    def complete(_system, _user, _opts), do: {:ok, "(narration)"}
    def chat(_messages, _opts), do: {:ok, "늑대가 으르렁거린다."}
  end

  # Reads every line as talk, and says so to the test process; with
  # `down: true` it fails, so the rules stand in.
  defmodule Counting do
    @behaviour Aethrion.Interpreter

    @impl true
    def interpret(request, opts) do
      send(self(), {:interpreted, request.text})

      if Keyword.get(opts, :down),
        do: {:error, :down},
        else:
          {:ok,
           [
             %{
               as: :talk,
               confidence: 0.9,
               event: Aethrion.Event.message_sent("user", request.to, request.text, tone: :warm)
             }
           ]}
    end
  end

  defp no_cache, do: %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}

  defp den(change \\ & &1) do
    {:ok, state} =
      "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> change.() |> State.parse()

    state
  end

  setup do
    start_supervised!({Store, name: Aethrion.Bridge.Readings})
    start_supervised!({Store, name: Aethrion.Bridge.Checkpoints})
    :ok
  end

  defp checkpoints, do: Store.cache(Aethrion.Bridge.Checkpoints)

  defp play(cast, messages, to \\ "sera") do
    {_all, chat} = Bridge.transcript(messages)
    read = Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache())
    replayed = Bridge.replay(cast, chat, read, to: to, checkpoints: checkpoints())
    # Checkpoints are kept in the background; the next request comes later.
    _ = :sys.get_state(Aethrion.Bridge.Checkpoints)
    replayed
  end

  # Plays lines one request at a time, as an app would, and returns the
  # messages with each reply's status block.
  defp chat(cast, lines, to \\ "sera") do
    Enum.reduce(lines, [], fn line, messages ->
      messages = messages ++ [%{"role" => "user", "content" => line}]
      {_before, now, turn} = play(cast, messages, to)
      messages ++ [%{"role" => "assistant", "content" => "…\n\n" <> Bridge.status(now, turn)}]
    end)
  end

  defp hp(state, id), do: State.stat(state, id, "hp")

  @u1 "다이어 울프에게 롱소드를 휘두른다"
  @u2 "다이어 울프를 다시 벤다"
  @u3 "세라, 고마워"

  describe "checkpoints" do
    test "are not taken from another cast" do
      messages = chat(den(), [@u1])

      stronger =
        den(fn data ->
          update_in(data, ["stats", "dire_wolf"], &Map.merge(&1, %{"hp" => 99, "max_hp" => 99}))
        end)

      {_before, now, _turn} = play(stronger, messages ++ [%{"role" => "user", "content" => @u3}])
      {_before, fresh, _turn} = play(stronger, [%{"role" => "user", "content" => @u1}])
      assert hp(now, "dire_wolf") == hp(fresh, "dire_wolf")
    end

    test "a chat that ends with a reply goes on from that reply's checkpoint, and nothing happens again" do
      messages = chat(den(), [@u1, @u2])
      {_before, full, _turn} = play(den(), messages)

      # Trimmed to the last turn and its reply, as a continue request after trimming.
      trimmed = Enum.drop(messages, 2)
      {before, now, turn} = play(den(), trimmed)
      assert hp(now, "dire_wolf") == hp(full, "dire_wolf")
      assert before == now
      assert turn.readings == [] and turn.outputs == []
    end

    test "survive a change of the character spoken to" do
      messages = chat(den(), [@u1, @u2])
      {_before, after_two, _turn} = play(den(), messages)

      next = [%{"role" => "user", "content" => @u3}]
      {_before, now, _turn} = play(den(), Enum.drop(messages, 2) ++ next, "doyun")

      {_before, expected, _turn} =
        Bridge.replay(
          after_two,
          next,
          Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache()),
          to: "doyun"
        )

      assert hp(now, "dire_wolf") == hp(expected, "dire_wolf")

      assert State.get_relationship(now, "doyun", "user") ==
               State.get_relationship(expected, "doyun", "user")
    end

    test "keep the cast's lore out; a resumed world has it back" do
      lore = %{"keys" => ["굴"], "content" => String.duplicate("늑대굴은 오래된 광산이다. ", 200)}

      cast =
        den(&Map.update(&1, "story", %{"lore" => [lore]}, fn s -> Map.put(s, "lore", [lore]) end))

      messages = chat(cast, [@u1])
      [_, id] = Regex.run(~r/id="([0-9a-f]+)"/, List.last(messages)["content"])

      assert get_in(Store.get(Aethrion.Bridge.Checkpoints, id), ["state", "story", "lore"]) in [
               nil,
               []
             ]

      {_before, now, _turn} = play(cast, messages ++ [%{"role" => "user", "content" => @u3}])
      assert now.story.lore == cast.story.lore
    end

    test "two lines in a row are both this turn's" do
      messages = [
        %{"role" => "user", "content" => @u1},
        %{"role" => "user", "content" => @u2}
      ]

      {before, _now, turn} = play(den(), messages)
      assert hp(before, "dire_wolf") == 37
      assert length(turn.readings) >= 2
    end
  end

  describe "checkpoints, second pass" do
    defp plain(lines_and_replies),
      do:
        Enum.map(lines_and_replies, fn
          :reply -> %{"role" => "assistant", "content" => "…"}
          line -> %{"role" => "user", "content" => line}
        end)

    test "only the lines after the last reply are this turn's" do
      {before, _now, turn} = play(den(), plain([@u1, :reply, @u2, @u2, :reply, @u3]))
      {_before, expected, _turn} = play(den(), plain([@u1, @u2, @u2]))
      assert hp(before, "dire_wolf") == hp(expected, "dire_wolf")
      assert turn.line == @u3 and length(turn.readings) == 1

      {_before, _now, turn} = play(den(), plain([@u1, @u2, :reply]))
      assert turn.line == nil
    end

    test "a chat trimmed to begin with a reply goes on from that reply" do
      messages = chat(den(), [@u1, @u2])
      {_before, full, _turn} = play(den(), messages)
      [_u1, _a1, _u2, a2] = messages

      {_before, now, turn} = play(den(), [a2])
      assert hp(now, "dire_wolf") == hp(full, "dire_wolf") and turn.line == nil

      {before, _now, _turn} = play(den(), [a2, %{"role" => "user", "content" => @u3}])
      assert hp(before, "dire_wolf") == hp(full, "dire_wolf")
    end

    test "the first line left after trimming, edited, is replayed from the world before it" do
      [_u1, _a1, _u2, a2, u3, a3] = chat(den(), [@u1, @u2, @u3])
      edited = %{"role" => "user", "content" => "방패를 들어 막는다"}

      {_before, now, _turn} =
        play(den(), [edited, a2, u3, a3, %{"role" => "user", "content" => "안녕"}])

      {_before, expected, _turn} =
        Bridge.replay(
          den(),
          plain([@u1, edited["content"], @u3, "안녕"]),
          Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache()),
          to: "sera"
        )

      assert hp(now, "dire_wolf") == hp(expected, "dire_wolf")
      assert hp(now, "user") == hp(expected, "user")
    end

    test "a chat without status blocks still goes on from its checkpoints" do
      lines = ["안녕", "고마워", "오늘 날씨 좋다", "같이 가자"]

      history =
        Enum.reduce(lines, [], fn line, history ->
          history = history ++ [%{"role" => "user", "content" => line}]
          play(den(), history)
          history ++ [%{"role" => "assistant", "content" => "…"}]
        end)

      {_all, chat} = Bridge.transcript(history ++ [%{"role" => "user", "content" => "잘 자"}])
      read = Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache())

      assert {_before, _now, %{line: "잘 자"}} =
               Bridge.replay(den(), chat, read,
                 to: "sera",
                 checkpoints: checkpoints(),
                 max_lines: 2
               )
    end
  end

  describe "checkpoints, third pass" do
    defp user(line), do: %{"role" => "user", "content" => line}

    defp reply(cast, messages, to \\ "sera") do
      {_before, now, turn} = play(cast, messages, to)
      %{"role" => "assistant", "content" => "…\n\n" <> Bridge.status(now, turn)}
    end

    defp fresh(lines, to \\ "sera") do
      {_before, now, _turn} =
        Bridge.replay(
          den(),
          Enum.map(lines, &user/1),
          Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache()),
          to: to
        )

      now
    end

    # a; then b and c in a row; then e; each answered with a status block.
    defp in_a_row(b, c) do
      m1 = [user(@u1)]
      m1 = m1 ++ [reply(den(), m1)]
      m2 = m1 ++ [user("방패를 들어 막는다"), user(@u2)]
      m2 = m2 ++ [reply(den(), m2)]
      m3 = m2 ++ [user(@u3)]
      m3 = m3 ++ [reply(den(), m3)]
      [_a, _r1, _b, _c, r2, e, r3] = m3
      [user(b), user(c), r2, e, r3, user("안녕")]
    end

    test "a trimmed chat whose first turn had two lines, one edited, goes on from before them" do
      for {b, c} <- [{"세라에게 웃어 보인다", @u2}, {"방패를 들어 막는다", "세라에게 웃어 보인다"}] do
        {_before, now, _turn} = play(den(), in_a_row(b, c))
        expected = fresh([@u1, b, c, @u3, "안녕"])

        assert {hp(now, "dire_wolf"), hp(now, "user")} ==
                 {hp(expected, "dire_wolf"), hp(expected, "user")}
      end
    end

    test "a chat without status blocks finds its checkpoints past lines sent in a row" do
      history = [user("안녕"), user("고마워")]
      play(den(), history)
      history = history ++ [%{"role" => "assistant", "content" => "…"}]

      history =
        Enum.reduce(["오늘 날씨 좋다", "같이 가자"], history, fn line, history ->
          history = history ++ [user(line)]
          play(den(), history)
          history ++ [%{"role" => "assistant", "content" => "…"}]
        end)

      {_all, chat} = Bridge.transcript(history ++ [user("잘 자")])
      read = Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache())

      assert {_before, _now, %{line: "잘 자"}} =
               Bridge.replay(den(), chat, read,
                 to: "sera",
                 checkpoints: checkpoints(),
                 max_lines: 1
               )
    end

    test "a reroll in a chat without status blocks is this turn again, not a continue" do
      history = [user(@u1)]
      {_before, first, _turn} = play(den(), history)
      {before, again, turn} = play(den(), history)
      assert turn.line == @u1 and turn.readings != []
      assert hp(before, "dire_wolf") == 37 and hp(again, "dire_wolf") == hp(first, "dire_wolf")
    end

    test "a trimmed chat whose first turn had both its lines edited goes on from before them" do
      {_before, now, _turn} = play(den(), in_a_row("세라에게 웃어 보인다", "도윤에게 손을 흔든다"))
      expected = fresh([@u1, "세라에게 웃어 보인다", "도윤에게 손을 흔든다", @u3, "안녕"])

      assert {hp(now, "dire_wolf"), hp(now, "user")} ==
               {hp(expected, "dire_wolf"), hp(expected, "user")}
    end

    test "a line deleted from the first turn is not applied twice" do
      m = [user(@u1), user("방패를 들어 막는다"), user(@u2)]
      m = m ++ [reply(den(), m)]
      [a, _b, c, r] = m
      {_before, now, _turn} = play(den(), [a, c, r, user("안녕")])
      expected = fresh([@u1, @u2, "안녕"])

      assert {hp(now, "dire_wolf"), hp(now, "user")} ==
               {hp(expected, "dire_wolf"), hp(expected, "user")}
    end

    test "a chat without status blocks follows its own chain when another chat began alike" do
      plain = fn messages, to ->
        play(den(), messages, to)
        messages ++ [%{"role" => "assistant", "content" => "…"}]
      end

      # Another chat said the same first words, to someone else.
      plain.([user("고마워")], "doyun")

      # This chat said them to Sera, and went on; then turns to Doyun. Its
      # own chain is the longer one. (Had it turned to Doyun right after the
      # first line, nothing in a chat without ids could tell the two apart.)
      history = plain.([user("고마워")], "sera")
      history = plain.(history ++ [user("너 최고야")], "sera")
      {_before, now, _turn} = play(den(), history ++ [user("잘 자")], "doyun")

      marked =
        Enum.reduce([{"고마워", "sera"}, {"너 최고야", "sera"}], [], fn {line, to}, history ->
          history = history ++ [user(line)]
          history ++ [reply(den(), history, to)]
        end)

      {_before, expected, _turn} = play(den(), marked ++ [user("잘 자")], "doyun")

      assert State.get_relationship(now, "sera", "user") ==
               State.get_relationship(expected, "sera", "user")
    end

    test "a chat without status blocks keeps who each line was said to" do
      plain = fn messages, to ->
        play(den(), messages, to)
        messages ++ [%{"role" => "assistant", "content" => "…"}]
      end

      history =
        [{"고마워", "sera"}, {"든든하다", "sera"}, {"너 최고야", "doyun"}]
        |> Enum.reduce([], fn {line, to}, history -> plain.(history ++ [user(line)], to) end)

      {_before, now, _turn} = play(den(), history ++ [user("잘 자")], "doyun")

      marked =
        [{"고마워", "sera"}, {"든든하다", "sera"}, {"너 최고야", "doyun"}]
        |> Enum.reduce([], fn {line, to}, history ->
          history = history ++ [user(line)]
          history ++ [reply(den(), history, to)]
        end)

      {_before, expected, _turn} = play(den(), marked ++ [user("잘 자")], "doyun")

      for who <- ["sera", "doyun"],
          do:
            assert(
              State.get_relationship(now, who, "user") ==
                State.get_relationship(expected, who, "user")
            )
    end
  end

  describe "readings" do
    test "are kept per world, not per line, stand-in readings too" do
      cache = Store.cache(Aethrion.Bridge.Readings)
      read = Bridge.reader([interpreter: Counting], cache)
      state = den()

      read.(state, "안녕", "a", "sera")
      assert_received {:interpreted, "안녕"}
      _ = :sys.get_state(Aethrion.Bridge.Readings)
      read.(state, "안녕", "a", "sera")
      refute_received {:interpreted, "안녕"}

      # The same words after a different history are read again.
      read.(state, "안녕", "b", "sera")
      assert_received {:interpreted, "안녕"}

      # A stand-in reading is kept like any other: the API keeps a turn's
      # readings only once its reply has gone out (second review), and a
      # turn that was answered must replay the same.
      down = Bridge.reader([interpreter: Counting, interpreter_opts: [down: true]], cache)
      down.(state, "잘 가", "a", "sera")
      _ = :sys.get_state(Aethrion.Bridge.Readings)
      down.(state, "잘 가", "a", "sera")
      assert_received {:interpreted, "잘 가"}
      refute_received {:interpreted, "잘 가"}
    end
  end

  test "a model name without a character talks to the one who greets on the card" do
    campfire = "priv/casts/campfire.json" |> File.read!() |> Jason.decode!()
    {:ok, campfire} = Aethrion.State.parse(campfire)
    greeter = Enum.find(Aethrion.State.sorted_characters(campfire), &(&1.greeting != ""))
    assert API.default_talker(campfire) == greeter.id

    card = Aethrion.Card.from_cast(campfire, name: "Campfire")
    assert card["data"]["first_mes"] == greeter.greeting

    # Without greetings: the first who is not a foe.
    quiet = %{
      campfire
      | characters: Map.new(campfire.characters, fn {id, c} -> {id, %{c | greeting: ""}} end)
    }

    first =
      Enum.find(
        Aethrion.State.sorted_characters(quiet),
        &(Aethrion.State.stat(quiet, &1.id, "enemy") == 0)
      )

    assert API.default_talker(quiet) == first.id
  end

  test "the card comes as a PNG with its cover when the server has one" do
    {:ok, campfire} =
      "priv/casts/campfire.json" |> File.read!() |> Jason.decode!() |> Aethrion.State.parse()

    start_supervised!({Worlds, name: Worlds.Test.CardImage, world: fn _key -> [] end})

    api =
      start_supervised!(
        {API,
         worlds: Worlds.Test.CardImage,
         port: 0,
         cast: campfire,
         card_name: "Campfire",
         card_image: "priv/casts/campfire.png"},
        id: :card_image
      )

    url = ~c"http://127.0.0.1:#{API.port(api)}/casts/card?format=png"

    {:ok, {{_v, 200, _r}, headers, png}} =
      :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert {~c"content-type", ~c"image/png"} in headers
    assert {:ok, %{"name" => "Campfire"}} = Aethrion.Card.read(png)

    # Without format=png, or without a cover, it is the JSON card.
    json = ~c"http://127.0.0.1:#{API.port(api)}/casts/card"
    {:ok, {{_v, 200, _r}, _h, body}} = :httpc.request(:get, {json, []}, [], body_format: :binary)
    assert %{"data" => %{"name" => "Campfire"}} = Jason.decode!(body)
  end

  describe "over HTTP" do
    setup do
      start_supervised!({Worlds, name: Worlds.Test.BridgeReview, world: fn _key -> [] end})

      server =
        &start_supervised!(
          {API,
           [
             worlds: Worlds.Test.BridgeReview,
             port: 0,
             locale: :ko,
             cast: den(),
             intent: [adapter: Narrator]
           ] ++ &1},
          id: &2
        )

      open = server.([], :open)
      locked = server.([token: "secret"], :locked)

      %{
        open: "http://127.0.0.1:#{API.port(open)}",
        locked: "http://127.0.0.1:#{API.port(locked)}"
      }
    end

    defp request(base, path, body, headers \\ []) do
      {:ok, {{_v, status, _r}, response_headers, response}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> path), headers, ~c"application/json", Jason.encode!(body)},
          [],
          body_format: :binary
        )

      {status, Map.new(response_headers, fn {k, v} -> {to_string(k), to_string(v)} end), response}
    end

    test "other origins are let in only when a token keeps them out", %{
      open: open,
      locked: locked
    } do
      body = %{"model" => "aethrion:sera", "messages" => [%{"role" => "user", "content" => "안녕"}]}
      origin = [{~c"origin", ~c"https://elsewhere.example"}]

      {403, headers, _} = request(open, "/v1/chat/completions", body, origin)
      refute Map.has_key?(headers, "access-control-allow-origin")

      {200, headers, _} =
        request(locked, "/v1/chat/completions", body, [
          {~c"authorization", ~c"Bearer secret"} | origin
        ])

      assert headers["access-control-allow-origin"] == "*"

      # A browser's preflight. :httpd takes OPTIONS from inets 9.8 (OTP 29);
      # before, it answers 501 itself and only server-side callers get in.
      case :httpc.request(
             :options,
             {String.to_charlist(locked <> "/v1/chat/completions"), []},
             [],
             []
           ) do
        {:ok, {{_v, 204, _r}, headers, _}} ->
          assert {~c"access-control-allow-origin", ~c"*"} in headers
          assert {~c"access-control-allow-private-network", ~c"true"} in headers

        {:ok, {{_v, 501, _r}, _headers, _}} ->
          assert inets_before?([9, 8])
      end
    end

    defp inets_before?(version) do
      :inets
      |> Application.spec(:vsn)
      |> to_string()
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)
      |> Kernel.<(version)
    end

    test "without a token, a page from another site cannot drive the server", %{open: open} do
      body = %{"model" => "aethrion:sera", "messages" => [%{"role" => "user", "content" => "안녕"}]}
      host = open |> URI.parse() |> then(&"#{&1.host}:#{&1.port}")

      assert {403, _h, _} =
               request(open, "/v1/chat/completions", body, [
                 {~c"origin", ~c"https://elsewhere.example"}
               ])

      assert {403, _h, _} =
               request(open, "/worlds/a/say", %{"to" => "sera", "text" => "hi"}, [
                 {~c"origin", ~c"null"}
               ])

      assert {200, _h, _} =
               request(open, "/v1/chat/completions", body, [
                 {~c"origin", String.to_charlist("http://" <> host)}
               ])
    end

    # httpc sets Host itself; a raw request can say anything.
    defp raw(base, request) do
      %URI{host: host, port: port} = URI.parse(base)
      {:ok, socket} = :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false])
      :ok = :gen_tcp.send(socket, request)
      {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.close(socket)
      [_, status] = Regex.run(~r/^HTTP\/1\.1 (\d+)/, response)
      String.to_integer(status)
    end

    test "without a token, only this machine's names reach the server", %{open: open} do
      get = fn host, origin ->
        raw(
          open,
          "GET /v1/models HTTP/1.1\r\nHost: #{host}\r\n#{origin}Connection: close\r\n\r\n"
        )
      end

      # A page whose name was rebound to 127.0.0.1 sends its own name both ways.
      assert get.("evil.example:4848", "Origin: http://evil.example:4848\r\n") == 403
      assert get.("evil.example:4848", "") == 403
      # A name that only begins like a loopback address is still a name.
      assert get.("127.attacker.example:4848", "Origin: http://127.attacker.example:4848\r\n") ==
               403

      assert get.("127.0.0.1.nip.io:4848", "") == 403
      assert get.("127.0.0.1:4848", "") == 200
      assert get.("localhost:4848", "") == 200
      # RisuAI in Docker calls the host by this name.
      assert get.("host.docker.internal:4848", "") == 200
      # A Compose service name is not this machine's unless the server allows it.
      assert get.("aethrion:4848", "") == 403
    end

    test "a name the server allows reaches it without a token" do
      allowed =
        start_supervised!(
          {API,
           worlds: Worlds.Test.BridgeReview, port: 0, cast: den(), allow_hosts: ["Aethrion"]},
          id: :allowed
        )

      base = "http://127.0.0.1:#{API.port(allowed)}"
      get = &raw(base, "GET /v1/models HTTP/1.1\r\nHost: #{&1}\r\nConnection: close\r\n\r\n")

      assert get.("aethrion:4848") == 200
      assert get.("localhost:4848") == 200
      assert get.("risuai:6001") == 403
    end

    test "a card added with a story of null, or an id the cast cannot have, is not a 500", %{
      open: open
    } do
      card = %{
        "name" => "Lumi",
        "character_book" => %{"entries" => [%{"keys" => ["별"], "content" => "별은 노래한다."}]}
      }

      assert {status, _h, _} =
               request(open, "/casts/import-card", %{"card" => card, "into" => %{"story" => nil}})

      assert status in [200, 400]

      for id <- ["", "user"] do
        assert {400, _h, _} = request(open, "/casts/import-card", %{"card" => card, "id" => id})
      end
    end

    test "a model that is not a name, or too many lines to replay, is a 400", %{open: open} do
      line = %{"role" => "user", "content" => "안녕"}

      assert {400, _h, _} =
               request(open, "/v1/chat/completions", %{
                 "model" => %{"a" => 1},
                 "messages" => [line]
               })

      many = List.duplicate(line, 301)

      assert {400, _h, body} =
               request(open, "/v1/chat/completions", %{"model" => "aethrion", "messages" => many})

      assert body =~ "too_many_lines"
    end

    test "a reply to a continue request carries no second status block", %{open: open} do
      line = %{"role" => "user", "content" => @u1}

      {200, _h, first} =
        request(open, "/v1/chat/completions", %{"model" => "aethrion:sera", "messages" => [line]})

      %{"choices" => [%{"message" => %{"content" => reply}}]} = Jason.decode!(first)
      assert reply =~ "<aethrion-status"

      continuing = [
        line,
        %{"role" => "assistant", "content" => reply},
        %{"role" => "system", "content" => "[Continue the last response]"}
      ]

      {200, _h, more} =
        request(open, "/v1/chat/completions", %{
          "model" => "aethrion:sera",
          "messages" => continuing
        })

      %{"choices" => [%{"message" => %{"content" => more}}]} = Jason.decode!(more)
      refute more =~ "<aethrion-status"
    end

    test "odd card shapes and a bad cast to add to are 400s or plain imports, never 500s",
         %{open: open} do
      for card <- [
            %{"name" => "A", "character_book" => %{"entries" => ["x"]}},
            %{"name" => "A", "character_book" => "x"},
            %{"name" => "A", "extensions" => "x"},
            %{"name" => "A", "extensions" => %{"risuai" => "x"}}
          ] do
        assert {200, _h, _} = request(open, "/casts/import-card", %{"card" => card})
      end

      for into <- [%{"characters" => "x"}, %{"story" => "x"}] do
        assert {400, _h, _} =
                 request(open, "/casts/import-card", %{"card" => %{"name" => "A"}, "into" => into})
      end
    end
  end

  describe "cards" do
    test "a CHARX whose card.json unpacks too large is refused, and a zip inside is not read" do
      big = ~s({"name": "A"}) <> String.duplicate(" ", 20_000_000)
      {:ok, {_name, zip}} = :zip.create(~c"bomb.charx", [{~c"card.json", big}], [:memory])
      assert byte_size(zip) < 100_000
      assert Card.read(zip) == {:error, :card_too_large}

      {:ok, {_name, inner}} =
        :zip.create(~c"inner.charx", [{~c"card.json", ~s({"name": "A"})}], [:memory])

      {:ok, {_name, outer}} = :zip.create(~c"outer.charx", [{~c"card.json", inner}], [:memory])
      assert {:error, _} = Card.read(outer)
    end

    test "adding a card again does not repeat its lore" do
      card = %{
        "name" => "Lumi",
        "character_book" => %{"entries" => [%{"keys" => ["별"], "content" => "별은 노래한다."}]}
      }

      {card_cast, _notes} = Card.to_cast(card)
      once = Card.merge(%{}, card_cast)
      assert Card.merge(once, card_cast) == once
    end
  end
end
