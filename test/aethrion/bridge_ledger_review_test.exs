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
      plan = plan(%{})
      finished = "A hit.\n\n[Status]\n- Level: 5\n- HP: 25 / 48\n- Gold: 120G\n[Status]"
      # Streamed as it should be: the rest follows.
      assert Reply.unsent(finished, "A hit.\n\n", plan) ==
               "[Status]\n- Level: 5\n- HP: 25 / 48\n- Gold: 120G\n[Status]"

      # A window the model printed slipped out: the ledger's comes after it.
      slipped = "A hit.\n\n**[Status]**\n- HP: 30 / 48\n**[Status]**"

      assert Reply.unsent(finished, slipped, plan) ==
               "\n\n[Status]\n- Level: 5\n- HP: 25 / 48\n- Gold: 120G\n[Status]"
    end
  end
end
