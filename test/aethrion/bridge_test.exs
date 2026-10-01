defmodule Aethrion.BridgeTest do
  use ExUnit.Case, async: false

  alias Aethrion.{API, Bridge, State, Worlds}

  # A model that answers every chat with a fixed line, and keeps what it was sent.
  defmodule Narrator do
    @behaviour Aethrion.LLM.Adapter
    @impl true
    def render(_request, _opts), do: {:ok, "..."}
    @impl true
    def complete(_system, _user, _opts), do: {:ok, "(narration)"}

    def chat(messages, _opts) do
      Agent.update(__MODULE__, &[messages | &1])
      {:ok, "늑대가 으르렁거린다."}
    end
  end

  defp cast(name) do
    {:ok, state} = "priv/casts/#{name}.json" |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  # How RisuAI lays a chat out: card and examples, a marker, the greeting, the history.
  defp risu(history) do
    [
      %{"role" => "system", "content" => "You are the narrator of a wolf den."},
      %{"role" => "user", "content" => "example: I attack"},
      %{"role" => "assistant", "content" => "example: you swing"},
      %{"role" => "system", "content" => "[Start a new chat]"},
      %{"role" => "assistant", "content" => "늑대들이 굴 앞을 막아선다."}
    ] ++ history ++ [%{"role" => "system", "content" => "Keep replies short."}]
  end

  setup do
    start_supervised!(%{
      id: Narrator,
      start: {Agent, :start_link, [fn -> [] end, [name: Narrator]]}
    })

    start_supervised!(Aethrion.Bridge.Readings)
    start_supervised!({Worlds, name: Worlds.Test.Bridge, world: fn _key -> [] end})

    pid =
      start_supervised!(
        {API,
         worlds: Worlds.Test.Bridge,
         port: 0,
         locale: :ko,
         cast: cast("den"),
         intent: [adapter: Narrator],
         interpreter: Aethrion.Interpreter.Rules}
      )

    %{base: "http://127.0.0.1:#{API.port(pid)}"}
  end

  defp post(base, body) do
    {:ok, {{_v, status, _r}, headers, response}} =
      :httpc.request(
        :post,
        {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json",
         Jason.encode!(body)},
        [],
        body_format: :binary
      )

    {status, Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end), response}
  end

  defp reply(base, history, extra \\ %{}) do
    {200, _headers, body} =
      post(base, Map.merge(%{"model" => "aethrion:sera", "messages" => risu(history)}, extra))

    %{"choices" => [%{"message" => %{"content" => content}}]} = Jason.decode!(body)
    content
  end

  defp status_line(content, who) do
    [_, block] = Regex.run(~r/<aethrion-status>(.*)<\/aethrion-status>/s, content)
    block |> String.split("\n") |> Enum.find(&String.starts_with?(&1, who))
  end

  test "the chat proper starts after the app's marker, and status blocks are taken out" do
    {all, chat} =
      Bridge.transcript(
        risu([
          %{"role" => "user", "content" => "다이어 울프를 벤다"},
          %{
            "role" => "assistant",
            "content" => "벤다!\n\n<aethrion-status>다이어 울프 · HP 31/37</aethrion-status>"
          }
        ])
      )

    assert Enum.map(chat, & &1["role"]) == ["assistant", "user", "assistant", "system"]
    refute Enum.any?(all, &(&1["content"] =~ "aethrion-status"))
  end

  test "a reply carries the rules' result; a reroll does not apply the move twice; an edit changes it",
       %{base: base} do
    attack = [%{"role" => "user", "content" => "다이어 울프에게 롱소드를 휘두른다"}]
    first = reply(base, attack)
    assert first =~ "늑대가 으르렁거린다."
    wolf = status_line(first, "다이어 울프")
    assert wolf =~ ~r/HP \d+\/37/

    # The model was told what happened, as facts not to change.
    [sent | _] = Agent.get(Narrator, & &1)
    %{"role" => "system", "content" => note} = List.last(sent)
    assert note =~ "the game's rules"
    assert note =~ "d20"

    # A reroll: the same history again. The wolf is hit once, not twice.
    assert status_line(reply(base, attack), "다이어 울프") == wolf

    # Next turn, after the reply, then an edit of that turn.
    history =
      attack ++
        [
          %{"role" => "assistant", "content" => first},
          %{"role" => "user", "content" => "방패를 들어 막는다"}
        ]

    assert reply(base, history) =~ "<aethrion-status>"

    edited =
      attack ++
        [
          %{"role" => "assistant", "content" => first},
          %{"role" => "user", "content" => "다이어 울프를 다시 벤다"}
        ]

    assert status_line(reply(base, edited), "다이어 울프") != wolf
  end

  test "plain model names leave the status out; streams are server-sent events", %{base: base} do
    plain = reply(base, [%{"role" => "user", "content" => "안녕"}], %{"model" => "aethrion-plain"})
    refute plain =~ "aethrion-status"

    {200, headers, events} =
      post(base, %{
        "model" => "aethrion",
        "stream" => true,
        "messages" => risu([%{"role" => "user", "content" => "안녕"}])
      })

    assert headers["content-type"] =~ "text/event-stream"
    assert headers["access-control-allow-origin"] == "*"
    assert events =~ ~s("content":"늑대가)
    assert String.ends_with?(events, "data: [DONE]\n\n")
  end

  test "models, preflight, and mistakes", %{base: base} do
    {:ok, {{_v, 200, _r}, _h, models}} = :httpc.request(String.to_charlist(base <> "/v1/models"))
    assert %{"data" => [%{"id" => "aethrion"} | _] = list} = Jason.decode!(models)
    assert Enum.any?(list, &(&1["id"] == "aethrion:sera"))

    {:ok, {{_v, 204, _r}, headers, _}} =
      :httpc.request(:options, {String.to_charlist(base <> "/v1/chat/completions"), []}, [], [])

    assert {~c"access-control-allow-origin", ~c"*"} in headers

    assert {400, _h, body} = post(base, %{"model" => "aethrion:ghost", "messages" => risu([])})
    assert body =~ "ghost"
    assert {400, _h, _body} = post(base, %{"model" => "aethrion"})
  end
end
