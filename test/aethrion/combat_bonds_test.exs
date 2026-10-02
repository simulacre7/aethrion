defmodule Aethrion.CombatBondsTest do
  # Fights that follow how the fighters feel about each other.
  use ExUnit.Case, async: true

  alias Aethrion.{Combat, Event, Runtime, State}

  # A cleric and a rogue beside the player, and one wolf. `feel` sets
  # relationships as {from, to} => %{affinity, trust, tension}.
  defp party(feel \\ %{}, stats \\ %{}) do
    relationships =
      %{
        {"sera", "user"} => %{"affinity" => 25, "trust" => 20},
        {"doyun", "user"} => %{"affinity" => 30, "trust" => 20},
        {"sera", "doyun"} => %{"affinity" => 30, "trust" => 25},
        {"doyun", "sera"} => %{"affinity" => 30, "trust" => 25}
      }
      |> Map.merge(feel, fn _key, base, set -> Map.merge(base, set) end)
      |> Enum.map(fn {{from, to}, values} -> Map.merge(%{"from" => from, "to" => to}, values) end)

    base_stats = %{
      "user" => %{
        "hp" => 28,
        "max_hp" => 28,
        "ac" => 16,
        "attack_bonus" => 5,
        "damage_dice" => 1,
        "damage_die" => 8,
        "damage_bonus" => 3
      },
      "sera" => %{
        "hp" => 21,
        "max_hp" => 21,
        "ac" => 18,
        "attack_bonus" => 4,
        "damage_dice" => 1,
        "damage_die" => 6,
        "damage_bonus" => 2,
        "heal_dice" => 1,
        "heal_die" => 8,
        "heal_bonus" => 3,
        "party" => 1
      },
      "doyun" => %{
        "hp" => 20,
        "max_hp" => 20,
        "ac" => 14,
        "attack_bonus" => 5,
        "damage_dice" => 1,
        "damage_die" => 6,
        "damage_bonus" => 3,
        "party" => 1
      },
      "wolf" => %{
        "hp" => 60,
        "max_hp" => 60,
        "ac" => 1,
        "attack_bonus" => 20,
        "damage_dice" => 2,
        "damage_die" => 4,
        "damage_bonus" => 2,
        "enemy" => 1
      }
    }

    {:ok, state} =
      State.parse(%{
        "characters" => [
          %{"id" => "sera", "name" => "세라", "traits" => ["calm"]},
          %{"id" => "doyun", "name" => "도윤"},
          %{"id" => "wolf", "name" => "늑대"}
        ],
        "relationships" => relationships,
        "stats" => Map.merge(base_stats, stats, fn _id, base, set -> Map.merge(base, set) end)
      })

    state
  end

  defp run(state, events) do
    Enum.reduce(events, {state, []}, fn event, {state, outputs} ->
      {:ok, step} = Runtime.step(state, event)
      {step.state, outputs ++ step.outputs}
    end)
  end

  defp combat(outputs), do: for(%{type: :combat} = o <- outputs, do: o)
  defp hp(state, id), do: State.stat(state, id, "hp")
  defp feel(state, from, to), do: State.get_relationship(state, from, to)

  describe "a companion who cares steps in front of a blow" do
    test "when the one they care about is in danger, once a round" do
      state = party(%{{"sera", "doyun"} => %{"affinity" => 60}}, %{"doyun" => %{"hp" => 5}})
      before = feel(state, "doyun", "sera")

      {state, outputs} = run(state, [Event.attack("wolf", "doyun", counter: true)])

      assert [%{kind: :protected, character_id: "sera", to: "doyun"}, blow | _] = combat(outputs)
      assert blow.to == "sera" and blow.character_id == "wolf"
      assert hp(state, "doyun") == 5
      assert hp(state, "sera") < 21
      assert feel(state, "doyun", "sera").affinity > before.affinity
      assert feel(state, "doyun", "sera").trust > before.trust

      # A second blow the same round finds no one in the way.
      {state, outputs} = run(state, [Event.attack("wolf", "doyun", counter: true)])
      refute Enum.any?(combat(outputs), &(&1.kind == :protected))
      assert hp(state, "doyun") < 5 or Enum.any?(combat(outputs), &(&1.kind == :missed))
    end

    test "not by someone who does not care enough, or is badly hurt themselves" do
      for state <- [
            party(%{{"sera", "doyun"} => %{"affinity" => 40}}, %{"doyun" => %{"hp" => 5}}),
            party(%{{"sera", "doyun"} => %{"affinity" => 60}}, %{
              "doyun" => %{"hp" => 5},
              "sera" => %{"hp" => 9}
            }),
            # Not in danger: a scratch is taken.
            party(%{{"sera", "doyun"} => %{"affinity" => 60}})
          ] do
        {_state, outputs} = run(state, [Event.attack("wolf", "doyun", counter: true)])
        refute Enum.any?(combat(outputs), &(&1.kind == :protected))
      end
    end

    test "the player too, by a companion who loves them" do
      state = party(%{{"doyun", "user"} => %{"affinity" => 70}}, %{"user" => %{"hp" => 6}})
      {state, outputs} = run(state, [Event.attack("wolf", "user", counter: true)])
      assert [%{kind: :protected, character_id: "doyun", to: "user"} | _] = combat(outputs)
      assert hp(state, "user") == 6
    end
  end

  describe "a fall" do
    test "enrages those who loved the fallen, for the rest of the fight" do
      state =
        party(%{{"sera", "doyun"} => %{"affinity" => 60}}, %{
          "doyun" => %{"hp" => 1},
          "sera" => %{"hp" => 9}
        })

      {state, outputs} = run(state, [Event.attack("wolf", "doyun", counter: true)])
      assert hp(state, "doyun") == 0

      assert Enum.any?(
               combat(outputs),
               &match?(%{kind: :enraged, character_id: "sera", to: "doyun"}, &1)
             )

      assert State.stat(state, "sera", "fury") == 1

      {_state, outputs} = run(state, [Event.attack("sera", "wolf", counter: true)])
      assert [%{character_id: "sera", attack_bonus: 6} | _] = combat(outputs)
    end

    test "leaves the others as they were" do
      state = party(%{}, %{"doyun" => %{"hp" => 1}, "sera" => %{"hp" => 9}})
      {state, outputs} = run(state, [Event.attack("wolf", "doyun", counter: true)])
      refute Enum.any?(combat(outputs), &(&1.kind == :enraged))
      assert State.stat(state, "sera", "fury") == 0
    end
  end

  describe "fighting together" do
    test "a companion who trusts the player deeply strikes with advantage beside them" do
      {_state, outputs} =
        run(party(%{{"doyun", "user"} => %{"trust" => 45}}), [Event.attack("user", "wolf")])

      assert %{d20_rolls: [_, _], advantage: true} =
               Enum.find(combat(outputs), &(&1.character_id == "doyun"))

      {_state, outputs} = run(party(), [Event.attack("user", "wolf")])
      assert %{d20_rolls: [_]} = Enum.find(combat(outputs), &(&1.character_id == "doyun"))
    end

    test "a healer passes over someone they resent until they fall" do
      resent = %{{"sera", "doyun"} => %{"tension" => 60}}
      state = party(resent, %{"doyun" => %{"hp" => 5}})
      {_state, outputs} = run(state, [Event.attack("user", "wolf")])
      kinds = combat(outputs)
      assert Enum.any?(kinds, &match?(%{kind: :ignores, character_id: "sera", to: "doyun"}, &1))
      refute Enum.any?(kinds, &match?(%{kind: :healed, character_id: "sera", to: "doyun"}, &1))

      # Without the grudge she tends him.
      {_state, outputs} =
        run(party(%{}, %{"doyun" => %{"hp" => 5}}), [Event.attack("user", "wolf")])

      assert Enum.any?(
               combat(outputs),
               &match?(%{kind: :healed, character_id: "sera", to: "doyun"}, &1)
             )

      # Fallen, he is tended whatever she feels.
      state = party(resent, %{"doyun" => %{"hp" => 0}})
      {_state, outputs} = run(state, [Event.attack("user", "wolf")])

      assert Enum.any?(
               combat(outputs),
               &match?(%{kind: :healed, character_id: "sera", to: "doyun"}, &1)
             )
    end
  end

  test "the new moments are told in both languages" do
    state = party()

    for {kind, ko, en} <- [
          {:protected, "앞을 막아섰다", "steps in front of"},
          {:enraged, "분노", "rage"},
          {:ignores, "외면", "passes over"}
        ] do
      output = %{
        type: :combat,
        kind: kind,
        character_id: "sera",
        to: "doyun",
        subject: "sera",
        amount: 0,
        hp: 21,
        max_hp: 21
      }

      assert Combat.describe(output, state, :ko) =~ ko
      assert Combat.describe(output, state, :en) =~ en
    end
  end
end
