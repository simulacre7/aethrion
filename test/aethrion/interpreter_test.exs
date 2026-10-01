defmodule Aethrion.InterpreterTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Interpreter, State}

  # A model stand-in: answers the schema's questions from a fixed table.
  defmodule Scripted do
    @behaviour Aethrion.Interpreter

    @impl true
    def interpret(request, opts) do
      case Map.fetch(Keyword.fetch!(opts, :answers), request.text) do
        {:ok, answers} -> Interpreter.from_answers(request, answers)
        :error -> {:error, :no_answer}
      end
    end
  end

  defp cast(name) do
    {:ok, state} = "priv/casts/#{name}.json" |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  defp read(state, to, text, answers \\ nil) do
    opts =
      if answers,
        do: [interpreter: Scripted, interpreter_opts: [answers: answers]],
        else: []

    Interpreter.read(state, "user", to, text, opts)
  end

  test "the schema comes from the cast: targets with sides, healers, tones, activities" do
    schema = Interpreter.schema(cast("den"), "user", "sera")

    assert schema.fight
    assert %{id: "dire_wolf", side: :enemy} = Enum.find(schema.targets, &(&1.id == "dire_wolf"))
    assert %{id: "sera", side: :party} = Enum.find(schema.targets, &(&1.id == "sera"))
    assert schema.healers == ["sera"]

    assert [%{id: "does", type: :choice} | _] = questions = Interpreter.questions(schema)
    assert Enum.find(questions, &(&1.id == "target")).options |> Enum.member?("wolf_grey")

    assert Interpreter.schema(cast("summer"), "user", "seoyun").activities == ~w(공부 그림 산책 휴식)
  end

  test "the rules read a line into events, talk first" do
    assert {:ok, [talk, move], %{status: :ok}} =
             read(cast("quest"), "kael", "리아, 고마워! 늑대왕의 목을 노려 벤다")

    assert %{as: :talk, event: %{type: :message_sent, to: "ria", tone: :warm}} = talk
    assert %{as: :combat, event: %{type: :attack, to: "wolf"}} = move
  end

  test "a model's answers become the same events" do
    answers = %{
      "베어 버려" => %{"does" => "attack", "target" => "wolf_grey", "confidence" => 0.93},
      "세라 도윤 좀" => %{"does" => "heal", "helper" => "sera", "target" => "doyun"},
      "그림!" => %{"does" => "activity", "activity" => "그림"},
      "흥" => %{"does" => "talk", "tone" => "cold"}
    }

    den = cast("den")

    assert {:ok, [%{as: :combat, event: %{type: :attack, to: "wolf_grey"}, confidence: 0.93}],
            %{status: :ok, interpreter: Scripted}} = read(den, "sera", "베어 버려", answers)

    assert {:ok, [%{event: %{type: :heal, from: "sera", to: "doyun", asked_by: "user"}}], _meta} =
             read(den, "sera", "세라 도윤 좀", answers)

    summer = cast("summer")

    assert {:ok, [%{as: :activity, event: %{activity: "그림", character: "seoyun"}}], _} =
             read(summer, "seoyun", "그림!", answers)

    assert {:ok, [%{as: :talk, event: %{tone: :cold}}], _} = read(summer, "seoyun", "흥", answers)
  end

  test "the rules stand in when a model fails, answers outside the schema, or is unsure" do
    answers = %{
      "늑대왕을 벤다" => %{"does" => "attack", "target" => "dragon"},
      "막는다" => %{"does" => "defend", "confidence" => 0.2},
      "도망" => %{"does" => "dance"}
    }

    quest = cast("quest")

    assert {:ok, [%{event: %{type: :attack, to: "wolf"}}],
            %{status: :fallback, reason: {:unknown_target, "dragon"}}} =
             read(quest, "kael", "늑대왕을 벤다", answers)

    assert {:ok, [%{event: %{type: :defend}}], %{status: :fallback, reason: :unsure}} =
             read(quest, "kael", "막는다", answers)

    assert {:ok, _readings, %{status: :fallback, reason: {:not_an_option, "does", "dance"}}} =
             read(quest, "kael", "도망", answers)

    assert {:ok, _readings, %{status: :fallback, reason: :no_answer}} =
             read(quest, "kael", "안녕", answers)
  end
end
