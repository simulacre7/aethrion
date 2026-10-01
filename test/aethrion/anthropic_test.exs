defmodule Aethrion.LLM.AnthropicTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Expression, Intent, Runtime, StubHTTPServer}
  alias Aethrion.Expression.Request
  alias Aethrion.LLM.Anthropic

  @request %Request{
    kind: :reply,
    reason: :reply,
    speaker: %{name: "Mina"},
    listener: %{name: "you"},
    fallback_text: "That's sweet of you."
  }

  defp message(blocks, stop_reason \\ "end_turn") do
    Jason.encode!(%{
      "type" => "message",
      "role" => "assistant",
      "content" => blocks,
      "stop_reason" => stop_reason
    })
  end

  defp stub(response, status \\ 200) do
    {:ok, base_url, _pid} = StubHTTPServer.start(fn _request -> {status, response} end)
    [base_url: base_url, api_key: "sk-ant-test"]
  end

  test "overload and rate limits are retried, other errors are not" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    {:ok, base_url, _pid} =
      StubHTTPServer.start(fn _request ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 ->
            {529, ~s({"type":"error","error":{"type":"overloaded_error"}}),
             [{"retry-after", "0"}]}

          _ ->
            {200, message([%{"type" => "text", "text" => "Hello!"}])}
        end
      end)

    assert {:ok, "Hello!"} =
             Anthropic.render(@request, base_url: base_url, api_key: "sk-ant-test")

    assert Agent.get(calls, & &1) == 2

    {:ok, bad_request, _pid} =
      StubHTTPServer.start(fn _request ->
        {400, ~s({"type":"error","error":{"type":"invalid_request_error","message":"no"}})}
      end)

    assert {:error, {:api_error, 400, "invalid_request_error", "no"}} =
             Anthropic.render(@request, base_url: bad_request, api_key: "sk-ant-test")

    assert_received {:stub_request, _first}
    assert_received {:stub_request, _second}
    assert_received {:stub_request, _bad}
    refute_received {:stub_request, _retried}
  end

  test "sends a Messages API request and returns only the text blocks" do
    opts =
      stub(
        message([
          %{"type" => "thinking", "thinking" => ""},
          %{"type" => "text", "text" => "\"Oh, that's lovely.\""}
        ])
      )

    assert {:ok, "Oh, that's lovely."} = Anthropic.render(@request, opts)

    assert_received {:stub_request, request}
    assert request.path == "/v1/messages"
    assert request.headers["x-api-key"] == "sk-ant-test"
    assert request.headers["anthropic-version"] == "2023-06-01"
    assert request.headers["anthropic-beta"] == "server-side-fallback-2026-07-01"

    body = Jason.decode!(request.body)
    assert body["model"] == "claude-opus-5-5"
    assert body["output_config"] == %{"effort" => "low"}
    assert body["fallbacks"] == "default"
    assert body["system"] =~ "Your job is to phrase it."
    assert [%{"role" => "user", "content" => content}] = body["messages"]
    assert content =~ "Draft line: That's sweet of you."
    refute Map.has_key?(body, "temperature")
  end

  test "language: asks the model to write in that language" do
    opts = stub(message([%{"type" => "text", "text" => "다정하네."}]))

    assert {:ok, "다정하네."} = Anthropic.render(@request, [language: "Korean"] ++ opts)

    assert_received {:stub_request, request}
    assert Jason.decode!(request.body)["system"] =~ "Write the line in Korean"
  end

  test "fallbacks are only sent for models that support them, and can be disabled" do
    opts = stub(message([%{"type" => "text", "text" => "hi"}]))

    assert {:ok, "hi"} = Anthropic.render(@request, opts ++ [model: "claude-haiku-4-5"])
    assert_received {:stub_request, %{headers: headers, body: body}}
    refute Map.has_key?(headers, "anthropic-beta")
    refute Map.has_key?(Jason.decode!(body), "fallbacks")

    config = %{
      model: "claude-opus-5-5",
      max_tokens: 10,
      effort: "low",
      fallbacks: false
    }

    refute Map.has_key?(Anthropic.request_body(config, "s", "c"), :fallbacks)
  end

  test "refusals keep the deterministic fallback text" do
    opts =
      stub(
        message([], "refusal")
        |> Jason.decode!()
        |> Map.put("stop_details", %{"category" => nil})
        |> Jason.encode!()
      )

    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {_state, outputs} = dispatch!(state, Event.time_tick("t2", hours: 2))

    rendered = Expression.render(outputs, adapter: Anthropic, adapter_opts: opts)

    for {before, output} <- Enum.zip(outputs, rendered), Aethrion.Output.expressive?(before) do
      assert output.text == before.text
      assert %{status: :fallback, reason: {:refusal, %{"category" => nil}}} = output.expression
    end
  end

  test "API errors are reported with their type" do
    error =
      Jason.encode!(%{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
      })

    assert {:error, {:api_error, 529, "overloaded_error", "Overloaded"}} =
             Anthropic.render(@request, stub(error, 529) ++ [retries: 0])
  end

  test "interprets intents from JSON text" do
    opts =
      stub(message([%{"type" => "text", "text" => ~s({"intent": "message", "tone": "hostile"})}]))

    assert {:ok, %{type: :message_sent, tone: :hostile}, %{status: :ok}} =
             Intent.interpret(Runtime.demo_state(), "ugh",
               to: "mina",
               adapter: Anthropic,
               adapter_opts: opts
             )
  end

  test "an api key is required" do
    assert {:error, :missing_api_key} = Anthropic.config(api_key: "")
    assert {:error, :missing_api_key} = Anthropic.render(@request, api_key: "")
  end
end
