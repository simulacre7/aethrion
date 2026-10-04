defmodule Aethrion.ExampleCardsTest do
  use ExUnit.Case, async: true

  alias Aethrion.Bridge.Ledger

  @spec_ %{
    open: "[상태창]",
    close: "[상태창]",
    # What a reader takes from the card's rules, in the card's own field names.
    rules: [
      "HP.max = 체력 * 10",
      "기력.max = 근력 * 6",
      "경험치.max = 레벨 * 100",
      "when 경험치 >= 경험치.max: 레벨 += 1; 경험치 -= 경험치.max",
      "when 레벨 rises: 스탯 포인트 += 3",
      "when 근력 rises: 스탯 포인트 -= 1",
      "when 체력 rises: 스탯 포인트 -= 1"
    ]
  }

  setup_all do
    card = "examples/cards/moonlit-tower.ko.json" |> File.read!() |> Jason.decode!()
    {_head, window, ""} = Ledger.window(card["data"]["first_mes"], @spec_)
    %{card: card, window: window}
  end

  test "the example card's first message has the window its description sets out", context do
    %{card: card, window: window} = context
    assert card["spec"] == "chara_card_v2"
    assert card["data"]["description"] =~ window

    assert Enum.map(Ledger.fields(window, @spec_), & &1.name) ==
             ~w(날짜 위치 레벨 HP 기력 경험치) ++ ["스탯 포인트", "근력", "체력", "골드", "소지품"]

    # Its own example agrees with every rule that always holds.
    for rule <- Enum.take(@spec_.rules, 3), do: assert(Ledger.agrees?(window, rule, @spec_), rule)
    assert Ledger.settle(window, @spec_) == {window, []}
  end

  test "a few turns of it, in Korean field names", %{window: window} do
    # A wolf bites, a wolf falls, a potion is drunk.
    changes = [
      {"HP", "-18"},
      {"경험치", "+120"},
      {"소지품", "-회복약 × 1"},
      {"소지품", "+늑대 가죽"},
      {"골드", "+7"}
    ]

    assert {kept, _applied, []} = Ledger.apply(window, changes, @spec_)
    assert {one, ruled} = Ledger.settle(kept, @spec_, window)

    assert Ledger.rule_log(ruled, :ko) == [
             "규칙 · 레벨 1 → 2 · 경험치 120 / 100 → 20 / 200 · 스탯 포인트 0 → 3"
           ]

    assert one =~ "- HP: 32 / 50\n"
    assert one =~ "- 소지품: 낡은 검 / 회복약 × 1 / 늑대 가죽\n"

    # The points are spent; what the model writes of the cost is the rules' to say.
    changes = [{"체력", "+2"}, {"근력", "+1"}, {"스탯 포인트", "-3"}]
    assert {kept, _applied, [{"스탯 포인트", "-3", :ruled}]} = Ledger.apply(one, changes, @spec_)
    assert {two, ruled} = Ledger.settle(kept, @spec_, one)

    assert Ledger.rule_log(ruled, :ko) == [
             "규칙 · HP 32 / 50 → 32 / 70 · 기력 30 / 30 → 36 / 36 · 스탯 포인트 3 → 0"
           ]

    assert two =~ "- 스탯 포인트: 0\n- 근력: 6\n- 체력: 7\n"
  end

  describe "the bookshop card, a window of one line" do
    @shop %{
      open: "[ 날짜:",
      close: "]",
      rules: [
        "친밀 = clamp(친밀, 0, 100)",
        "경계 = clamp(경계, 0, 100)",
        "친밀 = clamp(친밀, 친밀.before - 3, 친밀.before + 3)",
        "경계 = clamp(경계, 경계.before - 5, 경계.before + 5)"
      ]
    }

    setup do
      card = "examples/cards/rainy-bookshop.ko.json" |> File.read!() |> Jason.decode!()
      {_head, window, ""} = Ledger.window(card["data"]["first_mes"], @shop)
      %{card: card, window: window}
    end

    test "its first message has the window its description sets out", %{
      card: card,
      window: window
    } do
      assert card["spec"] == "chara_card_v2"
      assert card["data"]["description"] =~ window
      assert Enum.map(Ledger.fields(window, @shop), & &1.name) == ~w(날짜 시간 장소 친밀 경계 Note)
      assert Ledger.settle(window, @shop) == {window, []}
      assert Ledger.instruction(window, @shop) =~ "(날짜, 시간, 장소, 친밀, 경계, Note)"

      assert Ledger.instruction(window, @shop) =~
               "Note is the window's line of words that has no name (now `비 오는 날 손님이라니, 책이 젖지만 않으면 좋겠는데.`)"
    end

    test "a turn of it: a number moves only so far, the clock and the thought go on", %{
      window: window
    } do
      changes = [
        {"시간", "+40분"},
        {"장소", "서점 2층 다락"},
        {"친밀", "+8"},
        {"경계", "-3"},
        {"Note", "책을 저렇게 조심히 넘기는 사람은 오랜만이네: 차라도 한 잔 낼까."}
      ]

      assert {changed, _applied, []} = Ledger.apply(window, changes, @shop)
      assert {settled, ruled} = Ledger.settle(changed, @shop, window)

      assert settled ==
               "[ 날짜: 3월 2일 (월) | 시간: 15:40 | 장소: 서점 2층 다락 | 친밀: 13% | 경계: 37% | 책을 저렇게 조심히 넘기는 사람은 오랜만이네 — 차라도 한 잔 낼까. ]"

      assert Ledger.rule_log(ruled, :ko) == ["규칙 · 친밀 18% → 13%"]
    end
  end
end
