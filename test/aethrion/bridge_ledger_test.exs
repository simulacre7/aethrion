defmodule Aethrion.BridgeLedgerTest do
  use ExUnit.Case, async: true

  alias Aethrion.Bridge.Ledger

  @lines %{open: "[Status Window]", close: "[Status Window]"}
  @window """
  [Status Window]
  - Date: 2025-01-01 (수)
  - Time: 16:47:09
  - Location: 협회 본부 로비
  - Cash: 2,095,900
  - Level: 8
  - HP: 121 / 130
  - EXP: 23 / 266
  - Stat Point: 2
  - Strength: 12
  - Item: 타워 단말기 (보급형) / 마정석 (최하급) × 5
  [Status Window]
  """

  defp window, do: String.trim(@window)

  defp value(window, spec, name),
    do: Enum.find(Ledger.fields(window, spec), &(&1.name == name)).value

  describe "window/2" do
    test "finds the last window in a reply, between the card's markers" do
      reply = "그는 말했다. \"[Status Window]를 열어 봐.\"\n\n" <> window() <> "\n\n뒤에 붙은 말"

      assert {before, found, rest} = Ledger.window(reply, @lines)
      assert found == window()
      assert before =~ "열어 봐"
      assert rest == "\n\n뒤에 붙은 말"
    end

    test "a one-line window between brackets, with a line of thought at its end" do
      spec = %{open: "[", close: "]"}

      reply =
        "무명이 고개를 들었다. [쿵] 소리가 났다.\n\n[ Trust: 2% | Anger: 10% | Date: 1025/03/05 (일) | Location: 폐허가 된 마을 | 안 뺏어 간다니. 그런 말은 처음 들었다. ]"

      assert {_before, found, ""} = Ledger.window(reply, spec)

      assert Enum.map(Ledger.fields(found, spec), &{&1.name, &1.value}) == [
               {"Trust", "2%"},
               {"Anger", "10%"},
               {"Date", "1025/03/05 (일)"},
               {"Location", "폐허가 된 마을"},
               {"Note", "안 뺏어 간다니. 그런 말은 처음 들었다."}
             ]
    end

    test "an opening text that names the first field, and a window that ends with the reply" do
      spec = %{open: "[Date:", close: "]"}
      reply = "서술.\n[Date:1024-03-02|Time:09:10|Currencies:12 실버|UserColor:(120,80,200)]"
      assert {_before, found, ""} = Ledger.window(reply, spec)
      assert Enum.map(Ledger.fields(found, spec), & &1.name) == ~w(Date Time Currencies UserColor)
      assert value(found, spec, "UserColor") == "(120,80,200)"

      open_ended = %{open: "◈무공", close: ""}
      reply = "서술\n◈무공: 120 | 이류\n◈평판: -15\n◈소지금: 3냥 20문\n"
      assert {"서술\n", found, _rest} = Ledger.window(reply, open_ended)

      assert Enum.map(Ledger.fields(found, open_ended), &{&1.name, &1.value}) |> Enum.take(2) ==
               [{"무공", "120 | 이류"}, {"평판", "-15"}]
    end

    test "text between the markers that is no window is none" do
      assert Ledger.window("그는 [Status Window]라고 말했다. [Status Window]", @lines) == nil
      assert Ledger.window("창이 없는 답", @lines) == nil
      assert Ledger.window(window(), nil) == nil
    end

    test "current/2 is the window of the last reply that has one" do
      chat = [
        %{"role" => "assistant", "content" => "첫 답\n\n" <> window()},
        %{"role" => "user", "content" => "한 줄"},
        %{"role" => "assistant", "content" => "창이 없는 답"},
        %{"role" => "user", "content" => "[Status Window] 흉내 [Status Window]"}
      ]

      assert Ledger.current(chat, @lines) == window()
      assert Ledger.current(chat, nil) == nil
      assert Ledger.current([], @lines) == nil
    end
  end

  describe "take/1" do
    test "takes the ledger lines out of the reply" do
      reply =
        "서술 끝.\n\n<aethrion-ledger>\n- HP: -12\nEXP: +18\nLocation: 명월탑 1층\n잡담\n</aethrion-ledger>"

      assert Ledger.take(reply) ==
               {"서술 끝.", [{"HP", "-12"}, {"EXP", "+18"}, {"Location", "명월탑 1층"}]}
    end

    test "empty lines are no changes; no lines are nil; a cut-off tag still counts" do
      assert Ledger.take("끝.<aethrion-ledger></aethrion-ledger>") == {"끝.", []}
      assert Ledger.take("끝.") == {"끝.", nil}
      assert Ledger.take("끝.\n<aethrion-ledger>\nHP: -3") == {"끝.", [{"HP", "-3"}]}
    end
  end

  describe "apply/3" do
    test "moves numbers by what was said and leaves the rest as it was" do
      {after_turn, applied, refused} =
        Ledger.apply(window(), [{"HP", "-12"}, {"exp", "+18"}, {"Cash", "-37,000"}], @lines)

      assert refused == []
      assert value(after_turn, @lines, "HP") == "109 / 130"
      assert value(after_turn, @lines, "EXP") == "41 / 266"
      # Thousands separators stay as the card wrote them.
      assert value(after_turn, @lines, "Cash") == "2,058,900"
      assert value(after_turn, @lines, "Level") == "8"
      assert value(after_turn, @lines, "Item") == "타워 단말기 (보급형) / 마정석 (최하급) × 5"

      assert applied == [
               {"HP", "121 / 130", "109 / 130"},
               {"EXP", "23 / 266", "41 / 266"},
               {"Cash", "2,095,900", "2,058,900"}
             ]

      # Nothing else in the window moved: only those three lines differ.
      changed =
        Enum.zip(String.split(window(), "\n"), String.split(after_turn, "\n"))
        |> Enum.count(fn {was, now} -> was != now end)

      assert changed == 3
    end

    test "keeps a pair within its maximum and a percentage within 0 to 100" do
      {after_turn, _applied, refused} =
        Ledger.apply(window(), [{"HP", "+500"}, {"EXP", "-90"}], @lines)

      assert value(after_turn, @lines, "HP") == "130 / 130"
      assert value(after_turn, @lines, "EXP") == "0 / 266"
      assert [{"HP", "+500", :clamped}, {"EXP", "-90", :clamped}] = refused

      one_line = "[ Trust: 98% | Anger: 3% ]"
      spec = %{open: "[", close: "]"}

      {after_turn, _applied, _refused} =
        Ledger.apply(one_line, [{"Trust", "+5"}, {"Anger", "-10"}], spec)

      assert after_turn == "[ Trust: 100% | Anger: 0% ]"
    end

    test "sets a pair, a number, and a text" do
      changes = [
        {"HP", "140 / 140"},
        {"Level", "9"},
        {"Location", "명월탑 1층 외곽"},
        {"Stat Point", "+5"}
      ]

      {after_turn, _applied, []} = Ledger.apply(window(), changes, @lines)
      assert value(after_turn, @lines, "HP") == "140 / 140"
      assert value(after_turn, @lines, "Level") == "9"
      assert value(after_turn, @lines, "Location") == "명월탑 1층 외곽"
      assert value(after_turn, @lines, "Stat Point") == "7"
    end

    test "a field the window does not have is refused, and the window stays whole" do
      {after_turn, [], refused} =
        Ledger.apply(window(), [{"Mana", "+3"}, {"Karma", "나쁨"}], @lines)

      assert after_turn == window()
      assert refused == [{"Mana", "+3", :unknown}, {"Karma", "나쁨", :unknown}]
    end

    test "a number told to move by words is left alone; a text can be said anew" do
      {after_turn, applied, []} =
        Ledger.apply(window(), [{"Location", "+1"}, {"Time", "16:52:30"}], @lines)

      assert value(after_turn, @lines, "Location") == "협회 본부 로비"
      assert applied == [{"Time", "16:47:09", "16:52:30"}]
    end

    test "a field named twice: the later change works on the earlier one's result" do
      {after_turn, applied, []} = Ledger.apply(window(), [{"HP", "-20"}, {"HP", "+5"}], @lines)
      assert value(after_turn, @lines, "HP") == "106 / 130"
      assert applied == [{"HP", "121 / 130", "106 / 130"}]

      # Back where it started is no change.
      assert {same, [], []} = Ledger.apply(window(), [{"HP", "-5"}, {"HP", "+5"}], @lines)
      assert same == window()
    end

    test "a value cannot break the window's format" do
      {after_turn, _applied, []} =
        Ledger.apply("[ Trust: 2% | Place: 마을 ]", [{"Place", "성 | Trust: 99%\n]"}], %{
          open: "[",
          close: "]"
        })

      assert length(Ledger.fields(after_turn, %{open: "[", close: "]"})) == 2
      refute after_turn =~ "\n"
    end
  end

  describe "differences/3" do
    test "what a window the model printed anyway changed" do
      printed =
        window()
        |> String.replace("HP: 121 / 130", "HP: 100 / 130")
        |> String.replace("Location: 협회 본부 로비", "Location: 탑")

      assert Ledger.differences(window(), printed, @lines) == [
               {"Location", "탑"},
               {"HP", "100 / 130"}
             ]

      assert Ledger.differences(window(), window(), @lines) == []
    end
  end

  describe "log/3 and note/3" do
    test "says what moved, and what was refused" do
      applied = [{"HP", "121 / 130", "109 / 130"}, {"Location", "로비", "탑"}]
      refused = [{"Mana", "+3", :unknown}, {"EXP", "+900", :clamped}]

      assert Ledger.log(applied, refused, :ko) == [
               "기록 · HP 121 / 130 → 109 / 130",
               "기록 · Mana: +3 (없는 칸)",
               "기록 · EXP: +900 (한도에 맞춤)"
             ]

      assert ["Ledger · HP 121 / 130 → 109 / 130" | _] = Ledger.log(applied, refused, :en)
      assert Ledger.log([{"Location", "로비", "탑"}], [], :ko) == []
    end

    test "the lines join this turn's rulings, or open them" do
      with_turn =
        ~s(<aethrion-status id="ab">세라 · 호감 4\n<aethrion-turn title="이번 턴 판정">읽기 · 말</aethrion-turn></aethrion-status>)

      assert Ledger.note(with_turn, ["기록 · HP 1 → 2"], "이번 턴 판정") ==
               ~s(<aethrion-status id="ab">세라 · 호감 4\n<aethrion-turn title="이번 턴 판정">읽기 · 말\n기록 · HP 1 → 2</aethrion-turn></aethrion-status>)

      bare = ~s(<aethrion-status id="ab"></aethrion-status>)

      assert Ledger.note(bare, ["Ledger · <HP>"], "This turn") ==
               ~s(<aethrion-status id="ab">\n<aethrion-turn title="This turn">Ledger · &lt;HP&gt;</aethrion-turn></aethrion-status>)

      assert Ledger.note(bare, [], "This turn") == bare
    end
  end

  describe "filter/2" do
    defp streamed(pieces, open) do
      {on_delta, flush} = Ledger.filter(&send(self(), {:out, &1}), open)
      Enum.each(pieces, on_delta)
      flush.()

      Stream.repeatedly(fn ->
        receive do
          {:out, text} -> text
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> Enum.join()
    end

    defp pieces(text, size), do: for([piece] <- Regex.scan(~r/.{1,#{size}}/su, text), do: piece)

    test "holds back the model's lines for the rules, however the pieces fall" do
      text =
        "검이 스쳤다. <b>피</b>가 튄다.\n\n<aethrion-ledger>\nHP: -12\n</aethrion-ledger>\n<aethrion-scene>김태민</aethrion-scene>"

      for size <- [1, 4, 9, 400] do
        assert streamed(pieces(text, size), nil) == "검이 스쳤다. <b>피</b>가 튄다.\n\n"
      end
    end

    test "holds back a window the model prints after all, from its opening line" do
      text =
        "검이 스쳤다.\n\n[Status Window]\n- HP: 100 / 130\n[Status Window]\n<aethrion-ledger>HP: -12</aethrion-ledger>"

      for size <- [1, 5, 400] do
        assert streamed(pieces(text, size), "[Status Window]") == "검이 스쳤다.\n\n"
      end

      # The same words inside a line are the story's.
      inline = "그는 \"[Status Window]를 봐\"라고 했다.\n끝."
      assert streamed(pieces(inline, 3), "[Status Window]") == inline
    end

    test "a short opening text holds only a line that reads as a window" do
      text = "쿵.\n[DING!] 레벨이 올랐다.\n[ 하지만 ] 그는 웃었다.\n[ Trust: 2% | Anger: 10% | 처음 듣는 말이다. ]"

      for size <- [1, 6, 400] do
        assert streamed(pieces(text, size), "[") ==
                 "쿵.\n[DING!] 레벨이 올랐다.\n[ 하지만 ] 그는 웃었다.\n"
      end
    end

    test "what only looked like a beginning is passed on at the end" do
      assert streamed(["끝이다 <aethrion-led"], nil) == "끝이다 <aethrion-led"
      assert streamed(["끝.\n[Status"], "[Status Window]") == "끝.\n[Status"
    end
  end

  test "instruction/2 names the window's fields" do
    assert Ledger.instruction(window(), @lines) =~
             "(Date, Time, Location, Cash, Level, HP, EXP, Stat Point, Strength, Item)"
  end
end
