defmodule Aethrion.BridgeLedgerReviewTest do
  @moduledoc "What a review of the ledger found, each kept from coming back."
  use ExUnit.Case, async: true

  alias Aethrion.Bridge.{Ledger, Reply, Scene}
  alias Aethrion.Bridge.Ledger.{Listing, Rules}

  @lines %{open: "[Status]", close: "[Status]"}

  test "two fields of one name are told apart, and neither takes the other's number" do
    spec = %{open: "[People]", close: "[People]"}

    window =
      "[People]\n이름: 아리아 | 호감도: 30 | 신뢰: 10\n이름: 벨라 | 호감도: 55 | 신뢰: 40\n[People]"

    assert Enum.map(Ledger.fields(window, spec), & &1.name) ==
             ["이름", "호감도", "신뢰", "이름 2", "호감도 2", "신뢰 2"]

    assert Ledger.settle(window, spec) == {window, []}
    assert {kept, _applied, []} = Ledger.apply(window, [{"호감도", "+5"}, {"호감도 2", "-5"}], spec)
    assert kept =~ "아리아 | 호감도: 35 | 신뢰: 10\n이름: 벨라 | 호감도: 50 | 신뢰: 40"

    # A pair and a plain number under one name: no crash, each its own.
    mixed = "[Status]\n- HP: 30 / 48\n- HP: 12\n[Status]"
    assert Ledger.settle(mixed, @lines) == {mixed, []}
    assert Ledger.instruction(mixed, @lines) =~ "(HP, HP 2)"
  end

  test "digits of other scripts are text, not numbers to compute with" do
    window = "[Status]\n- レベル: １２\n- HP: 30 / 48\n- 持ち物: ポーション×３\n[Status]"
    assert Ledger.settle(window, @lines) == {window, []}
    assert is_binary(Ledger.instruction(window, @lines))

    assert {kept, _applied, _refused} =
             Ledger.apply(window, [{"HP", "-５"}, {"レベル", "+1"}, {"持ち物", "-ポーション×１"}], @lines)

    assert kept =~ "- HP: 30 / 48\n"

    assert Listing.change("ポーション×３", "+ポーション×２", %{separator: ", ", empty: "なし"}) |> elem(0) =~
             "ポーション"

    assert Ledger.Cells.read("P １ | L ２") == []
  end

  test "a number too long to be a figure is text" do
    long = String.duplicate("9", 320)
    window = "[Status]\n- Serial: #{long}.5\n- HP: 30 / 48\n[Status]"
    assert Ledger.settle(window, @lines) == {window, []}
    assert {_kept, _applied, _refused} = Ledger.apply(window, [{"HP", "-#{long}.5"}], @lines)
  end

  test "a value cannot close the window it is written into" do
    spec = %{open: "[ Trust:", close: "]"}
    window = "[ Trust: 3% | Mood: calm | Anger: 5% ]"

    assert {kept, _applied, []} =
             Ledger.apply(window, [{"Mood", "calm [for now] but wary"}], spec)

    assert kept == "[ Trust: 3% | Mood: calm (for now) but wary | Anger: 5% ]"
    assert {"", ^kept, ""} = Ledger.window(kept, spec)

    assert {kept, _applied, []} =
             Ledger.apply(
               "[Status]\n- Mood: calm\n- HP: 3 / 4\n[Status]",
               [{"Mood", "a [Status] of grace"}],
               @lines
             )

    assert kept == "[Status]\n- Mood: a   of grace\n- HP: 3 / 4\n[Status]" or
             kept == "[Status]\n- Mood: a of grace\n- HP: 3 / 4\n[Status]"
  end

  test "a window with no closing text ends at a blank line: the story after it stays the story" do
    spec = %{open: "[Day", close: "]"}
    reply = "[Day 3/30 · noon]\nHP: 30 / 48\nGold: 12\n\nMira: Come with me.\nShe said: wait."
    assert {"", window, "\n\nMira: Come with me.\nShe said: wait."} = Ledger.window(reply, spec)
    assert Enum.map(Ledger.fields(window, spec), & &1.name) == ["Day", "HP", "Gold"]
  end

  test "several rules for one field's rise all fire, and arithmetic that overflows is none" do
    names = ["level", "stat point", "skill point", "gold", "hp"]

    parsed =
      for text <- [
            "when Level rises: Stat Point += 5",
            "when Level rises: Skill Point += 1",
            "HP.max = 10 ^ 308 * 10",
            "when Gold > 1: Gold = Gold * Gold * Gold * Gold * Gold * Gold * Gold * Gold"
          ] do
        {:ok, rule} = Rules.parse(text, names)
        rule
      end

    before = %{
      "level" => %{now: 1, max: nil},
      "stat point" => %{now: 0, max: nil},
      "skill point" => %{now: 0, max: nil},
      "gold" => %{now: 99_999_999_999, max: nil},
      "hp" => %{now: 5, max: 10}
    }

    assert %{"stat point" => %{now: 10}, "skill point" => %{now: 2}, "hp" => %{max: 10}} =
             Rules.run(put_in(before["level"].now, 3), parsed, before)
  end

  test "ledger lines in several blocks or another case are all taken out" do
    reply =
      "끝.\n<Aethrion-Ledger>HP: -3</Aethrion-Ledger>\n뒷말.\n<aethrion-ledger>\nGold: +2\n</aethrion-ledger>"

    assert Ledger.take(reply) == {"끝.\n\n뒷말.", [{"HP", "-3"}, {"Gold", "+2"}]}
    refute Ledger.cut_off?(reply)
    assert Ledger.cut_off?("끝.\n<aethrion-ledger>\nHP: -1")

    # And held back from a stream.
    {on_delta, flush} = Ledger.filter(&send(self(), {:out, &1}), nil)
    on_delta.("끝.\n<Aethrion-Ledger>HP: -3</Aethrion-Ledger>")
    flush.()
    assert_received {:out, "끝.\n"}
    refute_received {:out, _more}
  end

  test "a scene with a backslash in it is kept as it is" do
    status = ~s(<aethrion-status id="ab">x</aethrion-status>)

    marked =
      Scene.mark(status, [
        %{name: "Mira", profile: "path C:\\0 keeper"},
        %{name: "Tom", profile: ""}
      ])

    assert marked =~ ~s(scene="Mira|path C:\\0 keeper;Tom">)
    assert [%{name: "Mira"}, %{name: "Tom"}] = Scene.marked(marked)
  end

  test "a field under a mark is found by its name" do
    window = "[Status]\n- ❤️ 체력: 30 / 48\n- 📍: 숲\n[Status]"
    assert {kept, _applied, []} = Ledger.apply(window, [{"체력", "-12"}, {"📍", "마을"}], @lines)
    assert kept == "[Status]\n- ❤️ 체력: 18 / 48\n- 📍: 마을\n[Status]"
  end

  test "a fraction below nothing keeps its sign" do
    window = "[Status]\n- Drift: 0.3\n- HP: 3 / 4\n[Status]"
    assert {kept, _applied, []} = Ledger.apply(window, [{"Drift", "-0.5"}], @lines)
    assert kept =~ "- Drift: -0.2\n"
  end

  describe "what a reply comes to" do
    defp plan(overrides) do
      store = :ets.new(:review_store, [:public])

      Map.merge(
        %{
          ledger: "[Status]\n- Level: 5\n- HP: 30 / 48\n- Gold: 120G\n[Status]",
          spec: @lines,
          locale: :en,
          player: nil,
          line?: true,
          settled: nil,
          keep: &:ets.insert(store, {:kept, &1}),
          store: store
        },
        overrides
      )
    end

    defp kept(plan), do: plan.store |> :ets.lookup(:kept) |> Keyword.get(:kept)

    test "a window printed where changes were asked for gives its numbers outright" do
      plan = plan(%{})
      reply = "A hit.\n\n[Status]\n- Level: 7\n- HP: 20 / 48\n- Gold: 150G\n[Status]"
      assert {text, nil} = Reply.finish(reply, nil, plan)
      assert text == "A hit.\n\n[Status]\n- Level: 7\n- HP: 20 / 48\n- Gold: 150G\n[Status]"
      assert %{fields: [{"Level", "7"}, {"HP", "20 / 48"}, {"Gold", "150G"}]} = kept(plan)
    end

    test "what is settled is what was applied, not what was written; cut-off lines settle nothing" do
      plan = plan(%{})
      reply = "A hit.\n<aethrion-ledger>\nHP: 8\nMana: -3\nGold: +5\n</aethrion-ledger>"
      assert {text, nil} = Reply.finish(reply, nil, plan)
      assert text =~ "- HP: 30 / 48\n- Gold: 125G"
      assert %{fields: [{"Gold", "125G"}], lines: lines} = kept(plan)
      assert Enum.any?(lines, &(&1 =~ "HP: 8 (no + or -)"))

      # A reroll: the same window and record, whatever the model writes now.
      again = %{plan | settled: kept(plan)}
      assert Reply.instruction(again, []) =~ "is settled: Ledger · Gold 120G → 125G. Narrate"

      assert {text, status} =
               Reply.finish(
                 "Another telling.\n<aethrion-ledger>HP: -40</aethrion-ledger>",
                 ~s(<aethrion-status id="ab"></aethrion-status>),
                 again
               )

      assert text =~ "Another telling.\n\n[Status]\n- Level: 5\n- HP: 30 / 48\n- Gold: 125G"
      assert status =~ "Ledger · Gold 120G → 125G"

      cut = plan(%{})
      assert {_text, nil} = Reply.finish("A hit.\n<aethrion-ledger>\nHP: -1", nil, cut)
      assert kept(cut) == nil
    end

    test "a reply continued prints no window and changes none" do
      plan = plan(%{line?: false})
      assert Reply.instruction(plan, []) =~ "do not print it again"

      reply =
        "…and the door gave way.\n\n[Status]\n- Level: 5\n- HP: 1 / 30\n- Gold: 999G\n[Status]\n<aethrion-ledger>HP: -29</aethrion-ledger>"

      assert Reply.finish(reply, nil, plan) == {"…and the door gave way.", nil}
      assert kept(plan) == nil
    end

    test "what was streamed and is not how the reply begins is followed by the window all the same" do
      finished = "A hit.\n\n[Status]\n- Level: 5\n- HP: 25 / 48\n- Gold: 120G\n[Status]"
      # Streamed as it should be: the rest follows.
      assert Reply.unsent(finished, "A hit.\n\n") ==
               "[Status]\n- Level: 5\n- HP: 25 / 48\n- Gold: 120G\n[Status]"

      # A window the model printed slipped out: the ledger's comes after it.
      slipped = "A hit.\n\n**[Status]**\n- HP: 30 / 48\n**[Status]**"

      assert Reply.unsent(finished, slipped) ==
               "\n\n[Status]\n- Level: 5\n- HP: 25 / 48\n- Gold: 120G\n[Status]"
    end
  end

  describe "a second review" do
    test "names that are looked up as one are told apart, whatever marks or numbers they carry" do
      for window <- [
            "[Status]\n- ❤️ HP: 30 / 48\n- HP: 12\n[Status]",
            "[Status]\n- HP: 30 / 48\n- HP: 20 / 40\n- HP 2: 7\n[Status]",
            "[Status]\n- 🔴 Affection: 30 / 100\n- 🔵 Affection: 12 / 100\n- Stat Point: 1\n- Stat  Point: 2\n[Status]"
          ] do
        names = Enum.map(Ledger.fields(window, @lines), &Ledger.Fields.key(&1.name))
        assert names == Enum.uniq(names)
        assert Ledger.settle(window, @lines) == {window, []}
        assert is_binary(Ledger.instruction(window, @lines))
      end
    end

    test "the stream filter finds a window after a line break or blanks, and a tag in any case" do
      streamed = fn pieces, open ->
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

      assert streamed.(
               ["You strike.", "\n[Status]\n- HP: 22 / 30\n[Status]\n\nThe goblin falls."],
               "[Status]"
             ) ==
               "You strike.\n"

      assert streamed.([" ", "[Status]\n- HP: 22 / 30\n[Status]\nA story."], "[Status]") == " "

      assert streamed.(["The end.\n<Aeth", "rion-Ledger>\nHP: -3\n</Aethrion-Ledger>"], nil) ==
               "The end.\n"
    end

    test "what slipped out is followed by the story that was held, and the window" do
      finished = "You strike.\n\nThe goblin falls.\n\n[Status]\n- HP: 22 / 30\n[Status]"
      gone = "You strike.\n[Status]\n- HP: 30 / 30\n"

      assert Reply.unsent(finished, gone) ==
               "\n\nThe goblin falls.\n\n[Status]\n- HP: 22 / 30\n[Status]"
    end

    test "a printed window's numbers are taken as they stand, signs and all" do
      window = "[Status]\n- Karma: -5\n- Temp: -3°C\n- Debt: -200G\n- Bag: rope\n[Status]"
      printed = "[Status]\n- Karma: -7\n- Temp: -1°C\n- Debt: -150G\n- Bag: -\n[Status]"
      plan = %{ledger: window, spec: @lines, locale: :en, player: nil, line?: true}
      assert {text, nil} = Reply.finish("Night falls.\n\n" <> printed, nil, plan)
      assert text == "Night falls.\n\n" <> printed

      assert {kept, _applied, []} =
               Ledger.apply(window, [{"Karma", "=-7"}, {"Debt", "-5 (def=3)"}], @lines)

      assert kept =~ "- Karma: -7\n"
      assert kept =~ "- Debt: -205G\n"
    end

    test "an open-ended window goes on over its own blank lines, and stops before the story" do
      marked = %{open: "◈Time", close: ""}
      window = "◈Time: 05:00\n◈HP: 30 / 48\n\n◈Inventory: potion × 2\n◈Gold: 12"
      assert {"Dawn.\n\n", ^window, ""} = Ledger.window("Dawn.\n\n" <> window, marked)

      headed = %{open: "[Day", close: "]"}
      reply = "[Day 3/30 · noon]\n\nHP: 30 / 48\nGold: 12\n\nMira: Come with me.\nShe said: wait."

      assert {"", found, "\n\nMira: Come with me.\nShe said: wait."} =
               Ledger.window(reply, headed)

      assert Enum.map(Ledger.fields(found, headed), & &1.name) == ["Day", "HP", "Gold"]

      # Line breaks sent as CR LF.
      chat = [
        %{
          "role" => "assistant",
          "content" => "[Day 3/30 · noon]\r\nHP: 30 / 48\r\nGold: 12\r\n\r\nMira: Come."
        }
      ]

      assert Ledger.current(chat, headed) == "[Day 3/30 · noon]\nHP: 30 / 48\nGold: 12"
    end

    test "a reroll is told the words that changed too" do
      text =
        Ledger.settled_instruction(["Ledger · HP 30 / 30 → 25 / 30"], [
          {"HP", "25 / 30"},
          {"Location", "the docks"},
          {"Mood", "wary"}
        ])

      assert text =~
               "is settled: Ledger · HP 30 / 30 → 25 / 30; Location: the docks; Mood: wary. Narrate"

      assert Ledger.settled_instruction([], []) =~ "nothing in it changes this turn"
    end

    test "a name that only holds the letters of a date word is a number like any other" do
      window =
        "[Status]\n- Intimidate: 12\n- Candidates: 3 / 5\n- Updates: 4\n- 일자리: 3\n- Date: 12/5\n- 오늘: 5/31 (토)\n- Today: 1/31 (Fri)\n[Status]"

      changes = [
        {"Intimidate", "+1"},
        {"Candidates", "+1"},
        {"Updates", "+1"},
        {"일자리", "+1"},
        {"오늘", "6/1 (일)"},
        {"Today", "2/1 (Sat)"}
      ]

      assert {kept, _applied, []} = Ledger.apply(window, changes, @lines)

      assert kept ==
               "[Status]\n- Intimidate: 13\n- Candidates: 4 / 5\n- Updates: 5\n- 일자리: 4\n- Date: 12/5\n- 오늘: 6/1 (일)\n- Today: 2/1 (Sat)\n[Status]"

      assert Ledger.settle(kept, @lines, window) == {kept, []}
    end

    test "a row's change names its numbers a part at a time, and prose names none" do
      row = "Rank 10 | P 0 | L 0"
      assert Ledger.Cells.change(row, "L +1 | P +2") == {:ok, "Rank 10 | P 2 | L 1", nil}
      assert Ledger.Cells.change(row, "L 0 → 1, P: 5 -> 6") == {:ok, "Rank 10 | P 6 | L 1", nil}
      assert Ledger.Cells.change(row, "Rank 3 guards arrived") == :none
      assert Ledger.Cells.change(row, "moved to L 2 wing") == :none
    end

    test "ledger tags that are not closed, or closed wrongly, take no story with them" do
      assert Ledger.take(
               "A hit.\n<aethrion-ledger>\nHP: -5\n\nThe goblin staggers back: bleeding, it runs."
             ) ==
               {"A hit.\n\nThe goblin staggers back: bleeding, it runs.", [{"HP", "-5"}]}

      assert Ledger.take("A hit.\n<aethrion-ledger/>\nThe goblin runs.") ==
               {"A hit.\nThe goblin runs.", []}

      assert Ledger.take("A hit.\n<aethrion-ledger\nHP: -5\n</aethrion-ledger>") ==
               {"A hit.", [{"HP", "-5"}]}

      # A line too long to be a change is none, and costs no time.
      long = "HP: x" <> String.duplicate(" ", 60_000) <> "y"

      {time, {_text, []}} =
        :timer.tc(fn -> Ledger.take("<aethrion-ledger>\n" <> long <> "\n</aethrion-ledger>") end)

      assert time < 2_500_000
    end

    test "a sign before a digit of another script is no thing to add to a list" do
      window = "[Status]\n- レベル: １２\n- Time: 05:00\n- Gold: 3\n[Status]"

      assert {^window, [], refused} =
               Ledger.apply(window, [{"レベル", "+１"}, {"Time", "+３０분"}], @lines)

      assert length(refused) == 2
    end

    test "an amount is spent by a number" do
      habits = %{separator: ", ", empty: "None"}
      assert Listing.change("5G, 3S, 0C", "-G", habits) == {"5G, 3S, 0C", :missing}
      assert Listing.change("5G, 3S, 0C", "-2G", habits) == {"3G, 3S, 0C", nil}
    end
  end

  describe "a third review" do
    test "a story of short paragraphs is not read through for a window with no closing text" do
      story = "Her HP was low.\n\n" <> String.duplicate("a\n\n", 3_000)
      chat = [%{"role" => "assistant", "content" => story}]

      {time, nil} = :timer.tc(fn -> Ledger.current(chat, %{open: "HP", close: ""}) end)
      assert time < 5_000_000

      long =
        "She [quietly] nodded.\n\n" <>
          String.duplicate(
            "She looked at him for a long moment and said nothing at all.\n\n",
            400
          )

      {time, nil} = :timer.tc(fn -> Ledger.window(long, %{open: "[", close: "]"}) end)
      assert time < 5_000_000
    end

    test "the window is the card's, not a later place where its opening text stands" do
      current = fn content, spec ->
        Ledger.current([%{"role" => "assistant", "content" => content}], spec)
      end

      # A window with no closing text begins a line.
      assert current.(
               "Story.\n\nHP: 30/48\nMP: 10/10\nEnemy HP: 12/20\nPet HP: 5/5",
               %{open: "HP:", close: ""}
             ) == "HP: 30/48\nMP: 10/10\nEnemy HP: 12/20\nPet HP: 5/5"

      # The card's own closing text is tried at every opening before none is.
      assert current.(
               "[ Trust: 3% | Anger: 5% | hm, who is this ]\n\n[Later]\nMina: hello.\nJisoo: hi.",
               %{open: "[", close: "]"}
             ) == "[ Trust: 3% | Anger: 5% | hm, who is this ]"

      assert current.(
               "[Day 3 · noon]\nLocation: the keep\nItems: sword [rare]\nHP: 3/5\nMP: 1/2",
               %{open: "[", close: "]"}
             ) == "[Day 3 · noon]\nLocation: the keep\nItems: sword [rare]\nHP: 3/5\nMP: 1/2"

      # An opening text that is only a mark leads the first line, which is a field.
      assert Enum.map(
               Ledger.fields("📍 the beach\n❤️ 30\n⭐ 3", %{open: "📍", close: ""}),
               &{&1.name, &1.value}
             ) == [{"📍", "the beach"}, {"❤️", "30"}, {"⭐", "3"}]
    end

    test "an edit that would lose a field, or make another, is refused" do
      row = "Trust: 3% | Mood: calm | Place: inn"
      assert {^row, [], [{"Mood", "|", :unreadable}]} = Ledger.apply(row, [{"Mood", "|"}])

      lines = "HP: 3/5\nMood: calm"

      assert {^lines, [], [{"Mood", _value, :unreadable}]} =
               Ledger.apply(lines, [{"Mood", "new text:"}])

      # A place written with a colon, after a mark, would read as a field of
      # another name: it is written with a dash.
      marks = "📍 the beach\n❤️ 30\n💬 I wonder who this is"

      assert {"📍 Seoul — Gangnam station\n❤️ 31\n💬 He said — run, at 14:30", _applied, []} =
               Ledger.apply(marks, [
                 {"📍", "Seoul: Gangnam station"},
                 {"❤️", "+1"},
                 {"💬", "He said: run, at 14:30"}
               ])

      # A note in a line of its own, too short to be read back as one, is refused;
      # between bars it is a note whatever its length.
      lines = "[Status]\nHP: 3/5\nMP: 1/2\nShe wonders who this could be.\n[Status]"

      assert {^lines, [], [{"Note", "Hm.", :unsound}]} =
               Ledger.apply(lines, [{"Note", "Hm."}], %{open: "[Status]", close: "[Status]"})

      spec = %{open: "[ Trust:", close: "]"}
      note = "[ Trust: 3% | Anger: 5% | I wonder who this person is ]"

      assert {"[ Trust: 3% | Anger: 5% | Who is he? ]", _applied, []} =
               Ledger.apply(note, [{"Note", "Who is he?"}], spec)

      assert Ledger.log([], [{"Note", "Hm.", :unsound}], :en) ==
               ["Ledger · Note: Hm. (would change the window's fields)"]
    end

    test "names that only sound like a date or a place" do
      assert {"Today's Earnings: 150G\nHP: 10/20", _applied, []} =
               Ledger.apply("Today's Earnings: 120G\nHP: 10/20", [{"Today's Earnings", "+30"}])

      assert {"Date Count: 4\nHP: 10/20", _applied, []} =
               Ledger.apply("Date Count: 3\nHP: 10/20", [{"Date Count", "+1"}])

      assert {"Characters in Scene: Mina, Jisoo, Hana\nHP: 10/20", _applied, []} =
               Ledger.apply("Characters in Scene: Mina, Jisoo\nHP: 10/20", [
                 {"Characters in Scene", "+Hana"}
               ])

      assert {"Storage Area: rope × 1, torch × 2, potion × 1\nHP: 10/20", _applied, []} =
               Ledger.apply("Storage Area: rope × 1, torch × 2\nHP: 10/20", [
                 {"Storage Area", "+potion"}
               ])
    end

    test "arrows in words are a change only from what the words were" do
      value = fn window, name, change ->
        {now, _applied, refused} = Ledger.apply(window, [{name, change}])
        {Enum.find(Ledger.fields(now), &(&1.name == name)).value, refused}
      end

      assert value.("Quest: find the key\nHP: 3/5", "Quest", "go north -> open the gate") ==
               {"go north -> open the gate", []}

      assert value.("Mood: calm\nHP: 3/5", "Mood", "calm → tense") == {"tense", []}
      assert value.("Location: the alley\nHP: 10/20", "Location", "the van →") == {"the van", []}
      assert value.("HP: 30/48\nMP: 3/5", "HP", "-12 (club -> ribs)") == {"18/48", []}
    end

    test "a heading written with its own name or brackets, and a grade with a dash" do
      spec = %{open: "[Day", close: ""}
      window = "[Day 1 · night · the keep]\nHP: 3/5\nMP: 1/2"

      head = fn change ->
        window |> Ledger.apply([{"Day", change}], spec) |> elem(0) |> String.split("\n") |> hd()
      end

      assert head.("Day 2 · morning · the keep") == "[Day 2 · morning · the keep]"
      assert head.("[Day 2 · morning · the yard]") == "[Day 2 · morning · the yard]"

      assert {"[Rank A]\nHP: 3/5\nMP: 1/2", _applied, []} =
               Ledger.apply("[Rank B-]\nHP: 3/5\nMP: 1/2", [{"Rank", "A"}], %{
                 open: "[Rank",
                 close: ""
               })
    end

    test "numbers below nothing, with units, and the word for an empty list" do
      assert {"Karma: -3 / 100\nHP: 3/5", _applied, []} =
               Ledger.apply("Karma: -5 / 100\nHP: 3/5", [{"Karma", "+2"}])

      assert {"Weight: 15 kg / 80 kg\nHP: 3/5", _applied, []} =
               Ledger.apply("Weight: 12 kg / 80 kg\nHP: 3/5", [{"Weight", "+3"}])

      # Two amounts of different kinds are no pair.
      assert {"Coins: 5G / 3S / 2C\nHP: 3/5", _applied, []} =
               Ledger.apply("Coins: 5G / 3S\nHP: 3/5", [{"Coins", "+2C"}])

      assert {"Target: ???\nInventory: None\nHP: 10/20", _applied, []} =
               Ledger.apply("Target: ???\nInventory: rope × 1\nHP: 10/20", [
                 {"Inventory", "-rope"}
               ])
    end

    test "ledger tags: bold marks, tags that close themselves, tags cut off" do
      assert Ledger.take(
               "ok\n<aethrion-ledger>\n- **Location:** the east gate\n</aethrion-ledger>"
             ) ==
               {"ok", [{"Location", "the east gate"}]}

      refute Ledger.cut_off?("x\n<aethrion-ledger/>")
      refute Ledger.cut_off?("x\n<aethrion-ledger>\nHP: -1\n</aethrion-ledger >")
      assert Ledger.cut_off?("x\n<aethrion-ledger>\nHP: -1")

      assert Ledger.take("Story.\n<aethrion-ledger>\nHP: -12\n</aethrion-ledger") ==
               {"Story.", [{"HP", "-12"}]}

      assert Ledger.take("She nods <aethrion-ledge") == {"She nods", nil}

      assert Ledger.take("Story.\n<aethrion-ledger>\nHP: -12\n</ledger>\nMore story.") ==
               {"Story.\n\nMore story.", [{"HP", "-12"}]}
    end

    test "the name as the window writes it, and the rules' own under a person's name" do
      window = "❤️ HP: 1/2\nHP: 3/4\n💙 HP: 9/9"

      assert {"❤️ HP: 1/2\nHP: 3/4\n💙 HP: 8/9", _applied, []} =
               Ledger.apply(window, [{"💙 HP", "-1"}])

      assert {"❤️ HP: 0/2\nHP: 3/4\n💙 HP: 9/9", _applied, []} =
               Ledger.apply(window, [{"❤️ HP", "-1"}])

      assert {"❤️ HP: 1/2\nHP: 2/4\n💙 HP: 9/9", _applied, []} =
               Ledger.apply(window, [{"HP", "-1"}])

      plain = "HP: 3/5\nMP: 1/2"

      assert Ledger.apply(plain, [{"affinity-김석환", "+8"}, {"trust-kim", "+1, =63"}]) ==
               {plain, [], []}

      assert Ledger.unanswered([{"Nope", "+1", :ruled}], plain, plain) == [{"Nope", "+1", :ruled}]

      assert Ledger.current([%{"role" => "assistant", "content" => nil}], %{open: "HP", close: ""}) ==
               nil
    end

    test "rows: one labelled number, labels set apart by bars, and words that name nothing" do
      rows = "Mina | Affection 30 | cheerful | lobby\nTyler | Affection 10 | gloomy | room"

      assert {"Mina | Affection 32 | cheerful | lobby\nTyler | Affection 10 | gloomy | room",
              _applied, []} =
               Ledger.apply(rows, [{"Mina", "Affection +2"}])

      assert {^rows, [], [{"Mina", "happy", :unreadable}]} =
               Ledger.apply(rows, [{"Mina", "happy"}])

      assert {"Mina | Affection 40 | glad | the yard\nTyler | Affection 10 | gloomy | room",
              _applied, []} =
               Ledger.apply(rows, [{"Mina", "Affection 40 | glad | the yard"}])

      assert {"Tyler | L 2 | C 3\nMina | L 0 | C 0", _applied, []} =
               Ledger.apply("Tyler | L 1 | C 2\nMina | L 0 | C 0", [{"Tyler", "L +1 | C +1"}])
    end

    test "lines led by a mark: a clock is no name, and marked pieces on one line are fields" do
      assert Enum.map(Ledger.fields("⏰ 09:47\n📍 the beach\n❤️ 30"), &{&1.name, &1.value}) ==
               [{"⏰", "09:47"}, {"📍", "the beach"}, {"❤️", "30"}]

      assert Enum.map(Ledger.fields("⏰ 14:30 | 📍 학교 | ❤️ 30"), &{&1.name, &1.value}) ==
               [{"⏰", "14:30"}, {"📍", "학교"}, {"❤️", "30"}]

      assert {"⏰ 15:00 | 📍 학교 | ❤️ 32", _applied, []} =
               Ledger.apply("⏰ 14:30 | 📍 학교 | ❤️ 30", [{"⏰", "+30"}, {"❤️", "+2"}])

      assert Enum.map(Ledger.fields("HP: 3/5\n[Day 3 · 14:30]\nMP: 1/2"), &{&1.name, &1.value}) ==
               [{"HP", "3/5"}, {"Day", "3 · 14:30"}, {"MP", "1/2"}]

      # A table's row is still a row, whatever marks its cells have.
      assert [%{name: "Tyler", value: "62 | 😀 happy | 🏖 the beach"}, %{name: "Mina"}] =
               Ledger.fields("Tyler | 62 | 😀 happy | 🏖 the beach\nMina | 40 | 😐 calm | 🏠 home")
    end

    test "lines of blanks cost no time" do
      window =
        "[S]\nHP: 3/5\nMP: 1/2\n" <>
          String.duplicate(String.duplicate(" ", 1_990) <> "x\n", 5) <> "[/S]"

      {time, fields} = :timer.tc(fn -> Ledger.fields(window, %{open: "[S]", close: "[/S]"}) end)
      assert time < 1_500_000
      assert Enum.map(fields, & &1.name) == ["HP", "MP"]
    end

    test "lists: things with brackets, amounts with remarks, a thing renamed, words for gained and used" do
      habits = %{separator: ", ", empty: "None"}

      assert Listing.change(
               "None",
               "+Survival Kit (Fire Starter, Matches, Nuts), +Isekai Guidebook, +Contract (Unsigned)",
               habits
             ) ==
               {"Survival Kit (Fire Starter, Matches, Nuts), Isekai Guidebook, Contract (Unsigned)",
                nil}

      kit = "Survival Kit (Fire Starter, Matches, Nuts), Isekai Guidebook"
      assert Listing.change(kit, "+Rope", habits) == {kit <> ", Rope", nil}

      assert Listing.change(kit, "-Isekai Guidebook", habits) ==
               {"Survival Kit (Fire Starter, Matches, Nuts)", nil}

      assert Listing.change("0G, 2S, 0C", "+2S (now 4S)", habits) == {"0G, 4S, 0C", nil}
      assert Listing.change("0G, 2S, 94C", "-1C (the bet)", habits) == {"0G, 2S, 93C", nil}

      assert Listing.change("Slash, Parry", "Slash → Slash II", habits) ==
               {"Slash II, Parry", nil}

      assert Listing.change(
               "Potion × 3, rope × 1",
               "Potion × 1 used, mana stone × 5 gained",
               habits
             ) ==
               {"Potion × 2, rope × 1, mana stone × 5", nil}
    end

    test "a level gained by experience this turn pays for a point spent this turn" do
      spec = %{
        open: "[Status]",
        close: "[Status]",
        rules: [
          "when EXP >= EXP.max: Level += 1; EXP -= EXP.max",
          "when Level rises: Stat Point += 5",
          "when Strength rises: Stat Point -= 1"
        ]
      }

      before = "[Status]\n- Level: 3\n- EXP: 90 / 100\n- Stat Point: 0\n- Strength: 10\n[Status]"
      {changed, _applied, []} = Ledger.apply(before, [{"EXP", "+25"}, {"Strength", "+3"}], spec)
      {settled, _ruled} = Ledger.settle(changed, spec, before)

      assert settled ==
               "[Status]\n- Level: 4\n- EXP: 15 / 100\n- Stat Point: 2\n- Strength: 13\n[Status]"
    end

    test "a stream: a tag on a line that begins with a short opening text, and CR LF" do
      streamed = fn pieces, open ->
        {:ok, sent} = Agent.start_link(fn -> "" end)
        {on_delta, flush} = Ledger.filter(&Agent.update(sent, fn all -> all <> &1 end), open)
        Enum.each(pieces, on_delta)
        flush.()
        Agent.get(sent, & &1)
      end

      assert streamed.(
               ["She nods.\n[OOC: done] <aethrion-ledger>\nTrust: +2\n</aethrion-ledger>"],
               "["
             ) == "She nods.\n[OOC: done] "

      assert streamed.(
               ["She nods.\n[OO", "C: done]\nAnd left.\n", "[ Trust: 3% | Anger: 5% ]"],
               "["
             ) ==
               "She nods.\n[OOC: done]\nAnd left.\n"

      # What went out with CR LF is how the finished reply begins.
      assert Reply.unsent("Line one.\nLine two.\n\nHP: 25 / 48", "Line one.\r\nLine two.\r\n") ==
               "\nHP: 25 / 48"
    end
  end

  describe "a fourth review" do
    @status %{open: "[S]", close: "[/S]"}

    # (Time limits in this file are five times what a laptop needs, for a
    # shared CI machine: they are there for what goes wrong by a power.)
    test "time: brackets never closed in a list, runs of blanks, many fields of one name" do
      bags = Enum.map_join(1..5, "\n", fn n -> "Bag#{n}: " <> String.duplicate("(a, ", 495) end)
      window = "[S]\nHP: 30 / 48\n" <> bags <> "\n[/S]"
      changes = for n <- 1..40, do: {"Bag#{rem(n, 5) + 1}", "+x"}
      {time, _result} = :timer.tc(fn -> Ledger.apply(window, changes, @status) end)
      assert time < 15_000_000

      blanks = "She nods." <> String.duplicate(" ", 50_000) <> "He leaves."
      {time, {_story, nil}} = :timer.tc(fn -> Ledger.take(blanks) end)
      assert time < 2_500_000

      same = "[S]\n" <> String.duplicate("HP: 1/2\n", 600) <> "[/S]"
      {time, fields} = :timer.tc(fn -> Ledger.fields(same, @status) end)
      assert time < 7_500_000
      assert length(fields) == 600
    end

    test "what was streamed up to a blank on the story's last line is followed by the window on a line of its own" do
      text = "The goblin hits you.\n\n[Status]\nHP: 25 / 48\nMP: 3 / 5"
      gone = "The goblin hits you. "
      spec = %{open: "[Status]", close: ""}

      shown = gone <> Reply.unsent(text, gone)

      assert Ledger.current([%{"role" => "assistant", "content" => shown}], spec) ==
               "[Status]\nHP: 25 / 48\nMP: 3 / 5"

      assert Reply.unsent("The end.", "The end. ") == ""
    end

    test "an aside in brackets is not the window; nor are lines of speech under a heading" do
      spec = %{open: "[", close: "]"}

      current = fn content ->
        Ledger.current([%{"role" => "assistant", "content" => content}], spec)
      end

      assert current.(
               "You open the chest.\n[System: Quest accepted | Reward: 50 gold]\n\n[Day 3 · noon]\nHP: 30 / 48\nMP: 3 / 5"
             ) ==
               "[Day 3 · noon]\nHP: 30 / 48\nMP: 3 / 5"

      assert current.(
               "[ Trust: 3% | Anger: 5% | hm, who is this ]\n\n[Later]\nMina: hello.\nJisoo: hi."
             ) ==
               "[ Trust: 3% | Anger: 5% | hm, who is this ]"
    end

    test "a window after marks or blanks at the start of its line" do
      for lines <- [
            "　HP: 10/20\n　MP: 5/5",
            "❤️ HP: 10/20\n💙 MP: 5/5",
            String.duplicate(" ", 20) <> "HP: 10/20\n" <> String.duplicate(" ", 20) <> "MP: 5/5"
          ] do
        assert Ledger.window("story.\n\n" <> lines, %{open: "HP:", close: ""}) != nil, lines
      end

      assert Ledger.window("story.\n\nEnemy HP: 10/20\nMP: 5/5", %{open: "HP:", close: ""}) == nil
    end

    test "names that end in a number, and a title on the opening line" do
      assert Enum.map(
               Ledger.fields("Player 1: 30 / 48\nPlayer 2: 12 / 20\nSlot 3: 15 arrows"),
               & &1.name
             ) ==
               ["Player 1", "Player 2", "Slot 3"]

      assert {"Player 1: 5 / 9\nPlayer 2: 12 / 20", _applied, []} =
               Ledger.apply("Player 1: 5 / 9\nPlayer 2: 9 / 20", [{"Player 2", "+3"}])

      spec = %{open: "***", close: "***"}
      window = "*** Status ***\nHP: 3/5\nMP: 1/2\nShe wonders who he might be.\n***"

      assert {"*** Status ***\nHP: 3/5\nMP: 1/2\nHe seems kind after all.\n***", _applied, []} =
               Ledger.apply(window, [{"Note", "He seems kind after all."}], spec)
    end

    test "lists: a bracket never closed, a count or an end after an arrow, nothing gained" do
      habits = %{separator: ", ", empty: "None"}

      {list, nil} = Listing.change("Potion × 3, Rope × 1", "+Sword (broken", habits)
      assert Listing.change(list <> ", Key × 1", "-Key", habits) == {list, nil}

      assert Listing.change("Potion × 3, Smile :(, Key × 1", "-Key", habits) ==
               {"Potion × 3, Smile :(", nil}

      assert Listing.change("Potion × 3, Rope × 1", "Potion × 3 → 2", habits) ==
               {"Potion × 2, Rope × 1", nil}

      assert Listing.change("Potion × 3, Rope × 1", "Rope → none", habits) == {"Potion × 3", nil}
      assert Listing.change("Potion × 3, Rope × 1", "Rope → used", habits) == {"Potion × 3", nil}

      assert Listing.change("Potion × 3, Rope × 1", "Rope → Potion", habits) ==
               {"Potion × 4", nil}

      for said <- ["nothing gained", "No items gained"] do
        assert {"HP: 3/5\nInventory: Potion × 3, Rope × 1", [], [_refused]} =
                 Ledger.apply("HP: 3/5\nInventory: Potion × 3, Rope × 1", [{"Inventory", said}])
      end
    end

    test "words and numbers: arrows from part of the old words, a maximum with a fraction, marks of bold" do
      value = fn window, name, change ->
        {now, _applied, refused} = Ledger.apply(window, [{name, change}])
        {Enum.find(Ledger.fields(now), &(&1.name == name)).value, refused}
      end

      assert value.("HP: 3/5\nMood: calm (resting)", "Mood", "calm → tense") == {"tense", []}
      assert value.("HP: 3/5\nMood: calm", "Mood", "tense → calm") == {"calm", []}
      assert value.("HP: 3/5\n기분: 평온함", "기분", "평온 → 긴장") == {"긴장", []}

      assert value.("Stamina: 78.5 / 120\nHP: 3/5", "Stamina", "+1") == {"79.5 / 120", []}

      assert {"Stamina: 78.5 / 130\nHP: 3/5", _applied, []} =
               Ledger.apply("Stamina: 78.5 / 120\nHP: 3/5", [{"Stamina.max", "+10"}])

      assert {"Karma: -7\nHP: 3/5", [], [{"Karma", "0", :unsigned}]} =
               Ledger.apply("Karma: -7\nHP: 3/5", [{"Karma", "0"}])

      assert Ledger.take("ok\n<aethrion-ledger>\nMood: **tense**\n</aethrion-ledger>") ==
               {"ok", [{"Mood", "tense"}]}

      assert value.("EXP: 90 / 300\nLevel: 6", "EXP", "+150 (90 → 240); so → Level 7, EXP resets") ==
               {"240 / 300", []}

      assert value.("Gold: 1,250 G\nHP: 3/5", "Gold", "+50 (now 1,300); → shop 2") ==
               {"1,300 G", []}
    end

    test "a row with one labelled number takes a number" do
      rows = "Mina | Affection 30 | cheerful | lobby\nTyler | Affection 10 | gloomy | room"

      mina = fn change ->
        rows |> Ledger.apply([{"Mina", change}]) |> elem(0) |> String.split("\n") |> hd()
      end

      assert mina.("+2") == "Mina | Affection 32 | cheerful | lobby"
      assert mina.("-3 (annoyed)") == "Mina | Affection 27 | cheerful | lobby"
      assert mina.("=35") == "Mina | Affection 35 | cheerful | lobby"
      assert Ledger.instruction(rows) =~ "`Mina: Affection +1`"
    end

    test "tags closed wrongly are closed; a line of the story that only looks like a marker stays" do
      wrong = "The goblin hits you.\n<aethrion-ledger>\nHP: -5\n</ledger>"
      assert Ledger.take(wrong) == {"The goblin hits you.", [{"HP", "-5"}]}
      refute Ledger.cut_off?(wrong)
      refute Ledger.cut_off?("x\n<aethrion-ledger>\nHP: -5\n</aethrion-ledgers>")
      assert Ledger.cut_off?("x </aethrion-ledger>\n<aethrion-ledger>\nHP: -5")

      # The story's own lines.
      assert Ledger.take("He typed:\n</ledger>\nand saved.") ==
               {"He typed:\n</ledger>\nand saved.", nil}

      assert Ledger.unmarked("Morning.\n━━━━━━━━\nEvening.", %{open: "━━━━━━━━", close: ""}) ==
               "Morning.\n━━━━━━━━\nEvening."

      assert Ledger.unmarked("Status\nfine.", %{open: "Status", close: ""}) == "Status\nfine."
    end
  end

  describe "a fifth review" do
    @rpg "[Status]\n- HP: 30 / 48\n- Gold: 120\n- Item: Potion × 3 / Rope\n[Status]"
    @sp %{open: "[Status]", close: "[Status]"}

    defp turn(previous, raw, spec) do
      chat = [
        %{"role" => "assistant", "content" => previous},
        %{"role" => "user", "content" => "go"}
      ]

      plan = Reply.plan(%{window: spec, player: nil}, chat, %{line?: true, locale: :en})
      Reply.finish(raw, "<aethrion-status></aethrion-status>", plan)
    end

    test "a story of bytes that are no text, and many tags left open, cost no crash and no time" do
      raw = "You rest " <> <<0xEA, 0xB0>> <> "\n<aethrion-ledger>\nHP: +1\n</aethrion-ledger>"
      assert {text, _status} = turn("x\n\n" <> @rpg, raw, @sp)
      assert text =~ "- HP: 31 / 48"

      open = "Story.\n" <> String.duplicate("<aeth-ledger>\n\n", 3_333)
      {time, _result} = :timer.tc(fn -> turn("x\n\n" <> @rpg, open, @sp) end)
      assert time < 3_500_000
    end

    test "a raise the rule will make itself is not the model's as well" do
      window = "[Status]\n- Day: 3\n- AP: 1 / 3\n- HP: 12 / 48\n- Deaths: 0\n[Status]"
      rules = ["when AP <= 0: Day += 1; AP = AP.max", "when HP <= 0: Deaths += 1; HP = HP.max"]
      spec = Map.put(@sp, :rules, rules)

      {night, _status} =
        turn(
          "x\n\n" <> window,
          "Night.\n<aethrion-ledger>\nAP: -1\nDay: +1\n</aethrion-ledger>",
          spec
        )

      assert night =~ "- Day: 4\n- AP: 3 / 3"

      {dead, _status} =
        turn(
          "x\n\n" <> window,
          "Dark.\n<aethrion-ledger>\nHP: -12\nDeaths: +1\n</aethrion-ledger>",
          spec
        )

      assert dead =~ "- Deaths: 1\n"

      {hurt, _status} =
        turn(
          "x\n\n" <> window,
          "Ow.\n<aethrion-ledger>\nHP: -2\nDeaths: +1\n</aethrion-ledger>",
          spec
        )

      assert hurt =~ "- HP: 10 / 48\n- Deaths: 0\n"
    end

    test "what the story spent: a thing carried, as a word of its own, and not denied" do
      window =
        "[Status]\n- HP: 30 / 48\n- Party: Mina / Tyler\n- Skills: Fireball / Heal\n- Item: Potion × 3 / Ring / Map\n[Status]"

      for story <- [
            "You ate breakfast during the long silence.",
            "You threw a Fireball at the goblin.",
            "You handed over the letter to Mina.",
            "You never drank the potion."
          ] do
        assert Ledger.unsaid(story, window, [{"HP", "+1"}], @sp) == [], story
      end

      assert Ledger.unsaid("You drank the potion in one gulp.", window, [{"HP", "+1"}], @sp) ==
               [{"Item", "-Potion × 1", :unsaid}]

      korean = "[상태창]\n- 동료: 미나 / 타일러\n- 소지품: 사과 × 2 / 지도 / 회복약 × 1\n[상태창]"
      spec = %{open: "[상태창]", close: "[상태창]"}

      for story <- [
            "미나는 말없이 빵을 먹었다.",
            "그럴지도 모른다고 생각하며 빵을 먹었다.",
            "그녀는 사과하고 물을 마셨다.",
            "회복약을 안 마셨다."
          ] do
        assert Ledger.unsaid(story, korean, [], spec) == [], story
      end

      assert Ledger.unsaid("사과를 한 입 베어 먹었다.", korean, [], spec) == [{"소지품", "-사과 × 1", :unsaid}]
    end

    test "a heading written whole with other marks between its parts, or part by part with arrows" do
      spec = %{open: "[Day", close: ""}
      window = "[Day 1 · night · the keep]\nHP: 30 / 48\nMP: 3 / 5"

      head = fn change ->
        window |> Ledger.apply([{"Day", change}], spec) |> elem(0) |> String.split("\n") |> hd()
      end

      assert head.("2, morning, the yard") == "[Day 2, morning, the yard]"
      assert head.("2") == "[Day 2 · night · the keep]"
      assert head.("1 · night · the keep → the yard") == "[Day 1 · night · the yard]"
      assert head.("1 → 2 · night → morning · the keep") == "[Day 2 · morning · the keep]"
    end

    test "lists: something used and nothing gained; a sign after the thing; a thing gone" do
      item = fn change ->
        @rpg
        |> Ledger.apply([{"Item", change}], @sp)
        |> elem(0)
        |> String.split("\n")
        |> Enum.at(3)
      end

      assert item.("Potion × 1 used, nothing gained") == "- Item: Potion × 2 / Rope"
      assert item.("Potion -1, Arrow +10") == "- Item: Potion × 2 / Rope / Arrow × 10"
      assert item.("Rope → gone") == "- Item: Potion × 3"
      assert item.("Rope → -") == "- Item: Potion × 3"
      # A sign after a thing the list does not have is the thing's own: the
      # list of counted things is not said anew in a word.
      assert {_window, [], [{"Item", "Sword +1", :unreadable}]} =
               Ledger.apply(@rpg, [{"Item", "Sword +1"}], @sp)

      assert item.("+Sword +1") == "- Item: Potion × 3 / Rope / Sword +1"
    end

    test "numbers that may go below nothing; odd numerals; a field named twice" do
      window = "[Status]\n- Temp: 3°C\n- Karma: 2\n- Stat Point: 5\n- Gold: 120\n[Status]"

      assert {"[Status]\n- Temp: -5°C\n- Karma: -3\n- Stat Point: 0\n- Gold: 0\n[Status]",
              _applied, [{"Stat Point", "-8", :clamped}, {"Gold", "-500", :clamped}]} =
               Ledger.apply(
                 window,
                 [{"Temp", "-8"}, {"Karma", "-5"}, {"Stat Point", "-8"}, {"Gold", "-500"}],
                 @sp
               )

      for odd <- [".5", "1,2,3", "1.2.3"] do
        assert {^window, [], [{"Gold", ^odd, _reason}]} =
                 Ledger.apply(window, [{"Gold", odd}], @sp)
      end

      assert {now, _applied, []} = Ledger.apply(window, [{"Gold", "35"}, {"Gold", "20"}], @sp)
      assert now =~ "- Gold: 20\n"
    end

    test "a row's one number given a bare 0; a maximum of nothing; a change of a short name" do
      rows = "Mina | Affection 30 | cheerful | lobby\nTyler | Affection 10 | gloomy | room"
      assert {^rows, [], [{"Mina", "0", :unreadable}]} = Ledger.apply(rows, [{"Mina", "0"}])

      pairs = "HP: 30 / 48\nMP: 3 / 5"

      assert {^pairs, [], [{"HP.max", "-100", :unknown}]} =
               Ledger.apply(pairs, [{"HP.max", "-100"}])

      korean = "[Status]\n- HP: 30 / 48\n- 골드: 120\n[Status]"

      assert {"[Status]\n- HP: 31 / 48\n- 골드: 125\n[Status]", _applied, []} =
               Ledger.apply(korean, [{"HP Change", "+1"}, {"골드 변화", "+5"}], @sp)
    end

    test "values after a mark keep their links and faces; a thought with a colon is a note" do
      # (They are refused, as they would read as fields of other names: not rewritten.)
      marks = "📍 the beach\n🔗 none\n💬 hm, who is that"

      assert {^marks, [], [{"💬", "ok :)", :unsound}, {"🔗", "https://example.com/a:b", :unsound}]} =
               Ledger.apply(marks, [{"🔗", "https://example.com/a:b"}, {"💬", "ok :)"}])

      assert {"📍 Seoul — the station\n🔗 none\n💬 hm, who is that", _applied, []} =
               Ledger.apply(marks, [{"📍", "Seoul: the station"}])

      assert {"[ Trust: 12% | Anger: 5% | He said — no ]", _applied, []} =
               Ledger.apply(
                 "[ Trust: 12% | Anger: 5% | a thought here ]",
                 [{"Note", "He said: no"}],
                 %{open: "[ Trust:", close: "]"}
               )
    end

    test "a window whose opening is a bullet or a mark keeps its first field" do
      assert Enum.map(
               Ledger.fields("- HP: 30 / 48\n- MP: 3 / 5\n- Gold: 120", %{open: "-", close: ""}),
               & &1.name
             ) ==
               ["HP", "MP", "Gold"]

      assert Enum.map(
               Ledger.fields("◈Time: 09:00\n◈Place: the inn\n◈HP: 30 / 48", %{
                 open: "◈",
                 close: ""
               }),
               & &1.name
             ) ==
               ["Time", "Place", "HP"]
    end

    test "numbered lines of the story are no window; a tag opened twice leaves nothing" do
      {text, _status} =
        turn(
          "x\n\nHP: 10/20\nMP: 5/5",
          "You rest and count what came back:\n1. HP: fully restored\n2. MP: fully restored\nThen you sleep.\n<aethrion-ledger>\nHP: +10\n</aethrion-ledger>",
          %{open: "HP:", close: ""}
        )

      assert text =~ "1. HP: fully restored\n2. MP: fully restored\nThen you sleep."
      assert text =~ "HP: 20/20\nMP: 5/5"

      assert Ledger.take(
               "S.\n<aethrion-ledger>\n<aethrion-ledger>\nHP: -5\n</aethrion-ledger>\n</aethrion-ledger>\nAfter"
             ) ==
               {"S.\n\n\nAfter", [{"HP", "-5"}]}

      for tags <- [
            {"<aethrion-ledgers>", "</aethrion-ledgers>"},
            {"<aethrion ledger>", "</aethrion ledger>"},
            {"<ledger>", "</ledger>"}
          ] do
        {open, close} = tags
        assert {"S.", [{"HP", "-5"}]} = Ledger.take("S.\n" <> open <> "\nHP: -5\n" <> close)
      end
    end

    test "a stream goes on past a word that only begins as our tags do" do
      streamed = fn pieces ->
        {:ok, sent} = Agent.start_link(fn -> "" end)
        {on_delta, flush} = Ledger.filter(&Agent.update(sent, fn all -> all <> &1 end), nil)
        Enum.each(pieces, on_delta)
        flush.()
        Agent.get(sent, & &1)
      end

      assert streamed.(["The <aether> hums ", "around you.\nYou walk on."]) ==
               "The <aether> hums around you.\nYou walk on."

      assert streamed.(["King <Aethel", "red> stands."]) == "King <Aethelred> stands."

      assert streamed.(["Done.\n<aeth", "erion-ledger>\nHP: -1\n</aetherion-ledger>"]) ==
               "Done.\n"

      assert streamed.(["Done.\n<led", "ger>\nHP: -1\n</ledger>"]) == "Done.\n"
      assert streamed.(["Done. <aethrion-led"]) == "Done. "
    end
  end

  describe "a sixth review" do
    @rpg6 "[Status]\n- HP: 30 / 48\n- Gold: 120\n- Item: Potion × 3 / Rope\n- Location: the inn\n- Date: 2026-10-05 (Mon)\n[Status]"
    @st %{open: "[Status]", close: "[Status]"}
    @rows "[Day 1 · night · the keep]\nPresent: Mina\nTyler | 62 | calm | a thought\nMina | Rank 10 | P 0 (+0) | L 0 | C 0 | room | -"
    @day %{open: "[Day", close: ""}

    defp turn6(window, spec, lines) do
      chat = [
        %{"role" => "assistant", "content" => "You wake.\n\n" <> window},
        %{"role" => "user", "content" => "go"}
      ]

      plan = Reply.plan(%{window: spec, player: nil}, chat, %{line?: true, locale: :en})
      raw = "Story.\n<aethrion-ledger>\n" <> lines <> "\n</aethrion-ledger>"
      Reply.finish(raw, "<aethrion-status></aethrion-status>", plan)
    end

    # (The limits are for what goes wrong by a power, minutes where there
    # were moments: a shared CI machine takes five times a laptop's time.)
    test "time: a bag of many things and a long story; a line of many steps" do
      window =
        "[Status]\n- HP: 30 / 48\n- Item: " <> String.duplicate("+1, ", 474) <> "+1\n[Status]"

      story = String.duplicate("+1, ", 12_250)
      {time, _hints} = :timer.tc(fn -> Ledger.unsaid(story, window, [{"HP", "-1"}], @st) end)
      assert time < 8_000_000

      steps = String.slice(String.duplicate("+1, ", 100), 0, 399)

      {time, _result} =
        :timer.tc(fn -> Ledger.apply(window, List.duplicate({"Item", steps}, 40), @st) end)

      assert time < 15_000_000

      {time, _result} =
        :timer.tc(fn ->
          Ledger.apply(window, [{"HP.max", String.duplicate(" ", 20_000)}], @st)
        end)

      assert time < 3_000_000
    end

    test "N/A leaves a list, a place, a date as they are; a number that stands alone stays above nothing" do
      {text, _status} =
        turn6(@rpg6, @st, "HP: -5\nGold: N/A\nItem: N/A\nLocation: N/A\nDate: N/A")

      assert text =~
               "- HP: 25 / 48\n- Gold: 120\n- Item: Potion × 3 / Rope\n- Location: the inn\n- Date: 2026-10-05 (Mon)\n"

      assert {"[Status]\n- HP: 0\n- Level: 0\n- Karma: -3\n[Status]", _applied,
              [{"HP", "-50", :clamped}, {"Level", "-2", :clamped}]} =
               Ledger.apply(
                 "[Status]\n- HP: 30\n- Level: 1\n- Karma: 2\n[Status]",
                 [{"HP", "-50"}, {"Level", "-2"}, {"Karma", "-5"}],
                 @st
               )
    end

    test "a window whose lines all begin with its opening mark is all of them" do
      window = "◈Time: 09:00\n◈Place: the inn\n◈HP: 30 / 48\n◈Gold: 120"
      spec = %{open: "◈", close: ""}

      assert Ledger.current([%{"role" => "assistant", "content" => "Story.\n\n" <> window}], spec) ==
               window

      {text, _status} = turn6(window, spec, "Time: 09:30\nHP: -5")
      assert text =~ "◈Time: 09:30\n◈Place: the inn\n◈HP: 25 / 48\n◈Gold: 120"
    end

    test "a heading given with fewer parts keeps the rest; a row given fewer cells keeps the rest" do
      head = fn lines ->
        @rows
        |> turn6(@day, lines)
        |> elem(0)
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "[Day"))
      end

      assert head.("Day: 2 (morning)") == "[Day 2 (morning) · night · the keep]"
      assert head.("Day: 2, morning, the yard") == "[Day 2, morning, the yard]"

      {text, _status} = turn6(@rows, @day, "Tyler: 65 | wary")
      assert text =~ "Tyler | 65 | wary | a thought\n"
    end

    test "the model's working with its unit leaves no bracket; a word for which way a number moves" do
      line = "[ Trust: 3% | Anger: 5% | Gold: 120G | a thought of hers ]"
      spec = %{open: "[ Trust:", close: "]"}

      for {lines, expected} <- [
            {"Trust: +2 (3% → 5%)", "[ Trust: 5% | Anger: 5% | Gold: 120G |"},
            {"Trust: 5% (+2)", "[ Trust: 5% | Anger: 5% | Gold: 120G |"},
            {"Gold: +30 (120G → 150G)", "| Gold: 150G | a thought"},
            {"Gold: 30 gained", "| Gold: 150G |"},
            {"Gold: lost 30", "| Gold: 90G |"},
            {"Gold: 30 획득", "| Gold: 150G |"},
            {"Trust: 2 상승", "[ Trust: 5% |"}
          ] do
        {text, _status} = turn6(line, spec, lines)
        assert text =~ expected, lines
      end
    end

    test "rows and headings written as the window writes them; several changes on one line" do
      {text, _status} =
        turn6(@rows, @day, "Tyler | 65 | wary | What is she up to?\n[Day 2 · morning · the yard]")

      assert text =~ "[Day 2 · morning · the yard]\n"
      assert text =~ "Tyler | 65 | wary | What is she up to?\n"

      {text, _status} = turn6(@rpg6, @st, "HP: -12, Gold: +5\nLocation: the market, Item: -Rope")
      assert text =~ "- HP: 18 / 48\n- Gold: 125\n- Item: Potion × 3\n- Location: the market\n"

      line =
        "[ Trust: 3% | Anger: 5% | Date: 1025/03/05 | Location: the hut | a thought of hers ]"

      {text, _status} =
        turn6(
          line,
          %{open: "[ Trust:", close: "]"},
          "[ Trust: 5% | Anger: 2% | Date: 1025/03/06 | Location: the forest | She is watching ]"
        )

      assert text =~
               "[ Trust: 5% | Anger: 2% | Date: 1025/03/06 | Location: the forest | She is watching ]"
    end

    test "the line a reply was cut off in is not taken, and is said so" do
      chat = [
        %{"role" => "assistant", "content" => "You wake.\n\n" <> @rpg6},
        %{"role" => "user", "content" => "go"}
      ]

      plan = Reply.plan(%{window: @st, player: nil}, chat, %{line?: true, locale: :en})

      {text, status} =
        Reply.finish(
          "Story.\n<aethrion-ledger>\nHP: -12\nGold: +15",
          "<aethrion-status></aethrion-status>",
          plan
        )

      assert text =~ "- HP: 18 / 48\n- Gold: 120\n"
      assert status =~ "Ledger · Gold: +15 (the reply was cut off in this line)"
    end

    test "a scene left open ends at the next tag of ours" do
      assert {"Story.\n<aethrion-ledger>\nHP: -5\n</aethrion-ledger>", [%{name: "Mina"}]} =
               Scene.take(
                 "Story.\n<aethrion-scene>Mina\n<aethrion-ledger>\nHP: -5\n</aethrion-ledger>"
               )
    end

    test "on a stream, a window the model printed is followed by the whole window the rules keep" do
      text = "The goblin hits you.\n\n[Day 3 · noon]\nHP: 25 / 48\nMP: 3 / 5"
      gone = "The goblin hits you.\n\n[Day 3 · noon]\nHP: 26 / 48\nMP: 3 / 5\n"
      shown = gone <> Reply.unsent(text, gone)

      assert Ledger.current([%{"role" => "assistant", "content" => shown}], %{
               open: "[",
               close: "]"
             }) ==
               "[Day 3 · noon]\nHP: 25 / 48\nMP: 3 / 5"
    end
  end
end
