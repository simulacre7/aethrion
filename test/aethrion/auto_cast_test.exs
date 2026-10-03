defmodule Aethrion.AutoCastTest do
  use ExUnit.Case, async: false

  alias Aethrion.{API, State, Worlds}
  alias Aethrion.Bridge.AutoCast

  @card "Write Sera's next reply. Sera is a quiet healer who travels with Kim. Doyun, a shield-bearer, is with them."
  @greeting "세라: 불이 잘 붙었네요. 오늘은 여기서 쉬어요."

  describe "reading a card" do
    test "takes the people from the model's answer, the main one first" do
      answer = """
      Here you go:
      ```json
      {"title": "Campfire", "characters": [
        {"name": "세라", "profile": "조용한 치유사.", "affinity": 30, "trust": 140},
        {"name": "Doyun", "profile": "A shield-bearer.", "affinity": -5},
        {"name": "세라", "profile": "again"},
        {"name": "  "}
      ]}
      ```
      """

      assert {:ok, %{title: "Campfire", characters: [sera, doyun]} = people} =
               AutoCast.people(answer)

      assert sera["name"] == "세라"
      assert doyun["name"] == "Doyun"

      data = AutoCast.cast_data(people, %{prompt: @card, greeting: @greeting})
      assert {:ok, state} = State.parse(data)

      assert [%{name: "세라", greeting: @greeting}, %{name: "Doyun", greeting: ""}] =
               State.sorted_characters(state)

      # What the card says of the start, kept within 0 to 100.
      assert %{"affinity" => 30, "trust" => 100} = hd(data["relationships"])
      assert %{"affinity" => 0, "trust" => 0} = List.last(data["relationships"])
      # The one who greets is the one the player talks to.
      assert API.default_talker(state) == hd(data["characters"])["id"]
    end

    test "a card with no fixed characters starts with no one" do
      assert {:ok, people} = AutoCast.people(~s({"title": "Isekai RPG", "characters": []}))
      data = AutoCast.cast_data(people, %{prompt: "", greeting: nil})
      assert data == %{"characters" => [], "relationships" => []}
      assert {:ok, state} = State.parse(data)
      assert State.sorted_characters(state) == []
    end

    test "an answer that is not the JSON asked for is refused" do
      assert AutoCast.people("I cannot read this card.") == {:error, :no_characters_read}
      assert AutoCast.people(~s({"characters": "none"})) == {:error, :no_characters_read}
    end

    test "the key is the first message when there is one" do
      with_greeting = %{prompt: "a prompt", greeting: "hello"}
      assert AutoCast.key(with_greeting) == AutoCast.key(%{with_greeting | prompt: "another"})
      refute AutoCast.key(with_greeting) == AutoCast.key(%{with_greeting | greeting: "hi"})

      refute AutoCast.key(%{prompt: "a prompt", greeting: nil}) ==
               AutoCast.key(%{prompt: "another", greeting: nil})
    end
  end

  # Reads a card when asked to, narrates otherwise; every call is noted.
  defmodule Model do
    @behaviour Aethrion.LLM.Adapter
    @impl true
    def render(_request, _opts), do: {:ok, "..."}
    @impl true
    def complete(_system, _user, _opts), do: {:ok, "(narration)"}

    def chat(messages, _opts) do
      Agent.update(Aethrion.AutoCastTest.Calls, &(&1 ++ [messages]))

      cond do
        Enum.any?(messages, &(&1["content"] =~ "FAILING CARD")) ->
          {:error, :boom}

        hd(messages)["content"] =~ "You read a role-play character card" and
            Enum.any?(messages, &(&1["content"] =~ "NARRATOR CARD")) ->
          {:ok, ~s({"title": "Isekai", "characters": []})}

        Enum.any?(messages, &(&1["content"] =~ "NARRATOR CARD")) ->
          {:ok, narration(messages)}

        hd(messages)["content"] =~ "You read a role-play character card" ->
          {:ok,
           ~s({"title": "Campfire", "characters": [{"name": "세라", "profile": "조용한 치유사.", "affinity": 30, "trust": 20}, {"name": "도윤", "profile": "방패수.", "affinity": 10, "trust": 10}]})}

        true ->
          {:ok, "세라가 고개를 끄덕인다."}
      end
    end

    def stream_chat(messages, opts, on_delta) do
      {:ok, text} = chat(messages, opts)
      # In pieces that cut the scene line's tag in two.
      for piece <- Regex.scan(~r/.{1,7}/su, text), do: on_delta.(hd(piece))
      {:ok, text}
    end

    # A narrator: Haruka is there from the first reply, Kenji joins when
    # the player has spoken twice, and then Haruka leaves.
    defp narration(messages) do
      case Enum.count(messages, &(&1["role"] == "user")) do
        1 -> "버스가 멈춘다. 옆자리의 하루카가 고개를 든다.\n<aethrion-scene>\n하루카 | 조용한 도서부원\n</aethrion-scene>"
        2 -> "켄지가 다가온다.\n\n<aethrion-scene>하루카\n- 켄지 | 운동부 주장</aethrion-scene>"
        _more -> "하루카는 먼저 내렸다. <가방>만 남았다.\n<aethrion-scene>켄지</aethrion-scene>"
      end
    end
  end

  describe "the model name aethrion-auto" do
    setup do
      for name <- [Aethrion.Bridge.Readings, Aethrion.Bridge.Checkpoints, Aethrion.Bridge.Casts],
          do: start_supervised!({Aethrion.Bridge.Store, name: name})

      start_supervised!(%{
        id: Aethrion.AutoCastTest.Calls,
        start: {Agent, :start_link, [fn -> [] end, [name: Aethrion.AutoCastTest.Calls]]}
      })

      start_supervised!({Worlds, name: Worlds.Test.AutoCast, world: fn _key -> [] end})
      {:ok, den} = "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> State.parse()

      pid =
        start_supervised!(
          {API,
           worlds: Worlds.Test.AutoCast,
           port: 0,
           locale: :ko,
           cast: den,
           intent: [adapter: Model],
           interpreter: Aethrion.Interpreter.Rules}
        )

      %{base: "http://127.0.0.1:#{API.port(pid)}"}
    end

    defp ask(base, chat, opts \\ []) do
      messages =
        [
          %{"role" => "system", "content" => Keyword.get(opts, :card, @card)},
          %{"role" => "system", "content" => "[Start a new chat]"},
          %{"role" => "assistant", "content" => @greeting}
        ] ++ chat

      body =
        Jason.encode!(%{
          "model" => Keyword.get(opts, :model, "aethrion-auto"),
          "messages" => messages
        })

      {:ok, {{_v, status, _r}, _headers, answer}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json", body},
          [],
          body_format: :binary
        )

      case Jason.decode!(answer) do
        %{"choices" => [%{"message" => %{"content" => content}}]} -> {status, content}
        error -> {status, error}
      end
    end

    defp calls, do: Agent.get(Aethrion.AutoCastTest.Calls, & &1)
    defp user(line), do: %{"role" => "user", "content" => line}
    defp reply(text), do: %{"role" => "assistant", "content" => text}

    defp card_reads,
      do: Enum.count(calls(), &(hd(&1)["content"] =~ "You read a role-play character card"))

    test "plays the card in the request, read once", %{base: base} do
      {200, first} = ask(base, [user("세라, 고마워. 덕분에 살았어.")])

      # The people are the card's, not the server's cast (a wolf den).
      assert first =~
               ~r/<aethrion-status id="[0-9a-f]+">세라 · 호감 3\d \(\+\d\) · 신뢰 2\d \(\+\d\)\n도윤 · 호감 10 · 신뢰 10\n/

      refute first =~ "울프"
      assert card_reads() == 1

      # A reroll: the same numbers, and the card is not read again.
      {200, again} = ask(base, [user("세라, 고마워. 덕분에 살았어.")])
      assert status(again) == status(first)
      assert card_reads() == 1
    end

    test "the chat keeps its cast when the app changes its prompt", %{base: base} do
      line = user("세라, 고마워. 덕분에 살았어.")
      {200, first} = ask(base, [line])

      # A lorebook entry came in, and the app trimmed the first message away:
      # the reply's checkpoint still leads to the cast.
      changed = @card <> "\n\n[Lore: the forest is haunted.]"

      body = %{
        "model" => "aethrion-auto",
        "messages" => [
          %{"role" => "system", "content" => changed},
          line,
          reply(first),
          user("세라, 미안해. 내가 잘못했어.")
        ]
      }

      {:ok, {{_v, 200, _r}, _headers, answer}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json",
           Jason.encode!(body)},
          [],
          body_format: :binary
        )

      assert %{"choices" => [%{"message" => %{"content" => second}}]} = Jason.decode!(answer)
      assert second =~ "세라 · 호감"
      assert card_reads() == 1
    end

    test "leaves the card's own status window to the card", %{base: base} do
      {200, _reply} = ask(base, [user("세라, 고마워.")])
      note = calls() |> List.last() |> List.last() |> Map.fetch!("content")

      assert note =~ "If the card asks for a status window or a format of its own, keep it"
      refute note =~ "do not print a status window"

      # The server's own cast is told as before.
      {200, _reply} = ask(base, [user("다이어 울프를 벤다")], model: "aethrion")
      note = calls() |> List.last() |> List.last() |> Map.fetch!("content")
      assert note =~ "do not print a status window"
    end

    test "without a status block for aethrion-auto-plain", %{base: base} do
      {200, plain} = ask(base, [user("세라, 고마워.")], model: "aethrion-auto-plain")
      assert plain == "세라가 고개를 끄덕인다."
    end

    test "a card the model cannot read is an error, and nothing is kept", %{base: base} do
      {502, error} = ask(base, [user("안녕")], card: "FAILING CARD")
      assert error["error"]["code"] == "model_failed"
      assert error["error"]["message"] =~ "could not read the card"

      # The same first message with a card that can be read: read again.
      {200, _reply} = ask(base, [user("세라, 고마워.")])
      assert card_reads() == 2
    end

    test "the name is matched in any letter case", %{base: base} do
      # A settings field may capitalize what is typed into it.
      {200, reply} = ask(base, [user("세라, 고마워.")], model: "Aethrion-auto")
      assert reply =~ "세라 · 호감"
      refute reply =~ "울프"

      {200, plain} = ask(base, [user("세라, 고마워.")], model: "Aethrion-Auto-Plain")
      assert plain == "세라가 고개를 끄덕인다."
    end

    test "a narrator card: people join as the story brings them in", %{base: base} do
      card = [card: "NARRATOR CARD: an isekai world. You narrate."]
      first = user("주변을 둘러본다. 가장 가까운 사람에게 말을 건다.")
      {200, one} = ask(base, [first], card)

      # No one to track yet; the scene line is taken out of the reply and
      # kept in the status block's tag.
      assert one =~
               ~r/\A버스가 멈춘다. 옆자리의 하루카가 고개를 든다.\n\n<aethrion-status id="[0-9a-f]+" scene="하루카\|조용한 도서부원">/

      refute one =~ "<aethrion-scene"
      refute one =~ "호감"

      # The next line is said to Haruka, who is now in the cast.
      second = user("고마워요, 하루카. 덕분에 살았어요.")
      {200, two} = ask(base, [first, reply(one), second], card)
      assert two =~ ~r/하루카 · 호감 \d+ \(\+\d+\)/
      assert two =~ ~s(scene="하루카;켄지|운동부 주장")

      # A reroll: the same numbers.
      {200, again} = ask(base, [first, reply(one), second], card)
      assert status(again) == status(two)

      # Kenji is there for the third line, and sees it; then Haruka leaves.
      third = user("하루카, 이거 받아요. 선물이에요.")
      {200, three} = ask(base, [first, reply(one), second, reply(two), third], card)
      assert three =~ "켄지 · 호감 0 · 신뢰 0"
      assert three =~ "목격 · 켄지"
      assert three =~ ~s(scene="켄지">)
      assert three =~ "<가방>만 남았다."

      # Haruka is away: she is not listed, and does not see what Kenji is told.
      fourth = user("켄지, 고마워.")

      {200, four} =
        ask(base, [first, reply(one), second, reply(two), third, reply(three), fourth], card)

      assert four =~ ~r/켄지 · 호감 \d+ \(\+\d+\)/
      refute status(four) =~ "하루카"
      assert card_reads() == 1
    end

    test "the scene line is held back from a reply as it is streamed", %{base: base} do
      body =
        Jason.encode!(%{
          "model" => "aethrion-auto",
          "stream" => true,
          "messages" => [
            %{"role" => "system", "content" => "NARRATOR CARD: an isekai world."},
            user("주변을 둘러본다.")
          ]
        })

      {:ok, {{_v, 200, _r}, _headers, events}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json", body},
          [],
          body_format: :binary
        )

      text =
        for "data: " <> data <- String.split(events, "\n\n", trim: true),
            data != "[DONE]",
            %{"choices" => [%{"delta" => %{"content" => content}}]} <- [Jason.decode!(data)],
            into: "",
            do: content

      assert text =~
               ~r/\A버스가 멈춘다. 옆자리의 하루카가 고개를 든다.\s+<aethrion-status id="[0-9a-f]+" scene="하루카\|조용한 도서부원">/

      refute text =~ "<aethrion-scene"
    end

    test "is listed among the models", %{base: base} do
      {:ok, {{_v, 200, _r}, _headers, body}} =
        :httpc.request(:get, {String.to_charlist(base <> "/v1/models"), []}, [],
          body_format: :binary
        )

      ids = for %{"id" => id} <- Jason.decode!(body)["data"], do: id
      assert "aethrion-auto" in ids
      assert "aethrion-auto-plain" in ids
    end

    defp status(reply) do
      [_all, status] = Regex.run(~r/(<aethrion-status.*<\/aethrion-status>)/s, reply)
      status
    end
  end
end
