defmodule Aethrion.StreamingTest do
  use ExUnit.Case, async: false

  alias Aethrion.{API, State, StubHTTPServer, Worlds}
  alias Aethrion.LLM.{Anthropic, HTTP, OpenAICompatible}

  defp sse(events), do: Enum.map_join(events, "", &"data: #{&1}\n\n")

  defp collect(fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    result = fun.(fn delta -> Agent.update(agent, &[delta | &1]) end)
    deltas = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)
    {result, deltas}
  end

  test "server-sent events are split into complete events and what is still coming" do
    assert {["a", "b\nc"], "data: par"} =
             HTTP.sse_events("data: a\n\nevent: x\ndata: b\ndata: c\r\n\r\n: ping\n\ndata: par")

    assert {[], ""} = HTTP.sse_events("")
  end

  describe "OpenAI-compatible" do
    test "streams the reply piece by piece" do
      chunk = &Jason.encode!(%{"choices" => [%{"delta" => %{"content" => &1}}]})

      {:ok, base_url, _pid} =
        StubHTTPServer.start(fn _request ->
          {200, sse([chunk.(""), chunk.("늑대가 "), chunk.("으르렁거린다."), "[DONE]"])}
        end)

      {result, deltas} =
        collect(
          &OpenAICompatible.stream_chat(
            [%{"role" => "user", "content" => "안녕"}],
            [base_url: base_url <> "/v1", model: "m", api_key: "k"],
            &1
          )
        )

      assert result == {:ok, "늑대가 으르렁거린다."}
      assert deltas == ["늑대가 ", "으르렁거린다."]
      assert_received {:stub_request, request}
      assert %{"stream" => true, "model" => "m"} = Jason.decode!(request.body)
      assert request.headers["accept"] == "text/event-stream"
    end

    test "a server that answers whole gives one piece; an error status is an error" do
      whole =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "응"}}]
        })

      {:ok, base_url, _pid} = StubHTTPServer.start(fn _request -> {200, whole} end)
      opts = [base_url: base_url <> "/v1", model: "m"]
      message = [%{"role" => "user", "content" => "안녕"}]

      assert {{:ok, "응"}, ["응"]} = collect(&OpenAICompatible.stream_chat(message, opts, &1))

      {:ok, base_url, _pid} =
        StubHTTPServer.start(fn _request -> {401, ~s({"error":{"message":"no"}})} end)

      assert {{:error, {:http_status, 401, _body}}, []} =
               collect(
                 &OpenAICompatible.stream_chat(message, [base_url: base_url, model: "m"], &1)
               )
    end
  end

  test "Anthropic streams text deltas" do
    events = [
      Jason.encode!(%{"type" => "message_start", "message" => %{}}),
      Jason.encode!(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => "모닥불이 "}
      }),
      Jason.encode!(%{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => "탁 튄다."}
      }),
      Jason.encode!(%{"type" => "message_stop"})
    ]

    {:ok, base_url, _pid} = StubHTTPServer.start(fn _request -> {200, sse(events)} end)

    {result, deltas} =
      collect(
        &Anthropic.stream_chat(
          [%{"role" => "system", "content" => "narrate"}, %{"role" => "user", "content" => "안녕"}],
          [base_url: base_url, api_key: "k", fallbacks: false],
          &1
        )
      )

    assert result == {:ok, "모닥불이 탁 튄다."}
    assert deltas == ["모닥불이 ", "탁 튄다."]
    assert_received {:stub_request, request}
    assert %{"stream" => true, "system" => "narrate"} = Jason.decode!(request.body)
  end

  # A narrator that writes its reply in pieces, or fails.
  defmodule StreamNarrator do
    @behaviour Aethrion.LLM.Adapter
    @impl true
    def render(_request, _opts), do: {:ok, "..."}
    @impl true
    def complete(_system, _user, _opts), do: {:ok, "(narration)"}

    def chat(_messages, _opts), do: {:ok, "\n늑대가 으르렁거린다."}

    def stream_chat(messages, _opts, on_delta) do
      if Enum.any?(messages, &(&1["content"] == "실패해")) do
        {:error, :boom}
      else
        for piece <- ["\n", "늑대가 ", "으르렁거린다."], do: on_delta.(piece)
        {:ok, "\n늑대가 으르렁거린다."}
      end
    end
  end

  describe "the bridge" do
    setup do
      start_supervised!({Aethrion.Bridge.Store, name: Aethrion.Bridge.Readings})
      start_supervised!({Aethrion.Bridge.Store, name: Aethrion.Bridge.Checkpoints})
      start_supervised!({Worlds, name: Worlds.Test.Streaming, world: fn _key -> [] end})

      {:ok, den} = "priv/casts/den.json" |> File.read!() |> Jason.decode!() |> State.parse()

      pid =
        start_supervised!(
          {API,
           worlds: Worlds.Test.Streaming,
           port: 0,
           locale: :ko,
           cast: den,
           intent: [adapter: StreamNarrator],
           interpreter: Aethrion.Interpreter.Rules}
        )

      %{base: "http://127.0.0.1:#{API.port(pid)}"}
    end

    defp stream(base, line) do
      body =
        Jason.encode!(%{
          "model" => "aethrion",
          "stream" => true,
          "messages" => [%{"role" => "user", "content" => line}]
        })

      {:ok, {{_v, status, _r}, headers, events}} =
        :httpc.request(
          :post,
          {String.to_charlist(base <> "/v1/chat/completions"), [], ~c"application/json", body},
          [],
          body_format: :binary
        )

      headers = Map.new(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
      {status, headers, events}
    end

    defp contents(events) do
      for "data: " <> data <- String.split(events, "\n\n", trim: true),
          data != "[DONE]",
          %{"choices" => [%{"delta" => %{"content" => content}}]} <- [Jason.decode!(data)],
          content != "",
          do: content
    end

    test "sends the reply as the model writes it, the status block last", %{base: base} do
      {200, headers, events} = stream(base, "다이어 울프를 벤다")

      assert headers["content-type"] =~ "text/event-stream"
      assert ["늑대가 ", "으르렁거린다.", "\n\n<aethrion-status" <> _] = contents(events)
      assert String.ends_with?(events, "data: [DONE]\n\n")
    end

    test "a model that fails mid-stream ends it with an error event", %{base: base} do
      {200, _headers, events} = stream(base, "실패해")

      assert events =~ ~s("code":"model_failed")
      refute events =~ "aethrion-status"
      assert String.ends_with?(events, "data: [DONE]\n\n")
    end
  end
end
