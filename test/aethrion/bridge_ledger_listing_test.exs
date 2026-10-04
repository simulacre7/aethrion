defmodule Aethrion.BridgeLedgerListingTest do
  use ExUnit.Case, async: true

  alias Aethrion.Bridge.Ledger.Listing

  @habits %{separator: " / ", empty: "None"}
  @items "타워 단말기 (보급형) / 회복의 물약 (노말) × 3 / 마정석 (최하급) × 1"

  defp change(was, value, habits \\ @habits), do: Listing.change(was, value, habits)

  describe "list?/1" do
    test "several things, or one that is counted" do
      assert Listing.list?(@items)
      assert Listing.list?("마정석 (최하급) × 3")
      assert Listing.list?("물병 x2 · 라이터 · 밧줄")
      assert Listing.list?(~s(["rusty sword", "bread x2"]))
      assert Listing.list?("0G, 0S, 0C")
      refute Listing.list?("낡은 검 (노말)")
      refute Listing.list?("None")
    end
  end

  describe "change/3" do
    test "something joins, counted in the way the list counts" do
      assert change(@items, "+마정석 (최하급) × 2") ==
               {"타워 단말기 (보급형) / 회복의 물약 (노말) × 3 / 마정석 (최하급) × 3", nil}

      assert change(@items, "+고블린의 귀") == {@items <> " / 고블린의 귀", nil}
      # Something held without a count, gained again.
      assert change(@items, "+타워 단말기 (보급형)") ==
               {"타워 단말기 (보급형) × 2 / 회복의 물약 (노말) × 3 / 마정석 (최하급) × 1", nil}

      assert change("물병 x2 · 라이터", "+코코넛 x3") == {"물병 x2 · 라이터 · 코코넛 x3", nil}
      assert change("빵 2개, 물", "+빵 1개") == {"빵 3개, 물", nil}
    end

    test "something leaves, wholly or by count" do
      assert change(@items, "-회복의 물약 (노말) × 1") ==
               {"타워 단말기 (보급형) / 회복의 물약 (노말) × 2 / 마정석 (최하급) × 1", nil}

      assert change(@items, "−마정석 (최하급)") == {"타워 단말기 (보급형) / 회복의 물약 (노말) × 3", nil}
      assert change(@items, "-회복의 물약 (노말) × 5") == {"타워 단말기 (보급형) / 마정석 (최하급) × 1", nil}
    end

    test "what the list does not have cannot leave it" do
      assert change(@items, "-엘릭서") == {@items, :missing}
    end

    test "several changes on one line, and a count written first" do
      assert change(@items, "+2 마정석 (최하급), -타워 단말기 (보급형)") ==
               {"회복의 물약 (노말) × 3 / 마정석 (최하급) × 3", nil}
    end

    test "an empty list is filled, and an emptied one says so in the window's word" do
      assert change("None", "+출혈") == {"출혈", nil}
      assert change("출혈", "-출혈") == {"None", nil}
      assert change("검사의 기초 (클래스)", "-검사의 기초 (클래스)", %{@habits | empty: "없음"}) == {"없음", nil}
      assert change("검사의 기초 (클래스)", "+강타 (액티브)") == {"검사의 기초 (클래스) / 강타 (액티브)", nil}
    end

    test "one counted thing where the whole list was asked for keeps the rest" do
      # What was gained, said with words for it; a new count for what is held.
      assert change(@items, "마정석 (최하급) × 2 추가 획득") ==
               {"타워 단말기 (보급형) / 회복의 물약 (노말) × 3 / 마정석 (최하급) × 3", nil}

      assert change(@items, "회복의 물약 (노말) × 2") ==
               {"타워 단말기 (보급형) / 회복의 물약 (노말) × 2 / 마정석 (최하급) × 1", nil}
    end

    test "a list said anew replaces it, and so does any other text" do
      assert change(@items, "타워 단말기 (보급형) / 회복의 물약 (노말) × 2") ==
               {"타워 단말기 (보급형) / 회복의 물약 (노말) × 2", nil}

      assert change("최승규 / 에르웬 / 김태민", "None") == {"None", nil}
      assert change("서울, 명월탑 1층", "명월탑 2층") == {"명월탑 2층", nil}
    end

    test "an amount is added to its kind, and does not go below nothing" do
      assert change("0G, 0S, 0C", "+5G") == {"5G, 0S, 0C", nil}
      assert change("5G, 12S, 0C", "-2S, +30C") == {"5G, 10S, 30C", nil}
      assert change("5G, 0S, 0C", "-3S") == {"5G, 0S, 0C", :clamped}
    end

    test "brackets and quotes are kept as the list writes them" do
      assert change(~s(["rusty sword", "bread x2"]), "+healing potion") ==
               {~s(["rusty sword", "bread x2", "healing potion"]), nil}

      assert change(~s(["rusty sword", "bread x2"]), "-bread x1") ==
               {~s(["rusty sword", "bread x1"]), nil}

      assert change(~s(["rusty sword"]), "-rusty sword") == {"[]", nil}
    end
  end

  describe "moved/2" do
    test "what joined and what left" do
      assert Listing.moved(@items, "타워 단말기 (보급형) / 회복의 물약 (노말) × 2 / 마정석 (최하급) × 3 / 귀") ==
               ["−회복의 물약 (노말)", "+마정석 (최하급) × 2", "+귀"]

      assert Listing.moved("0G, 0S, 0C", "5G, 0S, 0C") == ["+5G"]
      assert Listing.moved("None", "출혈") == ["+출혈"]
    end

    test "a value written anew is no list of changes" do
      assert Listing.moved("서 있음, 수련 중", "앉음, 운기조식") == []
    end
  end
end
