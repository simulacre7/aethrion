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
           [journal: Path.join(dir, "#{key}.jsonl")]
       end}
    )

    pid = start_supervised!({API, worlds: Worlds.Test.API, port: 0, token: "secret"})
    %{base: "http://127.0.0.1:#{API.port(pid)}"}
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
    assert {200, %{"ok" => true}} = request(:get, base <> "/health")

    assert {401, %{"error" => %{"code" => "unauthorized"}}} =
             request(:get, base <> "/health", nil, nil)

    assert {401, _body} = request(:get, base <> "/health", nil, "wrong")
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
  end

  test "a world that renders with a model answers with the model's lines", %{base: base} do
    assert {200, %{"lines" => [line]}} =
             request(:post, base <> "/worlds/rendered/say", %{
               "to" => "mina",
               "text" => "thank you!"
             })

    assert %{"rendered" => true, "text" => "(model) " <> _} = line
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

    assert {404, _body} = request(:get, base <> "/nothing")
    assert {405, _body} = request(:get, base <> "/worlds/carol/say")
    assert Worlds.running(Worlds.Test.API) |> Enum.member?("..%2Fetc") == false
  end
end
