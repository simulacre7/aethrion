defmodule Aethrion.LLM.OpenAICompatibleTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Expression, Intent, Runtime, StubHTTPServer}
  alias Aethrion.LLM.OpenAICompatible

  defp completion(content) do
    Jason.encode!(%{
      "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}]
    })
  end

  defp jealous_outputs do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {_state, outputs} = dispatch!(state, Event.time_tick("t2", hours: 2))
    outputs
  end

  test "renders expressive outputs through a chat completions endpoint" do
    {:ok, base_url, _pid} =
      StubHTTPServer.start(fn _request -> {200, completion(~s("  Did you forget me?  "))} end)

    outputs =
      Expression.render(jealous_outputs(),
        adapter: OpenAICompatible,
        adapter_opts: [base_url: base_url <> "/v1/", model: "test-model", api_key: "sk-test"]
      )

    assert %{text: "Did you forget me?", expression: %{status: :ok}} =
             Enum.find(outputs, &(&1.type == :proactive_message and &1.character_id == "yuna"))

    assert_received {:stub_request, request}
    assert request.method == "POST"
    assert request.path == "/v1/chat/completions"
    assert request.headers["authorization"] == "Bearer sk-test"

    body = Jason.decode!(request.body)
    assert body["model"] == "test-model"
    assert [%{"role" => "system"}, %{"role" => "user", "content" => context}] = body["messages"]
    assert context =~ "Draft line: You looked happy with Mina earlier."
    assert context =~ "yuna saw user give mina a flower."
    assert context =~ "mood: jealous"
  end

  test "language: reaches the system message" do
    {:ok, base_url, _pid} = StubHTTPServer.start(fn _request -> {200, completion("응")} end)

    request = %Aethrion.Expression.Request{
      kind: :reply,
      reason: :reply,
      speaker: %{name: "Mina"},
      listener: %{name: "you"},
      fallback_text: "Sure."
    }

    assert {:ok, "응"} =
             OpenAICompatible.render(request,
               base_url: base_url <> "/v1",
               model: "m",
               language: "Korean"
             )

    assert_received {:stub_request, http}
    assert [%{"role" => "system", "content" => system} | _] = Jason.decode!(http.body)["messages"]
    assert system =~ "Write the line in Korean"
  end

  test "omits the authorization header without an api key" do
    {:ok, base_url, _pid} = StubHTTPServer.start(fn _request -> {200, completion("ok")} end)

    request = %Aethrion.Expression.Request{
      kind: :reply,
      reason: :reply,
      speaker: %{name: "A"},
      listener: %{name: "B"},
      fallback_text: "hi"
    }

    assert {:ok, "ok"} = OpenAICompatible.render(request, base_url: base_url, model: "m")
    assert_received {:stub_request, %{headers: headers}}
    refute Map.has_key?(headers, "authorization")
  end

  test "interprets intents from JSON wrapped in prose or code fences" do
    reply = "Sure!\n```json\n{\"intent\": \"apology\", \"tone\": \"warm\"}\n```"
    {:ok, base_url, _pid} = StubHTTPServer.start(fn _request -> {200, completion(reply)} end)

    assert {:ok, %{type: :apology_offered}, %{status: :ok}} =
             Intent.interpret(Runtime.demo_state(), "my fault, truly",
               to: "yuna",
               adapter: OpenAICompatible,
               adapter_opts: [base_url: base_url, model: "m"]
             )

    assert_received {:stub_request, %{body: body}}
    assert %{"temperature" => 0} = Jason.decode!(body)
  end

  test "provider errors fall back to deterministic text" do
    {:ok, base_url, _pid} =
      StubHTTPServer.start(fn _request -> {500, ~s({"error": {"message": "overloaded"}})} end)

    outputs = jealous_outputs()

    rendered =
      Expression.render(outputs,
        adapter: OpenAICompatible,
        adapter_opts: [base_url: base_url, model: "m", retries: 0]
      )

    for {before, output} <- Enum.zip(outputs, rendered), Aethrion.Output.expressive?(before) do
      assert output.text == before.text

      assert %{status: :fallback, reason: {:http_status, 500, %{"error" => _}}} =
               output.expression
    end
  end

  test "unexpected payloads and empty lines are errors" do
    request = %Aethrion.Expression.Request{
      kind: :reply,
      reason: :reply,
      speaker: %{name: "A"},
      listener: %{name: "B"},
      fallback_text: "hi"
    }

    {:ok, base_url, _pid} = StubHTTPServer.start(fn _request -> {200, ~s({"object": "nope"})} end)

    assert {:error, {:unexpected_response, _}} =
             OpenAICompatible.render(request, base_url: base_url, model: "m")

    {:ok, base_url, _pid} = StubHTTPServer.start(fn _request -> {200, completion("  ")} end)

    assert {:error, :empty_response} =
             OpenAICompatible.render(request, base_url: base_url, model: "m")
  end

  test "slow servers time out" do
    {:ok, base_url, _pid} =
      StubHTTPServer.start(fn _request ->
        Process.sleep(500)
        {200, completion("late")}
      end)

    request = %Aethrion.Expression.Request{
      kind: :reply,
      reason: :reply,
      speaker: %{name: "A"},
      listener: %{name: "B"},
      fallback_text: "hi"
    }

    assert {:error, {:http_error, :timeout}} =
             OpenAICompatible.render(request, base_url: base_url, model: "m", timeout: 100)
  end

  test "configuration is required" do
    assert {:error, :missing_base_url} = OpenAICompatible.config(base_url: "", model: "m")
    assert {:error, :missing_model} = OpenAICompatible.config(base_url: "http://x", model: "")
    assert OpenAICompatible.configured?(base_url: "http://x", model: "m")
  end
end
