defmodule Aethrion.APITest do
  use ExUnit.Case, async: false

  alias Aethrion.{API, Worlds}

  defmodule ParrotAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(request, _opts), do: {:ok, "(model) " <> request.fallback_text}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "aethrion-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!(
      {Worlds,
       name: Worlds.Test.API,
       world: fn
         "rendered" = key ->
           [journal: Path.join(dir, "#{key}.jsonl"), expression: [adapter: ParrotAdapter]]

         key ->
           [journal: Path.join(dir, Worlds.file_name(key) <> ".jsonl")]
       end}
    )

    pid = start_supervised!({API, worlds: Worlds.Test.API, port: 0, token: "secret"})
    %{base: "http://127.0.0.1:#{API.port(pid)}", dir: dir}
  end

  defp request(method, url, body \\ nil, token \\ "secret") do
    headers =
      if token, do: [{~c"authorization", ~c"Bearer " ++ String.to_charlist(token)}], else: []

    request =
      case body do
        nil -> {String.to_charlist(url), headers}
        body -> {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}
      end

    {:ok, {{_version, status, _reason}, _headers, response}} =
      :httpc.request(method, request, [], body_format: :binary)

    {status, Jason.decode!(response)}
  end

  test "health, and a token is required", %{base: base} do
    assert {200, %{"ok" => true}} = request(:get, base <> "/health", nil, nil)

    assert {401, %{"error" => %{"code" => "unauthorized"}}} =
             request(:get, base <> "/worlds/a/state", nil, nil)

    assert {401, _body} = request(:get, base <> "/worlds/a/state", nil, "wrong")

    # The chat page holds no data and loads without a token.
    {:ok, {{_version, 200, _reason}, headers, html}} =
      :httpc.request(:get, {String.to_charlist(base <> "/"), []}, [], body_format: :binary)

    assert {~c"content-type", ~c"text/html; charset=utf-8"} in headers
    assert html =~ "<title>Aethrion Chat</title>"
  end

  test "free text in, what characters say out, in any language", %{base: base} do
    assert {200, body} =
             request(:post, base <> "/worlds/alice/say", %{"to" => "mina", "text" => "고마워, 진짜로"})

    assert %{"interpreted" => %{"type" => "message_sent", "tone" => "warm"}, "event_id" => "e1"} =
             body

    assert [%{"type" => "reply", "character_id" => "mina", "to" => "user", "rendered" => false}] =
             body["lines"]

    assert {200, %{"turns" => [first, _reply]}} =
             request(:get, base <> "/worlds/alice/conversation?character=mina")

    assert first["text"] == "고마워, 진짜로"

    # Polling for what is new.
    {200, _body} =
      request(:post, base <> "/worlds/alice/say", %{"to" => "mina", "text" => "또 보자"})

    assert {200, %{"turns" => [%{"text" => "또 보자"}, %{"from" => "mina"}]}} =
             request(:get, base <> "/worlds/alice/conversation?character=mina&after=e1")

    long = String.duplicate("가", 2_001)

    assert {400, %{"error" => %{"code" => "text_too_long"}}} =
             request(:post, base <> "/worlds/alice/say", %{"to" => "mina", "text" => long})
  end

  test "events in the scenario format", %{base: base} do
    gift = %{
      "type" => "gift_received",
      "from" => "user",
      "to" => "mina",
      "item" => "tea",
      "observed_by" => ["yuna"]
    }

    assert {200, %{"lines" => [%{"text" => "Thank you for the tea!"}], "outputs" => outputs}} =
             request(:post, base <> "/worlds/bob/events", gift)

    assert Enum.any?(outputs, &(&1["type"] == "memory_created"))

    tick = %{"type" => "time_tick", "hours" => 2, "now" => "later"}
    assert {200, %{"lines" => lines}} = request(:post, base <> "/worlds/bob/events", tick)
    assert Enum.any?(lines, &(&1["character_id"] == "yuna" and &1["type"] == "proactive_message"))

    assert {200, %{"clock" => 2}} = request(:get, base <> "/worlds/bob/state")

    assert {200, %{"characters" => characters}} = request(:get, base <> "/worlds/bob/characters")
    mina = Enum.find(characters, &(&1["id"] == "mina"))

    assert %{
             "name" => "Mina",
             "mood" => _,
             "toward" => %{"id" => "user", "bond" => _, "affinity" => _}
           } = mina
  end

  test "a world that renders with a model answers with the model's lines", %{base: base} do
    assert {200, %{"lines" => [line]}} =
             request(:post, base <> "/worlds/rendered/say", %{
               "to" => "mina",
               "text" => "thank you!"
             })

    assert %{"rendered" => true, "text" => "(model) " <> _} = line
  end

  test "reads do not create worlds, and polling has a cursor", %{base: base, dir: dir} do
    assert {200, %{"characters" => [_ | _]}} = request(:get, base <> "/worlds/reader/characters")
    assert {200, %{"turns" => []}} = request(:get, base <> "/worlds/reader/conversation")
    assert File.ls!(dir) == []

    gift = %{
      "type" => "gift_received",
      "from" => "user",
      "to" => "mina",
      "item" => "tea",
      "observed_by" => ["yuna"]
    }

    {200, _body} = request(:post, base <> "/worlds/reader/events", gift)

    {200, step} =
      request(:post, base <> "/worlds/reader/events", %{"type" => "time_tick", "hours" => 2})

    assert %{"event_id" => "e2", "last_event_id" => last} = step
    assert last != "e2"
    assert Enum.all?(step["lines"], &is_binary(&1["event_id"]))

    # Every thread of the person at once; nothing after the step's last event.
    assert {200, %{"turns" => turns}} = request(:get, base <> "/worlds/reader/conversation")
    assert Enum.any?(turns, &(&1["from"] == "yuna")) and Enum.any?(turns, &(&1["from"] == "mina"))

    assert {200, %{"turns" => []}} =
             request(:get, base <> "/worlds/reader/conversation?after=" <> last)
  end

  test "a world that cannot start is a 503, without its insides", %{base: base, dir: dir} do
    File.write!(Path.join(dir, Worlds.file_name("broken") <> ".jsonl"), "not a journal\n")

    assert {503, %{"error" => %{"code" => "world_failed", "message" => message}}} =
             request(:post, base <> "/worlds/broken/say", %{"to" => "mina", "text" => "hi"})

    refute message =~ "journal"
  end

  test "a fight from words, with the ending it settles", %{base: base, dir: dir} do
    {:ok, quest} =
      "priv/casts/quest.json" |> File.read!() |> Jason.decode!() |> Aethrion.State.parse()

    quest = put_in(quest.stats["wolf"]["hp"], 1)
    :ok = Aethrion.Journal.create(Path.join(dir, Worlds.file_name("quest") <> ".jsonl"), quest)

    assert {200, %{"interpreted" => %{"type" => "attack"}, "lines" => lines}} =
             request(:post, base <> "/worlds/quest/act", %{
               "to" => "wolf",
               "text" => "I swing my sword!"
             })

    assert [%{"type" => "combat", "kind" => _hit, "to" => "wolf"} | _] = lines
    assert Enum.any?(lines, &(&1["type"] == "combat" and &1["kind"] == "defeated"))
    assert %{"type" => "ending_reached", "title" => _title} = List.last(lines)

    assert {200, %{"reached" => %{"id" => _id}, "endings" => [%{"closeness" => _} | _]}} =
             request(:get, base <> "/worlds/quest/story")
  end

  test "one chat line, read as what it does: a day spent, a gift, talk, or a move in a fight",
       %{base: base, dir: dir} do
    for {key, cast} <- [{"summer", "priv/casts/summer.json"}, {"fight", "priv/casts/quest.json"}] do
      {:ok, state} = cast |> File.read!() |> Jason.decode!() |> Aethrion.State.parse()
      :ok = Aethrion.Journal.create(Path.join(dir, Worlds.file_name(key) <> ".jsonl"), state)
    end

    chat = fn key, to, text ->
      request(:post, base <> "/worlds/#{key}/chat", %{"to" => to, "text" => text})
    end

    assert {200, %{"interpreted" => %{"as" => "activity"}}} =
             chat.("summer", "seoyun", "오늘은 같이 그림 그리자")

    assert {200, %{"clock" => 24}} = request(:get, base <> "/worlds/summer/state")

    assert {200, %{"interpreted" => %{"as" => "talk", "tone" => "warm"}, "lines" => [_reply]}} =
             chat.("summer", "seoyun", "네 그림 진짜 좋다")

    assert {200, %{"interpreted" => %{"as" => "gift", "type" => "gift_received"}}} =
             chat.("summer", "seoyun", "물감 새로 사 왔어")

    assert {200, %{"interpreted" => %{"as" => "combat", "type" => "attack", "to" => "wolf"}}} =
             chat.("fight", "kael", "카엘, 엄호해 줘! 늑대왕의 목을 노려 벤다")

    assert {200, %{"interpreted" => %{"as" => "talk"}}} = chat.("fight", "kael", "고마워, 카엘")
  end

  test "mistakes are errors with a status", %{base: base} do
    assert {400, %{"error" => %{"code" => "invalid_key"}}} =
             request(:post, base <> "/worlds/..%2Fetc/say", %{"to" => "mina", "text" => "hi"})

    assert {400, %{"error" => %{"code" => "unknown_character"}}} =
             request(:post, base <> "/worlds/carol/say", %{"to" => "nobody", "text" => "hi"})

    assert {400, %{"error" => %{"code" => "invalid_request"}}} =
             request(:post, base <> "/worlds/carol/say", %{"to" => "mina"})

    assert {400, %{"error" => %{"code" => "invalid_event"}}} =
             request(:post, base <> "/worlds/carol/events", %{
               "type" => "gift_received",
               "from" => "user",
               "to" => "mina"
             })

    assert {400, %{"error" => %{"code" => "invalid_request"}}} =
             request(:post, base <> "/worlds/carol/say", %{"to" => "mina", "text" => "  \n "})

    assert {400, %{"error" => %{"message" => "observed_by must be a list of character ids"}}} =
             request(:post, base <> "/worlds/carol/say", %{
               "to" => "mina",
               "text" => "hi",
               "observed_by" => "yuna"
             })

    assert {400, %{"error" => %{"message" => "text must be a string"}}} =
             request(:post, base <> "/worlds/carol/say", %{"to" => "mina", "text" => 42})

    assert {400, %{"error" => %{"code" => "invalid_request"}}} =
             request(:get, base <> "/worlds/carol/conversation?after=soon")

    assert {400, %{"error" => %{"code" => "unknown_character"}}} =
             request(:get, base <> "/worlds/carol/conversation?character=nobody")

    assert {413, %{"error" => %{"code" => "body_too_large"}}} =
             request(:post, base <> "/worlds/carol/say", %{
               "to" => "mina",
               "text" => String.duplicate("a", 70_000)
             })

    assert {404, _body} = request(:get, base <> "/nothing")
    assert {405, _body} = request(:get, base <> "/worlds/carol/say")
    assert Worlds.running(Worlds.Test.API) |> Enum.member?("..%2Fetc") == false
  end
end
