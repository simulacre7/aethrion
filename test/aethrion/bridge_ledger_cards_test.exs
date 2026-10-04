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

  test "a list that counts every thing counts a new one as well" do
    habits = %{separator: ", ", empty: "None"}

    assert Listing.change("라이터 × 1, 손수건 × 2", "+밧줄", habits) ==
             {"라이터 × 1, 손수건 × 2, 밧줄 × 1", nil}

    assert Listing.change("검술, 방어", "+도약", habits) == {"검술, 방어, 도약", nil}
    assert Listing.change("5G, 3S", "+보석", habits) == {"5G, 3S, 보석", nil}
  end
end
