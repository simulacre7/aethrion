defmodule Aethrion.BridgeLedgerCardsTest do
  @moduledoc "What sessions with real cards showed, in windows shaped like theirs."
  use ExUnit.Case, async: true

  alias Aethrion.Bridge.Ledger
  alias Aethrion.Bridge.Ledger.Listing

  describe "a change written as the window writes its fields" do
    test "NAME=value is the field and its value, said outright" do
      spec = %{open: "<status>", close: "</status>"}
      window = "<status>\n\nDATE=10월 14일 (월)\n\nTIME=09:30\n\nHP=20\n\n</status>"

      {"story", changes} =
        Ledger.take("story\n<aethrion-ledger>\nTIME=09:47\nHP=+5\n</aethrion-ledger>")

      assert changes == [{"TIME", "=09:47"}, {"HP", "+5"}]

      assert {now, [{"TIME", "09:30", "09:47"}, {"HP", "20", "25"}], []} =
               Ledger.apply(window, changes, spec)

      assert now =~ "TIME=09:47\n\nHP=25"

      # A sign of equality further on is the value's own.
      assert Ledger.take("<aethrion-ledger>\nNote: a = b\nMood: =calm\n</aethrion-ledger>") ==
               {"", [{"Note", "a = b"}, {"Mood", "=calm"}]}
    end

    test "several changes on one line, between bars" do
      assert Ledger.take("<aethrion-ledger>\nBELL: 4 | HEARD: +1\n</aethrion-ledger>") ==
               {"", [{"BELL", "4"}, {"HEARD", "+1"}]}

      # A row written anew is one change: its cells have no names.
      assert Ledger.take("<aethrion-ledger>\nTyler: 62 | calm | a thought\n</aethrion-ledger>") ==
               {"", [{"Tyler", "62 | calm | a thought"}]}
    end
  end

  describe "a heading" do
    test "leaves the rule drawn after it out of its value" do
      spec = %{open: "━━ RECORD No.", close: ""}
      window = "━━ RECORD No.1 ━━\nSUBJECT: 기환 │ PLACE: 심문실 │ BELL: 3\nHEARD: 0"

      assert %{name: "RECORD No", value: "1"} = hd(Ledger.fields(window, spec))

      assert {now, applied, []} = Ledger.apply(window, [{"RECORD No", "+1"}], spec)
      assert now =~ "━━ RECORD No.2 ━━\n"
      assert Ledger.log(applied, [], :en) == ["Ledger · RECORD No 1 → 2"]
    end

    test "of several parts keeps the parts a change leaves out" do
      spec = %{open: "[Day", close: ""}
      window = "[Day 1 · 밤 · 최심부 총수실]\nPresent: Hansol\nFocus: None"

      first = fn changes ->
        window |> Ledger.apply(changes, spec) |> elem(0) |> String.split("\n") |> hd()
      end

      assert first.([{"Day", "+1"}]) == "[Day 2 · 밤 · 최심부 총수실]"
      assert first.([{"Day", "2 · 오전"}]) == "[Day 2 · 오전 · 최심부 총수실]"
      assert first.([{"Day", "2 · 낮 · B6 훈련장"}]) == "[Day 2 · 낮 · B6 훈련장]"

      # A part said anew beside a number that stays shows no line of the number.
      {_window, applied, []} = Ledger.apply(window, [{"Day", "1 · 새벽"}], spec)
      assert Ledger.log(applied, [], :ko) == []

      # One word says nothing of which part it is.
      assert {^window, [], [{"Day", "오전", :unreadable}]} =
               Ledger.apply(window, [{"Day", "오전"}], spec)

      assert Ledger.instruction(window, spec) =~
               "Day is a heading of several parts (now `1 · 밤 · 최심부 총수실`)"
    end
  end

  describe "where and when" do
    @spec_ %{open: "[Time:", close: "]"}
    @window "[Time: Sun., 02:15, (Autumn) | Location: Mapo-gu alley, Seoul / Inside a van | Race: Civilian]"

    test "a place is said anew, not a list for places to pile up in" do
      place = fn value ->
        {window, _applied, refused} = Ledger.apply(@window, [{"Location", value}], @spec_)
        [_all, place] = Regex.run(~r/Location: (.*?) \|/, window)
        {place, refused}
      end

      assert place.("Bureau van interior") == {"Bureau van interior", []}
      assert place.("+Bureau van interior") == {"Bureau van interior", []}
      assert place.("Mapo-gu alley → Bureau HQ, Seoul") == {"Bureau HQ, Seoul", []}

      assert {"Mapo-gu alley, Seoul / Inside a van", [{"Location", _value, :unreadable}]} =
               place.("-Mapo-gu alley, Seoul")

      refute Ledger.instruction(@window, @spec_) =~ "For a list"
    end

    test "a clock among other words moves, or is said anew, in its place" do
      time = fn value ->
        {window, _applied, []} = Ledger.apply(@window, [{"Time", value}], @spec_)
        [_all, time] = Regex.run(~r/Time: (.*?) \|/, window)
        time
      end

      assert time.("+25") == "Sun., 02:40, (Autumn)"
      assert time.("+1 hour") == "Sun., 03:15, (Autumn)"
      assert time.("02:40") == "Sun., 02:40, (Autumn)"
      assert time.("Mon., 09:00, (Autumn)") == "Mon., 09:00, (Autumn)"
    end
  end

  test "what the rules say of a person, written under the person's name, is dropped without a line" do
    spec = %{open: "[Time:", close: "]"}
    window = "[Time: 02:15 | Location: an alley | Race: Civilian]"

    assert Ledger.apply(window, [{"한서율", "trust +6"}, {"유서아", "호감 +10"}], spec) ==
             {window, [], []}

    assert {^window, [], [{"Mana", "+1", :unknown}]} =
             Ledger.apply(window, [{"Mana", "+1"}], spec)
  end

  test "a change left to a rule that names what the rule gives is no refusal" do
    spec = %{
      open: "[상태창]",
      close: "[상태창]",
      rules: ["when 근력 rises: 스탯 포인트 -= 1", "when 체력 rises: 스탯 포인트 -= 1"]
    }

    window = "[상태창]\n- 스탯 포인트: 3\n- 근력: 5\n- 체력: 5\n[상태창]"

    settle = fn changes ->
      {kept, _applied, refused} = Ledger.apply(window, changes, spec)
      {kept, _ruled} = Ledger.settle(kept, spec, window)
      {kept, Ledger.unanswered(refused, window, kept, spec)}
    end

    paid = "[상태창]\n- 스탯 포인트: 0\n- 근력: 7\n- 체력: 6\n[상태창]"
    assert settle.([{"근력", "+2"}, {"체력", "+1"}, {"스탯 포인트", "=0"}]) == {paid, []}
    assert settle.([{"근력", "+2"}, {"체력", "+1"}, {"스탯 포인트", "-3"}]) == {paid, []}

    # Not what the rule gave: the line stays, with its reason.
    assert {^paid, [{"스탯 포인트", "-1", :ruled}]} =
             settle.([{"근력", "+2"}, {"체력", "+1"}, {"스탯 포인트", "-1"}])
  end

  test "things that join and leave a list with only a space between them" do
    habits = %{separator: " / ", empty: "없음"}
    was = "낡은 검 / 회복약 × 2 / 이끼 쥐 털뭉치 × 1 / 작은 이빨 × 1"

    assert Listing.change(was, "-회복약 × 1 -이끼 쥐 털뭉치 × 1 -작은 이빨 × 1", habits) ==
             {"낡은 검 / 회복약 × 1", nil}

    assert Listing.change(was, "+회복약 × 1 -이끼 쥐 털뭉치 × 1 -작은 이빨", habits) ==
             {"낡은 검 / 회복약 × 3", nil}

    # A sign before a number is the thing's own.
    assert Listing.change("낡은 검", "+강철 검 +1", habits) == {"낡은 검 / 강철 검 +1", nil}

    assert Listing.change(was, "-회복약 × 1; -이끼 쥐 털뭉치 × 1; -작은 이빨 × 1", habits) ==
             {"낡은 검 / 회복약 × 1", nil}
  end

  test "a thing of a list named as a field, and a sum written out" do
    spec = %{open: "[상태창]", close: "[상태창]"}
    window = "[상태창]\n- HP: 36 / 50\n- 골드: 42\n- 소지품: 낡은 검 / 회복약 × 2\n[상태창]"

    assert {now, _applied, []} =
             Ledger.apply(window, [{"회복약", "-1"}, {"골드", "42 + 8"}, {"HP", "36 + 14"}], spec)

    assert now == "[상태창]\n- HP: 50 / 50\n- 골드: 50\n- 소지품: 낡은 검 / 회복약 × 1\n[상태창]"

    # A move written before the maximum is a move, not a pair to set.
    hp = fn value ->
      {now, _applied, _refused} = Ledger.apply(window, [{"HP", value}], spec)
      now |> String.split("\n") |> Enum.at(1)
    end

    assert hp.("+10 / 50") == "- HP: 46 / 50"
    assert hp.("-5 / 50") == "- HP: 31 / 50"
    assert hp.("36 + 10 / 50") == "- HP: 46 / 50"
    assert hp.("+25 / 50") == "- HP: 50 / 50"
    assert hp.("40 / 50") == "- HP: 40 / 50"

    # A thing no list holds is no field, and a sum from another number is not this one's.
    assert {^window, [], [{"마나 물약", "-1", :unknown}, {"골드", "40 + 8", _reason}]} =
             Ledger.apply(window, [{"마나 물약", "-1"}, {"골드", "40 + 8"}], spec)
  end

  test "words written as a change from one to another come to the last" do
    spec = %{open: "[상태창]", close: "[상태창]"}
    window = "[상태창]\n- 날짜: 1일차 아침\n- 기분: 평온\n- HP: 36 / 50\n- 변화: 구리 → 은\n[상태창]"

    {now, _applied, []} =
      Ledger.apply(
        window,
        [
          {"날짜", "1일차 저녁 → 2일차 아침"},
          {"기분", "평온 -> 들뜸"},
          {"HP", "36 / 50 → 50 / 50"},
          {"변화", "은 → 금"}
        ],
        spec
      )

    assert now == "[상태창]\n- 날짜: 2일차 아침\n- 기분: 들뜸\n- HP: 50 / 50\n- 변화: 은 → 금\n[상태창]"
  end

  test "the forms a small model wrote over a night of sessions" do
    spec = %{open: "[Status]", close: "[Status]"}

    window =
      "[Status]\n- Time: 14:20:00\n- Location: 명월탑 6층\n- HP: 36 / 50\n- EXP: 90 / 201\n- 골드: 42\n" <>
        "- Strength: 19\n- Item: 특급 마정석 × 200 / 황금 천사 편 × 1 / 고블린 하이브 (괴물심장) × 5 / 최하급 마정석 × 2\n[Status]"

    for {name, value, expected} <- [
          # Several moves in one change come to their sum, or to the number said plainly.
          {"골드", "+7 -15 = 34", "34"},
          {"골드", "+5 -15", "32"},
          {"골드", "+8 - 15", "35"},
          {"골드", "-15 +9 = -6", "36"},
          {"골드", "+5 - 15 = +(-10)", "32"},
          {"골드", "+8 -15 = +45에서 35로", "35"},
          {"골드", "42 + 8", "50"},
          {"골드", "+8 (42 → 50)", "50"},
          {"골드", "42 → 50 (+8)", "50"},
          # One move with what it comes to.
          {"Strength", "+4 (19 → 23)", "23"},
          {"HP", "-8 → 28 / 50", "28 / 50"},
          {"HP", "36 - 8 = 28 / 50", "28 / 50"},
          {"HP", "36 / 50 → 61 / 50 → 50 / 50", "50 / 50"},
          {"HP", "-18 (피로 누적)", "18 / 50"},
          {"EXP", "+25 → 115/201", "115 / 201"},
          # Times and places.
          {"Time", "+20 minutes → 14:40:00", "14:40:00"},
          {"Time", "06:30:00 → 09:15:00", "09:15:00"},
          {"Time", "+0:03:30", "14:23:30"},
          {"Location", "명월탑 6층 → 명월탑 1층 → 협회 정산 센터", "협회 정산 센터"},
          # Lists.
          {"Item", "-특급 마정석 × 189, -황금 천사 편", "특급 마정석 × 11 / 고블린 하이브 (괴물심장) × 5 / 최하급 마정석 × 2"},
          {"Item", "-고블린 하이브 (괴물심장) × 5 처치, 최하급 마정석 × 5 획득",
           "특급 마정석 × 200 / 황금 천사 편 × 1 / 최하급 마정석 × 7"}
        ] do
      {now, _applied, refused} = Ledger.apply(window, [{name, value}], spec)
      got = Enum.find(Ledger.fields(now, spec), &(&1.name == name)).value
      assert {name, value, got, refused} == {name, value, expected, []}
    end

    # What says too much to be read is refused, and the field stays.
    assert {^window, [], [{"EXP", _value, :unreadable}]} =
             Ledger.apply(
               window,
               [
                 {"EXP",
                  "+150 (90 → 40/240); actually: 90 + 150 = 240, so 240 = 240 → Level 7, 0 + 40"}
               ],
               spec
             )
  end

  test "a list that counts every thing counts a new one as well" do
    habits = %{separator: ", ", empty: "None"}

    assert Listing.change("라이터 × 1, 손수건 × 2", "+밧줄", habits) ==
             {"라이터 × 1, 손수건 × 2, 밧줄 × 1", nil}

    assert Listing.change("검술, 방어", "+도약", habits) == {"검술, 방어, 도약", nil}
    assert Listing.change("5G, 3S", "+보석", habits) == {"5G, 3S, 보석", nil}
  end
end
