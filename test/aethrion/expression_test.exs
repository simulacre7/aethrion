defmodule Aethrion.ExpressionTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Expression, Runtime}
  alias Aethrion.Expression.Request

  defmodule ShoutAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(%Request{} = request, opts) do
      send(Keyword.get(opts, :notify, self()), {:rendered, request})
      {:ok, "  " <> String.upcase(request.fallback_text) <> "  "}
    end
  end

  defmodule BrokenAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(_request, _opts), do: {:error, :timeout}
  end

  defmodule RaisingAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(_request, _opts), do: raise("provider exploded")
  end

  defmodule EmptyAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(_request, _opts), do: {:ok, ""}
  end

  setup do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {state, outputs} = dispatch!(state, Event.time_tick("t2", hours: 2))
    %{state: state, outputs: outputs}
  end

  test "adapters re-render expressive outputs from their context only", %{outputs: outputs} do
    rendered = Expression.render(outputs, adapter: ShoutAdapter)

    yuna = Enum.find(rendered, &(&1.type == :proactive_message and &1.character_id == "yuna"))

    assert yuna.text == "YOU LOOKED HAPPY WITH MINA EARLIER. I WONDERED IF YOU FORGOT ABOUT ME."
    assert yuna.expression == %{status: :ok, adapter: ShoutAdapter}

    assert_received {:rendered, %Request{kind: :proactive_message, reason: :jealous} = request}
    assert request.speaker.id == "yuna"
    assert [%{kind: :observed, data: %{"to" => "mina"}} | _] = request.memories
  end

  test "non-expressive outputs pass through unchanged", %{outputs: outputs} do
    rendered = Expression.render(outputs, adapter: ShoutAdapter)

    for {before, after_render} <- Enum.zip(outputs, rendered),
        before.type not in Aethrion.Output.expressive_types() do
      assert before == after_render
    end
  end

  test "adapter failures keep the deterministic fallback", %{outputs: outputs} do
    for adapter <- [BrokenAdapter, RaisingAdapter, EmptyAdapter] do
      rendered = Expression.render(outputs, adapter: adapter)

      for {before, output} <- Enum.zip(outputs, rendered), Aethrion.Output.expressive?(before) do
        assert output.text == before.text
        assert %{status: :fallback, adapter: ^adapter} = output.expression
      end
    end
  end

  test "rendering never touches the state", %{state: state, outputs: outputs} do
    snapshot = :erlang.term_to_binary(state)
    _rendered = Expression.render(outputs, adapter: ShoutAdapter)

    assert :erlang.term_to_binary(state) == snapshot
  end

  test "requests are plain data without the runtime state", %{outputs: outputs} do
    for %{context: %Request{} = request} <- outputs do
      refute contains_state?(request)
    end
  end

  test "the fake adapter returns the fallback text", %{outputs: outputs} do
    assert Expression.render(outputs) |> Enum.map(& &1[:text]) == Enum.map(outputs, & &1[:text])
  end

  test "build_request names the user as 'you' for natural phrasing", %{state: state} do
    request =
      Expression.build_request(state, :proactive_message, "yuna", "user", reason: :jealous)

    assert request.names["user"] == "you"
    assert request.listener == %{id: "user", name: "you", profile: nil, traits: [], mood: nil}
    assert request.relationship == %{affinity: 38, trust: 20, tension: 0, bond: :friendly}
  end

  defp contains_state?(%Aethrion.State{}), do: true
  defp contains_state?(%_{} = struct), do: struct |> Map.from_struct() |> contains_state?()

  defp contains_state?(map) when is_map(map),
    do: Enum.any?(map, fn {_k, v} -> contains_state?(v) end)

  defp contains_state?(list) when is_list(list), do: Enum.any?(list, &contains_state?/1)
  defp contains_state?(_value), do: false

  test "prompts map memory ids to names and explain memory kinds" do
    {:ok, state, _outputs, _log} =
      Aethrion.Runtime.dispatch(
        Aethrion.Runtime.demo_state(),
        Aethrion.Event.gift_received("user", "mina", "flower", observed_by: ["yuna"])
      )

    request =
      Aethrion.Expression.build_request(state, :proactive_message, "yuna", "user",
        reason: :jealous
      )

    {system, context} = Aethrion.Expression.Prompt.render_parts(request)

    assert system =~ "call people by the names listed under People"
    assert system =~ "reputation impression"
    assert context =~ "People: mina = Mina, user = you, yuna = Yuna\nMemories:"
  end

  describe "coming back after a while" do
    defp talk(state, tone \\ :warm) do
      {:ok, step} = Runtime.step(state, Event.message_sent("user", "haru", "hi", tone: tone))
      [reply] = of_type(step.outputs, :reply)
      {step.state, reply}
    end

    defp quiet_world do
      Aethrion.State.new(
        characters: [character("haru")],
        relationships: [relationship("haru", "user", affinity: 30, trust: 20)]
      )
    end

    test "a character notices a long absence, and remembers when you last talked" do
      {state, first} = talk(quiet_world())
      assert first.context.since_contact == nil
      assert state.cooldowns["contact:haru:user"] == 0

      {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 20))
      {state, soon} = talk(step.state)
      assert soon.context.since_contact == 20
      refute soon.text =~ "while"
      refute soon.text =~ "back"

      # Loneliness is kept low so the mood stays neutral.
      state = put_in(state.characters["haru"].state.loneliness, 0)
      state = %{state | clock: state.clock + 100}
      {_state, back} = talk(state)

      assert back.context.since_contact == 100
      assert back.text == "You're back! It's been a while. Thank you."
      assert Aethrion.Expression.Templates.Ko.render(back.context) == "오랜만이야! 고마워."

      {_system, context} = Aethrion.Expression.Prompt.render_parts(back.context)
      assert context =~ "Listener just said (warm) (after 100 hours without talking): hi"
    end

    test "a lonely character says it missed you" do
      {state, _reply} = talk(quiet_world())
      {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 100))
      {_state, back} = talk(step.state, :neutral)

      assert back.text == "You're back... I missed you."
      assert Aethrion.Expression.Templates.Ko.render(back.context) == "왔구나... 보고 싶었어."
    end

    test "a lonely character who has not heard from you in days says so" do
      {state, _reply} = talk(quiet_world(), :neutral)
      {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 100))

      assert [%{reason: :lonely, text: text} = message] =
               of_type(step.outputs, :proactive_message)

      assert text == "We haven't talked in a few days. Do you have a minute?"
      assert Aethrion.Expression.Templates.Ko.render(message.context) == "며칠째 얘기를 못 했네. 잠깐 시간 돼?"
    end
  end
end
