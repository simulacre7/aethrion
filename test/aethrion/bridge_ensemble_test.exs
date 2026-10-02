defmodule Aethrion.BridgeEnsembleTest do
  # A chat with several characters: who is spoken to, who sees it, who
  # hears of it later, and what the model is told about all of them.
  use ExUnit.Case, async: false

  alias Aethrion.{Bridge, State}
  alias Aethrion.Bridge.Store

  # Sera and Doyun at the camp; Harin away scouting for two hours.
  defp camp(story \\ %{"turn_hours" => 1}) do
    {:ok, state} =
      State.parse(%{
        "characters" => [
          %{"id" => "sera", "name" => "세라", "traits" => ["calm"]},
          %{"id" => "doyun", "name" => "도윤", "traits" => ["sensitive"]},
          %{"id" => "harin", "name" => "하린", "traits" => ["talkative"]}
        ],
        "relationships" => [
          %{"from" => "sera", "to" => "user", "affinity" => 30, "trust" => 30},
          %{"from" => "doyun", "to" => "user", "affinity" => 45, "trust" => 20},
          %{"from" => "harin", "to" => "user", "affinity" => 20, "trust" => 20},
          %{"from" => "doyun", "to" => "harin", "affinity" => 40, "trust" => 40},
          %{"from" => "harin", "to" => "doyun", "affinity" => 40, "trust" => 35},
          %{"from" => "sera", "to" => "doyun", "affinity" => 30, "trust" => 25},
          %{"from" => "doyun", "to" => "sera", "affinity" => 30, "trust" => 25}
        ],
        "stats" => %{"harin" => %{"away" => 2}},
        "story" => story
      })

    state
  end

  setup do
    start_supervised!({Store, name: Aethrion.Bridge.Checkpoints})
    :ok
  end

  defp no_cache, do: %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}

  defp play(state, lines, to \\ "sera") do
    messages =
      Enum.flat_map(lines, fn line ->
        [%{"role" => "user", "content" => line}, %{"role" => "assistant", "content" => "…"}]
      end)
      |> Enum.drop(-1)

    {_all, chat} = Bridge.transcript(messages)
    read = Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache())
    Bridge.replay(state, chat, read, to: to)
  end

  defp to_of(turn), do: Enum.map(turn.readings, & &1.event[:to])

  test "a line goes to whoever was called last, not only to the model's character" do
    {_before, _now, turn} = play(camp(), ["도윤, 괜찮아?", "고마워. 덕분에 살았어"])
    assert to_of(turn) == ["doyun"]

    # Calling someone else moves the talk on.
    {_before, _now, turn} = play(camp(), ["도윤, 괜찮아?", "세라, 너도 고마워"])
    assert to_of(turn) == ["sera"]

    # With no one called yet, the model's character.
    {_before, _now, turn} = play(camp(), ["다들 고마워"])
    assert to_of(turn) == ["sera"]
  end

  test "those present see what the player does; someone away does not" do
    {before, now, _turn} = play(camp(), ["세라, 목걸이 사 왔어. 선물이야"])

    assert State.character(now, "doyun").state.jealousy >
             State.character(before, "doyun").state.jealousy

    assert State.get_relationship(now, "doyun", "sera").tension > 0
    # Harin did not see it (word may reach her later).
    refute Enum.any?(now.memories, &(&1.character_id == "harin" and &1.kind == :observed))
  end

  test "the note tells the model who saw it, what changed between them, and who was away" do
    {before, now, turn} = play(camp(), ["세라, 목걸이 사 왔어. 선물이야"])
    note = Bridge.note(before, now, turn, :ko)

    assert note =~ "Seen by: 도윤"
    assert note =~ "도윤 toward 세라: tension +"
    assert note =~ "Not there, and does not know: 하린"
    assert note =~ ~r/도윤 feels: jealousy \+\d+/
    assert note =~ "도윤 told 하린"
  end

  test "the status window shows what changed between characters this turn" do
    {_before, now, turn} = play(camp(), ["세라, 목걸이 사 왔어. 선물이야"])
    status = Bridge.status(now, turn, :ko)
    assert status =~ "도윤 → 세라 · 긴장 +"
  end

  test "time passes each turn: word gets around, and someone away comes back" do
    lines = ["세라, 목걸이 사 왔어. 선물이야", "세라, 어때?"]
    {before, now, turn} = play(camp(), lines)

    assert State.stat(now, "harin", "away") == 0
    assert now.clock == 2
    assert Enum.any?(now.memories, &(&1.character_id == "harin" and &1.kind == :heard))

    note = Bridge.note(before, now, turn, :ko)
    assert note =~ "하린 is back"
  end

  test "without turn_hours, time stands still in a chat" do
    {_before, now, _turn} = play(camp(%{}), ["세라, 목걸이 사 왔어. 선물이야", "세라, 어때?"])
    assert now.clock == 0
    assert State.stat(now, "harin", "away") == 2
  end
end
