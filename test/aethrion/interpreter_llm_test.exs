defmodule Aethrion.InterpreterLLMTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Interpreter, State}
  alias Aethrion.LLM.{Backend, CLI}

  # A model that answers from a table, and shows what it was asked.
  defmodule Table do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(_request, _opts), do: {:ok, "..."}

    @impl true
    def complete(system, user, opts) do
      send(self(), {:asked, system, user})
      Keyword.fetch!(opts, :reply)
    end
  end

  defp cast(name) do
    {:ok, state} = "priv/casts/#{name}.json" |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  defp read(state, to, text, reply) do
    Interpreter.read(state, "user", to, text,
      interpreter: Interpreter.LLM,
      interpreter_opts: [adapter: Table, adapter_opts: [reply: reply]]
    )
  end

  test "the model is told what is possible, and its choices become events" do
    reply =
      {:ok,
       ~s({"readings": [{"does": "talk", "target": "sera", "tone": "warm"}, ) <>
         ~s({"does": "attack", "target": "wolf_grey", "confidence": 0.95}]})}

    assert {:ok, [talk, attack], %{status: :ok}} =
             read(cast("den"), "doyun", "세라님, 감사합니다! 회색 늑대를 내려칩니다", reply)

    assert %{as: :talk, event: %{type: :message_sent, to: "sera", tone: :warm}} = talk
    assert %{as: :combat, event: %{type: :attack, to: "wolf_grey"}, confidence: 0.95} = attack

    assert_received {:asked, system, user}
    assert system =~ "readings"
    assert user =~ "wolf_grey (회색 늑대): enemy"
    assert user =~ "Companions who can heal: sera"
    assert user =~ ~s("세라님, 감사합니다! 회색 늑대를 내려칩니다")
  end

  test "a gift's item comes from the model, an activity from the story" do
    summer = cast("summer")

    assert {:ok, [%{event: %{type: :gift_received, item: "아이스크림"}}], _} =
             read(
               summer,
               "seoyun",
               "너 좋아하는 아이스크림 사 왔어",
               {:ok, ~s({"readings": [{"does": "gift", "item": "아이스크림"}]})}
             )

    assert {:ok, [%{event: %{type: :activity, activity: "그림"}}], _} =
             read(
               summer,
               "seoyun",
               "수채화 연습하자",
               {:ok, ~s(```json\n{"readings": [{"does": "activity", "activity": "그림"}]}\n```)}
             )
  end

  test "the rules stand in when the model fails or answers nonsense" do
    quest = cast("quest")

    assert {:ok, [%{event: %{type: :attack}}], %{status: :fallback, reason: :timeout}} =
             read(quest, "kael", "늑대왕을 벤다", {:error, :timeout})

    assert {:ok, _readings, %{status: :fallback, reason: {:not_json, _}}} =
             read(quest, "kael", "늑대왕을 벤다", {:ok, "I think it's an attack"})

    assert {:ok, _readings, %{status: :fallback, reason: {:not_an_option, "activity", "춤"}}} =
             read(
               cast("summer"),
               "seoyun",
               "춤추자",
               {:ok, ~s({"readings": [{"does": "activity", "activity": "춤"}]})}
             )
  end

  @tag :tmp_dir
  test "a CLI on this machine is a backend", %{tmp_dir: dir} do
    fake = Path.join(dir, "fake-claude")
    File.write!(fake, ~s(#!/bin/sh\necho '{"readings": [{"does": "talk", "tone": "neutral"}]}'\n))
    File.chmod!(fake, 0o755)

    assert {:ok, ~s({"readings": [{"does": "talk", "tone": "neutral"}]})} =
             CLI.complete("system", "user", command: fake)

    assert {:error, {:command_not_found, "no-such-cli"}} =
             CLI.complete("s", "u", command: "no-such-cli")
  end

  test "backends by name" do
    assert {:ok, Aethrion.LLM.OpenAICompatible, opts, "Ollama (qwen3)"} =
             Backend.resolve("ollama", model: "qwen3")

    assert opts[:base_url] == "http://localhost:11434/v1"
    assert {:error, message} = Backend.resolve("ollama")
    assert message =~ "--model"
    assert {:error, message} = Backend.resolve("gpt-9")
    assert message =~ "anthropic"
  end
end
