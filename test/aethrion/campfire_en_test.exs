defmodule Aethrion.CampfireEnTest do
  # The English campfire cast is the Korean one in English: the same
  # numbers, so the same play reaches the same state.
  use ExUnit.Case, async: true

  alias Aethrion.{Bridge, State}

  defp cast(file) do
    {:ok, state} = "priv/casts/#{file}" |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  test "has the Korean cast's numbers, in English" do
    ko = cast("campfire.json")
    en = cast("campfire_en.json")

    assert en.relationships == ko.relationships
    assert en.stats == ko.stats
    assert Map.keys(en.characters) == Map.keys(ko.characters)
    assert Enum.map(en.story.endings, & &1.id) == Enum.map(ko.story.endings, & &1.id)

    for {id, character} <- en.characters do
      refute character.name =~ ~r/\p{Hangul}/u, "#{id} has a Korean name"
      refute character.profile =~ ~r/\p{Hangul}/u, "#{id} has a Korean profile"
    end
  end

  test "a gift seen by Doyun plays out in English" do
    read =
      Bridge.reader(
        [interpreter: Aethrion.Interpreter.Rules],
        %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}
      )

    messages = [%{"role" => "user", "content" => "Sera, I got you a necklace. It's a gift"}]
    {_all, chat} = Bridge.transcript(messages)
    {before, now, turn} = Bridge.replay(cast("campfire_en.json"), chat, read, to: "sera")
    status = Bridge.status(now, turn, :en, before)

    assert status =~ ~r/Sera · affinity \d+ \(\+\d+\)/
    assert status =~ "Doyun → Sera · tension +"
  end

  test "a raising sim's status shows the day, the stats, and the feelings its endings watch" do
    {:ok, summer} = "priv/casts/summer.json" |> File.read!() |> Jason.decode!() |> State.parse()

    read =
      Bridge.reader(
        [interpreter: Aethrion.Interpreter.Rules],
        %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}
      )

    messages = [%{"role" => "user", "content" => "서윤아, 오늘은 같이 그림 그리자"}]
    {_all, chat} = Bridge.transcript(messages)
    {before, now, turn} = Bridge.replay(summer, chat, read, to: "seoyun")
    status = Bridge.status(now, turn, :ko, before)

    assert status =~ "1일째 / 30일"
    assert status =~ ~r/서윤 · 호감 \d+ · 신뢰 \d+ · 그림 실력 \d+ \(\+\d+\) · 성적 \d+ · 스트레스 \d+ \(\+\d+\)/
    # Taeo's numbers are not watched by the story: only the relationship shows.
    assert status =~ ~r/태오 · 호감 \d+ · 신뢰 \d+\n<aethrion-turn/
    assert status =~ "읽기 · 활동: 그림"
  end

  test "the status block ends with this turn's rulings: the reading, the witnesses, the dice" do
    read =
      Bridge.reader(
        [interpreter: Aethrion.Interpreter.Rules],
        %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}
      )

    campfire = cast("campfire.json")

    {status, _messages} =
      Enum.reduce(["세라, 목걸이 사 왔어. 선물이야", "고블린 척후를 벤다"], {nil, []}, fn line, {_s, msgs} ->
        msgs = msgs ++ [%{"role" => "user", "content" => line}]
        {_all, chat} = Bridge.transcript(msgs)
        {before, now, turn} = Bridge.replay(campfire, chat, read, to: "sera")
        status = Bridge.status(now, turn, :ko, before)
        {status, msgs ++ [%{"role" => "assistant", "content" => "…\n\n" <> status}]}
      end)

    assert [_, log] =
             Regex.run(~r/<aethrion-turn title="이번 턴 판정">([\s\S]*)<\/aethrion-turn>/u, status)

    assert log =~ "읽기 · 공격 → 고블린 척후"
    # Every attack shows its roll against the target's armor class.
    assert log =~ ~r/\[d20 [^\]]*vs AC \d+/

    {_all, chat} = Bridge.transcript([%{"role" => "user", "content" => "세라, 목걸이 사 왔어. 선물이야"}])
    {before, now, turn} = Bridge.replay(campfire, chat, read, to: "sera")
    gift = Bridge.status(now, turn, :ko, before)
    assert gift =~ "읽기 · 세라에게 선물: 목걸이"
    assert gift =~ "목격 · 도윤"
    assert gift =~ "모름 · 하린 (자리에 없음)"
  end

  test "the note tells the narrator what each character remembers about the player" do
    read =
      Bridge.reader(
        [interpreter: Aethrion.Interpreter.Rules],
        %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}
      )

    messages = [
      %{"role" => "user", "content" => "세라, 목걸이 사 왔어. 선물이야"},
      %{"role" => "assistant", "content" => "…"},
      %{"role" => "user", "content" => "세라, 오늘 밤은 조용하네"}
    ]

    {_all, chat} = Bridge.transcript(messages)
    {before, now, turn} = Bridge.replay(cast("campfire.json"), chat, read, to: "sera")
    note = Bridge.note(before, now, turn, :ko)

    # From the turn before: lived through, seen, and heard secondhand.
    assert note =~ ~r/세라 remembers: the player gave 세라 a 목걸이 \(experienced, \d+ hours ago\)/
    assert note =~ ~r/도윤 remembers: 도윤 saw the player give 세라 a 목걸이 \(observed/
    assert note =~ "(heard from 도윤"
  end
end
