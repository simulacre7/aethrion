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

  test "whom the player was talking to comes back with a checkpoint, from the JSON kept" do
    read = Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache())
    checkpoints = Aethrion.Bridge.Store.cache(Aethrion.Bridge.Checkpoints)
    first = [%{"role" => "user", "content" => "도윤, 괜찮아?"}]
    {_all, chat} = Bridge.transcript(first)
    {_before, now, turn} = Bridge.replay(camp(), chat, read, to: "sera", checkpoints: checkpoints)
    _ = :sys.get_state(Aethrion.Bridge.Checkpoints)

    # The app trimmed the line away; the reply's checkpoint remains.
    reply = %{"role" => "assistant", "content" => "…\n\n" <> Bridge.status(now, turn, :ko)}
    {_all, chat} = Bridge.transcript([reply, %{"role" => "user", "content" => "고마워"}])

    {_before, _now, turn} =
      Bridge.replay(camp(), chat, read, to: "sera", checkpoints: checkpoints)

    assert to_of(turn) == ["doyun"]
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
    assert note =~ "도윤 sent word of it to 하린, who is still away"
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

  test "the note and status leave out the daily easing of tension, and stay short" do
    {:ok, crowd} =
      State.parse(%{
        "characters" => for(i <- 1..12, do: %{"id" => "c#{i}", "name" => "인물#{i}"}),
        "relationships" =>
          for(
            i <- 1..12,
            j <- 1..12,
            i != j,
            do: %{"from" => "c#{i}", "to" => "c#{j}", "tension" => 30}
          ),
        "story" => %{"turn_hours" => 24}
      })

    {before, now, turn} = play(crowd, ["인물1, 선물이야"], "c1")
    assert turn.between == []
    assert String.length(Bridge.note(before, now, turn, :ko)) < 3_000
    assert Bridge.status(now, turn, :ko) |> String.split("\n") |> length() <= 20
  end

  test "days passing in a turn hide nothing: what happened between characters is listed whole" do
    {_before, _now, turn} = play(camp(%{"turn_hours" => 72}), ["세라, 목걸이 사 왔어. 선물이야"])
    assert {"doyun", "sera", :tension, 8} in turn.between

    {:ok, crowd} =
      State.parse(%{
        "characters" => for(i <- 1..12, do: %{"id" => "c#{i}", "name" => "인물#{i}"}),
        "relationships" =>
          for(
            i <- 1..12,
            j <- 1..12,
            i != j,
            do: %{"from" => "c#{i}", "to" => "c#{j}", "tension" => 30}
          ),
        "story" => %{"turn_hours" => 24}
      })

    {_before, _now, turn} = play(crowd, ["인물1, 안녕", "인물1, 잘 지내?"], "c1")
    assert turn.between == []
  end

  test "lines in a row: who saw each, and who came back between them, in order" do
    state = %{camp() | stats: put_in(camp().stats, ["harin", "away"], 1)}

    {_all, chat} =
      Bridge.transcript([
        %{"role" => "user", "content" => "세라, 안녕"},
        %{"role" => "user", "content" => "세라, 목걸이 사 왔어. 선물이야"}
      ])

    read = Bridge.reader([interpreter: Aethrion.Interpreter.Rules], no_cache())
    {before, now, turn} = Bridge.replay(state, chat, read, to: "sera")
    note = Bridge.note(before, now, turn, :ko)

    # Harin missed the first line, came back, and saw the gift.
    refute note =~ "Seen by: 도윤, 하린.\n- Not there, and does not know: 하린."

    [first, back, second] =
      for text <- ["세라, 안녕", "하린 is back", "세라, 목걸이 사 왔어"],
          do: :binary.match(note, text) |> elem(0)

    assert first < back and back < second
    assert note =~ ~r/세라, 안녕[^\n]*Not there, and does not know: 하린/
    assert note =~ ~r/목걸이 사 왔어[^\n]*Seen by: 도윤, 하린/
  end

  test "without turn_hours, time stands still in a chat" do
    {_before, now, _turn} = play(camp(%{}), ["세라, 목걸이 사 왔어. 선물이야", "세라, 어때?"])
    assert now.clock == 0
    assert State.stat(now, "harin", "away") == 2
  end
end
