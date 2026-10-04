defmodule Aethrion.BridgeLedgerCellsTest do
  use ExUnit.Case, async: true

  alias Aethrion.Bridge.Ledger
  alias Aethrion.Bridge.Ledger.Cells

  @row "Rank 10 | P 0 (+0) | L 0 | C 0 | I 0 | B2 C동 숙소 | -"

  describe "read/1" do
    test "the labelled numbers of a row" do
      assert Enum.map(Cells.read(@row), &{&1.label, &1.number}) ==
               [{"Rank", 10}, {"P", 0}, {"L", 0}, {"C", 0}, {"I", 0}]

      # One label and a number is a sentence as often as a cell.
      assert Cells.read("62 | 의기양양 | 다들 날 보고 있어") == []
      assert Cells.read("Lv 5 | 초심자") == []
      assert Cells.read("협회 본부 로비") == []
    end
  end

  describe "change/2" do
    test "numbers named by their labels move; what names none of them is none" do
      assert Cells.change(@row, "L +1, C: +2 (조직의 따뜻함), Rank -3") ==
               {:ok, "Rank 7 | P 0 (+0) | L 1 | C 2 | I 0 | B2 C동 숙소 | -", nil}

      # What the rules say of the person is no cell of the row.
      assert Cells.change(@row, "+14 affinity, +2 trust / L: +1") ==
               {:ok, "Rank 10 | P 0 (+0) | L 1 | C 0 | I 0 | B2 C동 숙소 | -", nil}

      assert Cells.change(@row, "+14 affinity, +2 trust") == :none
      assert Cells.change(@row, "기분이 좋아 보인다") == :none
    end

    test "a number with no sign is left alone, unless it is the number as it stands" do
      assert Cells.change(@row, "L 5, C +1") ==
               {:ok, "Rank 10 | P 0 (+0) | L 0 | C 1 | I 0 | B2 C동 숙소 | -", :unsigned}

      assert Cells.change(@row, "L +2, I: 0") ==
               {:ok, "Rank 10 | P 0 (+0) | L 2 | C 0 | I 0 | B2 C동 숙소 | -", nil}
    end

    test "the row written anew" do
      assert Cells.change(@row, "Rank 9 | P 12 (+12) | L 8 | C 1 | I 0 | B2 대욕장 | 등 밀기") ==
               :rewrite
    end
  end

  test "moved/2 says which numbers moved" do
    assert Cells.moved(@row, "Rank 9 | P 12 (+12) | L 0 | C 1 | I 0 | B2 대욕장 | 등 밀기") ==
             ["Rank 10 → 9", "P 0 → 12", "C 0 → 1"]
  end

  describe "in the ledger" do
    @spec_ %{
      open: "[Day",
      close: "",
      rules: [
        "L = clamp(L, 0, 100)",
        "C = clamp(C, 0, 100)",
        "L = clamp(L, L.before - 3, L.before + 3)",
        "Rank = clamp(Rank, 1, 10)"
      ]
    }
    @window "[Day 1 · 밤 · 총수실]\nPresent: Hansol, Remi\nHansol | Rank 10 | P 0 (+0) | L 0 | C 0 | I 0 | B2 C동 숙소 | -\nRemi | Rank 10 | P 0 (+0) | L 0 | C 0 | I 0 | B2 A동 숙소 | -"

    defp turn(changes) do
      {kept, applied, refused} = Ledger.apply(@window, changes, @spec_)
      {settled, ruled} = Ledger.settle(kept, @spec_, @window)

      {settled |> String.split("\n") |> Enum.drop(2),
       Ledger.log(applied, refused, :ko) ++ Ledger.rule_log(ruled, :ko)}
    end

    test "a row's numbers are changed by label, with the row or in its line, and a rule for a label holds of every row" do
      assert turn([{"Hansol L", "+9"}, {"Remi", "C -4, Rank -3, P +5"}]) ==
               {[
                  "Hansol | Rank 10 | P 0 (+0) | L 3 | C 0 | I 0 | B2 C동 숙소 | -",
                  "Remi | Rank 7 | P 5 (+0) | L 0 | C 0 | I 0 | B2 A동 숙소 | -"
                ],
                [
                  "기록 · Hansol L 0 → 9 · Remi Rank 10 → 7, P 0 → 5, C 0 → -4",
                  "규칙 · Hansol L 9 → 3 · Remi C -4 → 0"
                ]}
    end

    test "a change written as the row is, with its bar" do
      assert {["Hansol | Rank 10 | P 0 (+0) | L 1 | C 2 | I 0 | B2 C동 숙소 | -", _remi],
              ["기록 · Hansol L 0 → 1, C 0 → 2"]} =
               turn([{"Hansol | L", "+1 / C: +2 (조직의 따뜻함 체감)"}])
    end

    test "a row written anew is taken, and its numbers held to the rules" do
      assert {["Hansol | Rank 9 | P 12 (+12) | L 3 | C 1 | I 0 | B2 대욕장 | 등 밀기", _remi], record} =
               turn([{"Hansol", "Rank 9 | P 12 (+12) | L 8 | C 1 | I 0 | B2 대욕장 | 등 밀기"}])

      assert record == [
               "기록 · Hansol Rank 10 → 9, P 0 → 12, L 0 → 8, C 0 → 1",
               "규칙 · Hansol L 8 → 3"
             ]
    end

    test "what is not about the row leaves it as it was" do
      assert {rows, ["기록 · Hansol: 기분이 좋아 보인다 (숫자가 아님)"]} = turn([{"Hansol", "기분이 좋아 보인다"}])
      assert rows == @window |> String.split("\n") |> Enum.drop(2)
    end

    test "the model is told how to write a row's numbers" do
      assert Ledger.instruction(@window, @spec_) =~
               "For a row of labelled numbers (Hansol, Remi), write the numbers that move by their labels, each with its sign, `Hansol: Rank +1`, or write the whole row anew."
    end
  end
end
