defmodule Aethrion.BridgeLedgerRulesTest do
  use ExUnit.Case, async: true

  alias Aethrion.Bridge.Ledger.Rules

  @names ["hp", "exp", "level", "stat point", "vigor", "trust", "inventory load", "vitality"]

  defp rules(texts) do
    for text <- texts do
      assert {:ok, rule} = Rules.parse(text, @names), "#{text} did not parse"
      rule
    end
  end

  defp values(overrides \\ %{}) do
    Map.merge(
      %{
        "hp" => %{now: 80, max: 80},
        "exp" => %{now: 0, max: 100},
        "level" => %{now: 1, max: nil},
        "stat point" => %{now: 0, max: nil},
        "vigor" => %{now: 8, max: nil},
        "trust" => %{now: 10, max: nil},
        "inventory load" => %{now: 12, max: 120},
        "vitality" => %{now: 12, max: nil}
      },
      overrides
    )
  end

  describe "parse/2" do
    test "reads what always holds and what happens, in the window's field names" do
      assert {:ok, {:always, {"hp", :max}, {:op, :times, {:field, "vigor", :now}, {:num, 10.0}}}} =
               Rules.parse("HP.max = Vigor * 10", @names)

      assert {:ok, {:when, {:op, :gte, {:field, "exp", :now}, {:field, "exp", :max}}, changes}} =
               Rules.parse("when EXP >= EXP.max: Level += 1; EXP -= EXP.max", @names)

      assert [{:add, {"level", :now}, {:num, 1.0}}, {:sub, {"exp", :now}, {:field, "exp", :max}}] =
               changes

      assert {:ok, {:rise, "level", [{:add, {"stat point", :now}, _expr}]}} =
               Rules.parse("when Level rises: Stat Point += if(Level % 5 == 0, 15, 5)", @names)
    end

    test "takes the ways a model spells things" do
      # A field's spaces as "_" or "." or none, or its first word alone.
      for text <- [
            "Inventory_Load.max = Vitality * 10",
            "Inventory.max = Vitality × 10",
            "InventoryLoad.max = Vitality * 10"
          ] do
        assert {:ok, {:always, {"inventory load", :max}, _expr}} = Rules.parse(text, @names)
      end

      # The condition after the changes, and "then" for the colon.
      assert {:ok, {:rise, "level", _changes}} =
               Rules.parse("Stat.Point += 5 when Level increases", @names)

      assert {:ok, {:when, _condition, [{:set, {"hp", :now}, _max}]}} =
               Rules.parse("when HP > HP.max then HP = HP.max", @names)

      assert {:ok, {:always, {"trust", :now}, _expr}} =
               Rules.parse("Trust = clamp(Trust, Trust.before − 2, Trust.before + 2)", @names)
    end

    test "what is not in the language is no rule" do
      for text <- [
            # A field the window does not have, a function there is none of, words.
            "Mana.max = Vigor * 3",
            "HP.max = system(1)",
            "when Trust or Anger change: change by -2, -1, 0, +1, or +2",
            "when heroic_deed: Trust += 5~15",
            # Something that happens with no condition, or to what it was before.
            "HP += 2",
            "Trust.before = 3",
            "HP.max = (Vigor * 10",
            ""
          ] do
        assert Rules.parse(text, @names) == :error, "#{text} parsed"
      end
    end

    test "a rule that leaves what it looks at alone is none: it would never stop" do
      assert Rules.parse("when Level % 5 == 0: Stat Point += 15", @names) == :error
      assert {:ok, _rule} = Rules.parse("when Level % 5 == 0: Level += 1", @names)
    end
  end

  describe "run/3" do
    test "a maximum follows its stat, and a pair that was full stays full" do
      rules = rules(["HP.max = Vigor * 10"])

      assert %{"hp" => %{now: 100, max: 100}} =
               Rules.run(values(%{"vigor" => %{now: 10, max: nil}}), rules)

      hurt = values(%{"vigor" => %{now: 10, max: nil}, "hp" => %{now: 31, max: 80}})
      assert %{"hp" => %{now: 31, max: 100}} = Rules.run(hurt, rules)
    end

    test "a level-up happens as often as it holds, each seeing the one before" do
      rules =
        rules([
          "EXP.max = floor(100 * 1.15 ^ (Level - 1))",
          "when EXP >= EXP.max: Level += 1; EXP -= EXP.max",
          "when Level rises: Stat Point += if(Level % 5 == 0, 15, 5)"
        ])

      before = values()

      # 100, 115, 132, 152: four levels and 86 toward the fifth's 174.
      assert %{
               "level" => %{now: 5},
               "exp" => %{now: 86, max: 174},
               "stat point" => %{now: 30}
             } = Rules.run(values(%{"exp" => %{now: 585, max: 100}}), rules, before)

      # 100 × 1.15 is 115, though the float falls just short of it.
      assert %{"exp" => %{max: 115}} = Rules.run(values(%{"level" => %{now: 2, max: nil}}), rules)
    end

    test "what a point gained gives is given once for each, whoever raised the field" do
      rules = rules(["when Level rises: Stat Point += if(Level % 5 == 0, 15, 5)"])
      raised = values(%{"level" => %{now: 6, max: nil}})
      before = values(%{"level" => %{now: 3, max: nil}})

      # Levels 4, 5, and 6: 5 + 15 + 5.
      assert %{"stat point" => %{now: 25}, "level" => %{now: 6}} =
               Rules.run(raised, rules, before)

      # With nothing to compare with, nothing has risen.
      assert %{"stat point" => %{now: 0}} = Rules.run(raised, rules)
      assert %{"stat point" => %{now: 0}} = Rules.run(before, rules, raised)
    end

    test "a number moves only so far in a turn, and stays within its range" do
      rules =
        rules([
          "Trust = clamp(Trust, Trust.before - 2, Trust.before + 2)",
          "Trust = clamp(Trust, 0, 100)"
        ])

      before = values(%{"trust" => %{now: 99, max: nil}})
      leapt = values(%{"trust" => %{now: 140, max: nil}})

      assert %{"trust" => %{now: 100}} = Rules.run(leapt, rules, before)
      assert %{"trust" => %{now: 97}} = Rules.run(values(), rules, before)
      # A first window has no turn before it: only the range holds.
      assert %{"trust" => %{now: 100}} = Rules.run(leapt, rules)
    end

    test "a rule that does not stop is left out, and the others are worked out" do
      rules =
        rules([
          "when Stat Point >= 0: Stat Point += 1",
          "when EXP >= EXP.max: Level += 1; EXP -= EXP.max"
        ])

      assert %{"level" => %{now: 2}, "exp" => %{now: 20}, "stat point" => %{now: 0}} =
               Rules.run(values(%{"exp" => %{now: 120, max: 100}}), rules)
    end

    test "what cannot be worked out changes nothing" do
      # A maximum for a number that has none, a division by nothing.
      rules = rules(["Level.max = 99", "HP.max = Vigor / (Level - 1)"])
      assert Rules.run(values(), rules) == values()
    end
  end

  test "a cost is paid for each point gained, from what there is" do
    rules = rules(["when Vigor rises: Stat Point -= 1"])
    before = values(%{"stat point" => %{now: 3, max: nil}})

    spent = Map.put(before, "vigor", %{now: 10, max: nil})
    assert %{"stat point" => %{now: 1}} = Rules.run(spent, rules, before)

    # More raised than there are points for: paid to nothing, not below.
    over = Map.put(before, "vigor", %{now: 13, max: nil})
    assert %{"stat point" => %{now: 0}, "vigor" => %{now: 13}} = Rules.run(over, rules, before)
    assert Rules.lowered(rules) == ["stat point"]
    assert Rules.raised(rules) == []
  end

  test "raised/1 and watched/1: what the rules raise themselves, and what may pass its maximum" do
    rules =
      rules([
        "HP.max = Vigor * 10",
        "when EXP >= EXP.max: Level += 1; EXP -= EXP.max",
        "when Level rises: Stat Point += 5"
      ])

    assert Rules.raised(rules) == ["level", "stat point"]
    assert Rules.watched(rules) == ["exp"]
  end
end
