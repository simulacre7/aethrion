defmodule Aethrion.SimulatorTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Simulator, State}

  defp cast(name) do
    {:ok, state} = "priv/casts/#{name}.json" |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  test "a route script: daily lines, every Nth day, and one day" do
    assert [
             {:daily, "오늘은 같이 그림 그리자"},
             {{:every, 3}, "내일은 좀 쉬자"},
             {{:on, 10}, "너 주려고 물감 사 왔어"},
             {{:every, 2}, "great job"}
           ] =
             Simulator.parse("""
             오늘은 같이 그림 그리자
             # a comment
             3일마다: 내일은 좀 쉬자
             10일째: 너 주려고 물감 사 왔어
             every 2: great job
             """)
  end

  test "routes written as chat reach different endings, the same way every time" do
    routes = [
      %{
        name: "painter",
        to: "seoyun",
        days: 30,
        script: "오늘은 같이 그림 그리자\n4일마다: 내일은 좀 쉬자\n5일마다: 네 그림 진짜 멋지다"
      },
      %{name: "study", to: "seoyun", days: 30, script: "오늘은 공부하자"}
    ]

    [painter, study] = results = Simulator.run(cast("summer"), routes, locale: :ko)
    assert %{ending: %{id: "painter"}, problems: []} = painter
    assert %{ending: %{id: "burnout"}, day: day} = study
    assert day < 30
    assert [%{closeness: _} | _] = painter.closest
    assert Simulator.run(cast("summer"), routes, locale: :ko) == results
  end

  test "a fight plays a round a day, and bond stories show up" do
    [fight] =
      Simulator.run(cast("quest"), [%{name: "fight", to: "kael", days: 20, script: "늑대왕을 벤다"}])

    assert %{ending: %{id: _}} = fight

    [talk] =
      Simulator.run(cast("academy"), [%{name: "warm", to: "hana", days: 5, script: "하나야 오늘도 고마워"}])

    assert "hana-1" in talk.milestones
  end
end
