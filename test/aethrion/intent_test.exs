defmodule Aethrion.IntentTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Intent, Runtime}

  defmodule ScriptedAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(request, _opts), do: {:ok, request.fallback_text}

    @impl true
    def interpret(_request, opts), do: Keyword.fetch!(opts, :reply)
  end

  defmodule RenderOnlyAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(request, _opts), do: {:ok, request.fallback_text}
  end

  setup do
    %{state: Runtime.demo_state()}
  end

  test "the fake adapter maps text to intents and tones", %{state: state} do
    cases = [
      {"I'm so sorry about earlier", :apology_offered, nil},
      {"Thank you, that was sweet", :message_sent, :warm},
      {"Just go away", :message_sent, :hostile},
      {"whatever, I'm busy", :message_sent, :cold},
      {"What are you reading?", :message_sent, :neutral}
    ]

    for {text, type, tone} <- cases do
      assert {:ok, event, %{status: :ok}} = Intent.interpret(state, text, to: "mina")
      assert event.type == type
      assert event.from == "user"
      assert event.to == "mina"
      if tone, do: assert(event.tone == tone)
    end
  end

  test "apologies keep the user's words as the reason", %{state: state} do
    assert {:ok, %{type: :apology_offered, reason: "Sorry I left early."}, _meta} =
             Intent.interpret(state, "  Sorry I left early.  ", to: "yuna")
  end

  test "adapter proposals are normalized from strings", %{state: state} do
    reply = {:ok, %{"intent" => " Message ", "tone" => "WARM"}}

    assert {:ok, %{type: :message_sent, tone: :warm}, %{status: :ok}} =
             Intent.interpret(state, "hmm",
               to: "mina",
               adapter: ScriptedAdapter,
               adapter_opts: [reply: reply]
             )
  end

  test "proposals outside the allowed set fall back to the fake interpretation", %{state: state} do
    for reply <- [
          {:ok, %{intent: :declare_war}},
          {:ok, %{intent: :message, tone: :furious}},
          {:ok, "apology"},
          {:error, :timeout},
          :garbage
        ] do
      assert {:ok, event, %{status: :fallback}} =
               Intent.interpret(state, "thank you",
                 to: "mina",
                 adapter: ScriptedAdapter,
                 adapter_opts: [reply: reply]
               )

      assert event.tone == :warm
    end
  end

  test "a message proposal without a tone is neutral", %{state: state} do
    assert {:ok, %{tone: :neutral}, %{status: :ok}} =
             Intent.interpret(state, "hmm",
               to: "mina",
               adapter: ScriptedAdapter,
               adapter_opts: [reply: {:ok, %{intent: "message"}}]
             )
  end

  test "adapters without interpret/2 fall back", %{state: state} do
    assert {:ok, %{type: :apology_offered},
            %{status: :fallback, reason: :interpret_not_supported}} =
             Intent.interpret(state, "sorry", to: "mina", adapter: RenderOnlyAdapter)
  end

  test "interpretation proposes an event but does not dispatch it", %{state: state} do
    assert {:ok, event, _meta} = Intent.interpret(state, "I hate this", to: "mina")
    assert state == Runtime.demo_state()
    assert {:ok, next_state, _outputs, _log} = Runtime.dispatch(state, event)
    assert next_state.characters["mina"].state.stress == 20
  end

  test "empty text and unknown targets are rejected", %{state: state} do
    assert {:error, %{code: :invalid_event}} = Intent.interpret(state, "   ", to: "mina")
    assert {:error, %{code: :unknown_character}} = Intent.interpret(state, "hi", to: "nobody")
  end
end
