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

  describe "windows of other shapes" do
    test "a table's rows, lines led by a symbol, and a heading with something to say" do
      # The card closes its heading with "]": the window runs on to the end.
      spec = %{open: "[Day", close: "]"}

      reply =
        "서술.\n\n[Day 3/30 · 오후]\n📍 해변 캠프\n🎒 물병 x2 · 라이터 · 밧줄\nTyler | 62 | 의기양양 | 다들 날 봐: 당연하지\nChloe♥ | 35 | 목마름 | 저 사람 2번이나 날 도왔어"

      assert {"서술.\n\n", found, ""} = Ledger.window(reply, spec)

      assert Enum.map(Ledger.fields(found, spec), &{&1.name, &1.value}) == [
               {"Day", "3/30 · 오후"},
               {"📍", "해변 캠프"},
               {"🎒", "물병 x2 · 라이터 · 밧줄"},
               {"Tyler", "62 | 의기양양 | 다들 날 봐: 당연하지"},
               {"Chloe♥", "35 | 목마름 | 저 사람 2번이나 날 도왔어"}
             ]

      changes = [
        {"Day", "+1"},
        {"Tyler", "-4"},
        {"Chloe♥", "38 | 미소 | 고마워"},
        {"📍", "숲 입구"},
        {"🎒", "+코코넛 x3"}
      ]

      assert {kept, applied, []} = Ledger.apply(found, changes, spec)

      assert kept ==
               "[Day 4/30 · 오후]\n📍 숲 입구\n🎒 물병 x2 · 라이터 · 밧줄 · 코코넛 x3\nTyler | 58 | 의기양양 | 다들 날 봐: 당연하지\nChloe♥ | 38 | 미소 | 고마워"

      # The turn's record has the figures, not the rows' words.
      assert Ledger.log(applied, [], :ko) == [
               "기록 · Day 3/30 · 오후 → 4/30 · 오후 · Tyler 62 → 58 · Chloe♥ 35 → 38 · 🎒 +코코넛 × 3"
             ]
    end

    test "lines marked with a sign, their values holding a bar" do
      spec = %{open: "◈시간:", close: ""}

      reply =
        "서술.\n\n```\n◈시간: 봄|월요일|진시\n◈장소: 화산파 연무장\n◈무공: 120 | 이류\n◈평판: -5 | 비호감\n```"

      assert {_head, found, ""} = Ledger.window(reply, spec)

      assert {kept, _applied, []} =
               Ledger.apply(
                 found,
                 [{"무공", "+30"}, {"평판", "10 | 호감"}, {"시간", "봄|월요일|사시"}],
                 spec
               )

      assert kept == "◈시간: 봄|월요일|사시\n◈장소: 화산파 연무장\n◈무공: 150 | 이류\n◈평판: 10 | 호감\n```"
    end

    test "a closing text copied from the card's format with a blank in it" do
      spec = %{open: "[Date:", close: "|UserColor:(R,G,B)]"}
      reply = "서술.\n[Date:1900-03-02 (Thu)|Currencies:0G, 0S, 0C|UserColor:(0,0,0)]\n뒷말."

      assert {"서술.\n", found, "\n뒷말."} = Ledger.window(reply, spec)
      assert {kept, _applied, []} = Ledger.apply(found, [{"Currencies", "+5G"}], spec)
      assert kept == "[Date:1900-03-02 (Thu)|Currencies:5G, 0S, 0C|UserColor:(0,0,0)]"
      # A color is no number to keep within bounds.
      assert Ledger.settle(kept, spec) == {kept, []}
    end

    test "a sheet in a code block, its numbers among words" do
      spec = %{open: "```", close: "```"}

      reply =
        "You wake.\n<stats>\n```\nInventory: [\"rusty sword\", \"bread x2\"]\nGold: 120G\nEXP: (45/100 EXP to next level)\nReputation: 12 \"novice\"\n```\n</stats>"

      assert {_head, found, "\n</stats>"} = Ledger.window(reply, spec)

      changes = [
        {"Gold", "-20"},
        {"EXP", "+30"},
        {"Reputation", "15 \"known\""},
        {"Inventory", "+rope"}
      ]

      assert {kept, applied, []} = Ledger.apply(found, changes, spec)

      assert kept ==
               "```\nInventory: [\"rusty sword\", \"bread x2\", \"rope\"]\nGold: 100G\nEXP: (75/100 EXP to next level)\nReputation: 15 \"known\"\n```"

      assert Ledger.log(applied, [], :en) == [
               "Ledger · Gold 120G → 100G · EXP 45/100 → 75/100 · Reputation 12 \"novice\" → 15 \"known\" · Inventory +rope"
             ]
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
        {"Strength", "14"},
        {"Location", "명월탑 1층 외곽"},
        {"Stat Point", "+5"}
      ]

      {after_turn, _applied, []} = Ledger.apply(window(), changes, @lines)
      assert value(after_turn, @lines, "HP") == "140 / 140"
      assert value(after_turn, @lines, "Strength") == "14"
      assert value(after_turn, @lines, "Location") == "명월탑 1층 외곽"
      assert value(after_turn, @lines, "Stat Point") == "7"
    end

    test "a field the window does not have is refused, and the window stays whole" do
      {after_turn, [], refused} =
        Ledger.apply(window(), [{"Mana", "+3"}, {"Karma", "나쁨"}], @lines)

      assert after_turn == window()
      assert refused == [{"Mana", "+3", :unknown}, {"Karma", "나쁨", :unknown}]
    end

    test "a text told to move by a number is left alone; a text can be said anew" do
      {after_turn, applied, [{"Location", "+1", :unreadable}]} =
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

  describe "apply/3 with what a small model writes" do
    test "a figure stays a figure, whatever words come with the number" do
      changes = [
        {"Stat Point", "3 / 221"},
        {"HP", "-17 (현재 damage from previous encounters recovered to 104/130)"},
        {"Cash", "2095900 → 2100000"},
        {"EXP", "23 / 266 → 60 / 266 (거의 다 왔다)"},
        {"Strength", "아주 강함"}
      ]

      assert {kept, _applied, refused} = Ledger.apply(window(), changes, @lines)
      assert value(kept, @lines, "Stat Point") == "3"
      assert value(kept, @lines, "HP") == "104 / 130"
      assert value(kept, @lines, "Cash") == "2,100,000"
      assert value(kept, @lines, "EXP") == "60 / 266"
      assert value(kept, @lines, "Strength") == "12"
      assert refused == [{"Strength", "아주 강함", :unreadable}]
    end

    test "a clock moves by a length of time; a text that is no list takes no number" do
      changes = [{"Time", "+0:45"}, {"Time", "+30분"}, {"Location", "+3"}, {"Date", "+1"}]
      assert {kept, _applied, refused} = Ledger.apply(window(), changes, @lines)
      assert value(kept, @lines, "Time") == "18:02:09"
      assert value(kept, @lines, "Location") == "협회 본부 로비"
      assert refused == [{"Location", "+3", :unreadable}, {"Date", "+1", :unreadable}]

      # Around midnight, and without seconds.
      line = "[ Time: 23:40 | Mood: calm ]"

      assert {"[ Time: 01:40 | Mood: calm ]", _applied, []} =
               Ledger.apply(line, [{"Time", "+2 hours"}], %{open: "[", close: "]"})
    end

    test "a number alone for a pair is not taken: it says neither up nor down" do
      changes = [{"HP", "8"}, {"EXP", "15"}, {"HP", "now 100"}, {"Strength", "14"}]
      assert {kept, _applied, refused} = Ledger.apply(window(), changes, @lines)
      assert value(kept, @lines, "EXP") == "23 / 266"
      # Words that say it is the new value; and a number that stands alone is set.
      assert value(kept, @lines, "HP") == "100 / 130"
      assert value(kept, @lines, "Strength") == "14"
      assert refused == [{"HP", "8", :unsigned}, {"EXP", "15", :unsigned}]
      assert Ledger.log([], refused, :ko) == ["기록 · HP: 8 (+나 -가 없음)", "기록 · EXP: 15 (+나 -가 없음)"]
    end

    test "a list is changed a thing at a time" do
      changes = [{"Item", "+마정석 (최하급) × 2"}, {"Item", "-타워 단말기 (보급형)"}, {"Item", "-엘릭서"}]
      assert {kept, applied, refused} = Ledger.apply(window(), changes, @lines)
      assert value(kept, @lines, "Item") == "마정석 (최하급) × 7"
      assert refused == [{"Item", "-엘릭서", :missing}]

      assert Ledger.log(applied, refused, :ko) == [
               "기록 · Item −타워 단말기 (보급형), +마정석 (최하급) × 2",
               "기록 · Item: -엘릭서 (가지고 있지 않음)"
             ]
    end

    test "a number with words of its own takes the new words; a bare one stays bare" do
      window = "[ 호감도: 30 (경계) | 위치: 명월탑 1층 | 레벨: 3 ]"
      spec = %{open: "[", close: "]"}

      changes = [{"호감도", "45 (호기심)"}, {"위치", "서울 협회 본부"}, {"레벨", "4 (레벨 업!)"}]
      assert {kept, _applied, []} = Ledger.apply(window, changes, spec)
      assert kept == "[ 호감도: 45 (호기심) | 위치: 서울 협회 본부 | 레벨: 4 ]"
    end
  end

  describe "settle/3: the card's arithmetic" do
    @rules [
      "HP.max = Strength * 10",
      "EXP.max = floor(100 * 1.15 ^ (Level - 1))",
      "when EXP >= EXP.max: Level += 1; EXP -= EXP.max",
      "when Level rises: Stat Point += if(Level % 5 == 0, 15, 5)",
      "Mana.max = Strength * 3",
      "not a rule at all"
    ]

    test "a first window is put right by the rules the card states" do
      spec = Map.put(@lines, :rules, @rules)
      # Strength 12: a maximum of 120, and the hurt stay as hurt as they were.
      assert {settled, ruled} = Ledger.settle(window(), spec)
      assert value(settled, spec, "HP") == "120 / 120"
      assert ruled == [{"HP", "121 / 130", "120 / 120"}]
      assert Ledger.rule_log(ruled, :ko) == ["규칙 · HP 121 / 130 → 120 / 120"]
      assert Ledger.rule_log([], :ko) == []
    end

    test "what the model gains is carried over a level, and the level's gifts are the rules'" do
      spec = Map.put(@lines, :rules, @rules)
      {before, _ruled} = Ledger.settle(window(), spec)

      # The model writes the EXP and, as it would without rules, the rest too.
      changes = [{"EXP", "+300"}, {"Level", "+1"}, {"Stat Point", "+5"}, {"Stat Point", "-1"}]
      assert {kept, applied, refused} = Ledger.apply(before, changes, spec)
      assert refused == [{"Level", "+1", :ruled}, {"Stat Point", "+5", :ruled}]
      # Past its maximum for now: the rule takes it up.
      assert {"EXP", "23 / 266", "323 / 266"} in applied

      assert {settled, ruled} = Ledger.settle(kept, spec, before)
      assert value(settled, spec, "Level") == "9"
      assert value(settled, spec, "EXP") == "57 / 305"
      assert value(settled, spec, "Stat Point") == "6"

      assert Ledger.rule_log(ruled, :en) == [
               "Rules · Level 8 → 9 · EXP 323 / 266 → 57 / 305 · Stat Point 1 → 6"
             ]
    end

    test "experience that fills its bar is a level gained, though the card's rules say nothing of it" do
      # The card's reader found only the maximum's formula.
      spec = Map.put(@lines, :rules, ["EXP.max = floor(100 * 1.15 ^ (Level - 1))"])
      assert {kept, _applied, []} = Ledger.apply(window(), [{"EXP", "+250"}], spec)
      assert {settled, ruled} = Ledger.settle(kept, spec, window())
      assert value(settled, spec, "Level") == "9"
      assert value(settled, spec, "EXP") == "7 / 305"
      assert Ledger.rule_log(ruled, :ko) == ["규칙 · Level 8 → 9 · EXP 273 / 266 → 7 / 305"]

      assert Ledger.instruction(window(), spec) =~
               "only what leads to them: the maximum of EXP, Level ("

      # With no rules at all, the maximum stays the model's to set.
      assert {kept, _applied, []} = Ledger.apply(window(), [{"EXP", "+250"}], @lines)
      assert {settled, _ruled} = Ledger.settle(kept, @lines, window())
      assert value(settled, @lines, "EXP") == "7 / 266"

      # A window with no level beside it: a bar that is full is full.
      bar = "[ EXP: 90 / 100 | Mood: calm ]"

      assert {"[ EXP: 100 / 100 | Mood: calm ]", _applied, [{"EXP", "+30", :clamped}]} =
               Ledger.apply(bar, [{"EXP", "+30"}], %{open: "[", close: "]"})
    end

    test "without rules, a pair is still kept within its maximum" do
      assert {settled, [{"HP", "150 / 130", "130 / 130"}]} =
               Ledger.settle(String.replace(window(), "121 / 130", "150 / 130"), @lines)

      assert value(settled, @lines, "HP") == "130 / 130"
      assert Ledger.settle(window(), @lines) == {window(), []}
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

  test "instruction/2 names the window's fields, its lists, and the card's rules" do
    text = Ledger.instruction(window(), @lines)
    assert text =~ "(Date, Time, Location, Cash, Level, HP, EXP, Stat Point, Strength, Item)"
    assert text =~ "For a list (Item), write only what joins or leaves it"
    # A level beside an experience bar is the rules' on any card.
    assert text =~
             "only what leads to them: Level (when EXP >= EXP.max: Level += 1; EXP -= EXP.max)."

    refute Ledger.instruction("[ Trust: 3% | Anger: 5% ]", %{open: "[", close: "]"}) =~
             "The game's rules set these themselves"

    # What the ledger did last turn is said, so that it is not asked for again.
    last = [
      %{"role" => "user", "content" => "스탯을 올린다."},
      %{
        "role" => "assistant",
        "content" =>
          ~s(올렸다.\n\n<aethrion-status id="ab">\n<aethrion-turn title="이번 턴 판정">읽기 · 말\n기록 · Stat Point 5 → 0 · Strength 9 → 14\n기록 · Mana: +3 \(없는 칸\)\n규칙 · HP 90 / 90 → 140 / 140</aethrion-turn></aethrion-status>)
      },
      %{"role" => "user", "content" => "앞으로 간다."}
    ]

    assert Ledger.recorded(last) == [
             "기록 · Stat Point 5 → 0 · Strength 9 → 14",
             "규칙 · HP 90 / 90 → 140 / 140"
           ]

    assert Ledger.recorded([%{"role" => "assistant", "content" => "창이 없는 답"}]) == []

    assert Ledger.instruction(window(), @lines, Ledger.recorded(last)) =~
             "do not write them again (기록 · Stat Point 5 → 0 · Strength 9 → 14; 규칙 · HP 90 / 90 → 140 / 140)."

    ruled = Ledger.instruction(window(), Map.put(@lines, :rules, ["HP.max = Strength * 10"]))

    assert ruled =~
             "The game's rules set these themselves, so do not write them, only what leads to them: the maximum of HP, Level (HP.max = Strength * 10 | when EXP >= EXP.max: Level += 1; EXP -= EXP.max)."

    # Only what the rules that parse do set is named: a level-up is the
    # model's to write when the card's reader found no rule for it.
    levels =
      Ledger.instruction(
        window(),
        Map.put(@lines, :rules, [
          "when EXP >= EXP.max: Level += 1; EXP -= EXP.max",
          "when Level rises: Stat Point += 5",
          "HP = clamp(HP, 0, 999)",
          "Mana.max = 3"
        ])
      )

    assert levels =~ "only what leads to them: Level, Stat Point ("
  end
end
