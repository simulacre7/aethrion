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
    read = Bridge.reader(to, [interpreter: Aethrion.Interpreter.Rules], no_cache())
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
          Bridge.reader("doyun", [interpreter: Aethrion.Interpreter.Rules], no_cache()),
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

      assert Store.get(Aethrion.Bridge.Checkpoints, id).state.story.lore == []
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

  describe "readings" do
    test "are kept per world, not per line, and a stand-in reading is not kept" do
      cache = Store.cache(Aethrion.Bridge.Readings)
      read = Bridge.reader("sera", [interpreter: Counting], cache)
      state = den()

      read.(state, "안녕", "a")
      assert_received {:interpreted, "안녕"}
      _ = :sys.get_state(Aethrion.Bridge.Readings)
      read.(state, "안녕", "a")
      refute_received {:interpreted, "안녕"}

      # The same words after a different history are read again.
      read.(state, "안녕", "b")
      assert_received {:interpreted, "안녕"}

      down = Bridge.reader("sera", [interpreter: Counting, interpreter_opts: [down: true]], cache)
      down.(state, "잘 가", "a")
      _ = :sys.get_state(Aethrion.Bridge.Readings)
      down.(state, "잘 가", "a")
      assert_received {:interpreted, "잘 가"}
      assert_received {:interpreted, "잘 가"}
    end
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

      {200, headers, _} = request(open, "/v1/chat/completions", body, origin)
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
