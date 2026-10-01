defmodule Aethrion.ChatTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Chat, State}

  defp cast(path) do
    {:ok, state} = path |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  test "suggesting an activity spends the day on it; mentioning it is talk" do
    summer = cast("priv/casts/summer.json")
    read = &Chat.read(summer, "user", "seoyun", &1)

    assert {:activity, %{character: "seoyun", activity: "그림"}} = read.("오늘은 같이 그림 그리자")
    assert {:activity, %{activity: "휴식"}} = read.("내일은 좀 쉬자. 요즘 너무 무리했어")
    assert {:activity, %{activity: "산책"}} = read.("저녁에 산책 갈래?")
    assert {:activity, %{activity: "공부"}} = read.("오늘은 공부할까?")
    assert :talk = read.("네 그림 정말 좋다")
    assert :talk = read.("그림 그리는 거 힘들지?")

    assert [{:talk, "seoyun", "서윤아 잘 잤어?"}, {:activity, %{activity: "그림"}}] =
             Chat.read_all(summer, "user", "seoyun", "서윤아 잘 잤어? 오늘은 같이 그림 그리자")
  end

  test "handing something over is a gift, named by what it is" do
    summer = cast("priv/casts/summer.json")

    item = fn text ->
      with {:gift, gift} <- Chat.read(summer, "user", "seoyun", text), do: gift.item
    end

    assert item.("물감 새로 사 왔어") == "물감"
    assert item.("너 주려고 꽃 사 왔어") == "꽃"
    assert item.("이거 선물이야") == "선물"
    assert item.("I got you some tea") == "tea"
    assert item.("선물 고마워") == :talk
    assert item.("내가 도와줄게") == :talk
  end

  test "in a fight, moves are moves and talk is talk; after the ending, it is all talk" do
    quest = cast("priv/casts/quest.json")

    assert {:combat, %{type: :attack, to: "wolf"}} =
             Chat.read(quest, "user", "kael", "늑대왕의 목을 노려 벤다")

    assert :talk = Chat.read(quest, "user", "kael", "카엘, 고마워")

    {:ok, step} =
      Aethrion.Runtime.step(
        put_in(quest.stats["wolf"]["hp"], 1),
        Aethrion.Event.attack("user", "wolf")
      )

    assert :talk = Chat.read(step.state, "user", "kael", "늑대왕을 벤다")
  end
end
