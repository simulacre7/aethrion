defmodule Aethrion.CombatTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Combat, Event, Explain, Journal, Runtime, State}

  defp arena do
    goblin = %Aethrion.Character{id: "goblin", name: "Goblin"}

    %{
      Runtime.demo_state()
      | characters: Map.put(Runtime.demo_state().characters, "goblin", goblin),
        stats: %{
          "user" => %{"hp" => 30, "max_hp" => 30, "attack" => 6, "defense" => 2, "speed" => 3},
          "mina" => %{"hp" => 20, "max_hp" => 20, "attack" => 3, "defense" => 1, "heal" => 8},
          "haru" => %{"hp" => 25, "max_hp" => 25, "attack" => 5, "defense" => 2},
          "yuna" => %{"hp" => 15, "max_hp" => 15, "attack" => 2, "defense" => 1},
          "goblin" => %{"hp" => 18, "max_hp" => 18, "attack" => 5, "defense" => 1, "speed" => 2}
        }
    }
  end

  defp run(state, events) do
    Enum.reduce(events, {state, [], []}, fn event, {state, outputs, steps} ->
      {:ok, step} = Runtime.step(state, event)
      {step.state, outputs ++ step.outputs, steps ++ [step]}
    end)
  end

  defp combat(outputs), do: for(%{type: :combat} = o <- outputs, do: o)
  defp hp(state, id), do: State.stat(state, id, "hp")

  test "a blow costs hp by the numbers, the target hits back once, and it replays the same" do
    {state, outputs, steps} = run(arena(), [Event.attack("user", "goblin")])

    assert [
             %{kind: hit, character_id: "user", to: "goblin", amount: dealt},
             %{character_id: "goblin", to: "user", amount: taken}
           ] =
             combat(outputs)

    assert hit in [:hit, :critical]
    assert hp(state, "goblin") == 18 - dealt
    assert hp(state, "user") == 30 - taken
    # attack 6 + roll 0..5 - defense 1, a critical half again.
    assert dealt in 5..15
    assert [%{before: 18}] = Explain.stat(steps, "goblin", "hp")

    {again, _outputs, _steps} = run(arena(), [Event.attack("user", "goblin")])
    assert again == state
  end

  test "a guard halves the next blow, then is spent" do
    {state, _outputs, _steps} = run(arena(), [Event.defend("user")])
    assert Map.has_key?(state.cooldowns, Combat.guard_key("user"))

    {state, outputs, _steps} = run(state, [Event.attack("goblin", "user", counter: true)])
    assert [%{guarded: true}] = combat(outputs)
    refute Map.has_key?(state.cooldowns, Combat.guard_key("user"))
  end

  test "a fighter at 0 hp is defeated and cannot act or be attacked; healing stops at max hp" do
    state = put_in(arena().stats["goblin"]["hp"], 1)
    {state, outputs, _steps} = run(state, [Event.attack("user", "goblin")])

    assert [%{kind: _hit}, %{kind: :defeated, character_id: "goblin"}] = combat(outputs)
    assert hp(state, "goblin") == 0

    assert {:error, %{message: "goblin is already down"}} =
             Runtime.step(state, Event.attack("user", "goblin"))

    assert {:error, %{message: "goblin is already down"}} =
             Runtime.step(state, Event.attack("goblin", "user"))

    unarmed = update_in(state.stats, &Map.delete(&1, "yuna"))

    assert {:error, %{message: "yuna cannot fight: no hp stat"}} =
             Runtime.step(unarmed, Event.attack("user", "yuna"))

    hurt = put_in(arena().stats["user"]["hp"], 25)
    {healed, outputs, _steps} = run(hurt, [Event.heal("mina", "user")])
    assert [%{kind: :healed, amount: 5}] = combat(outputs)
    assert hp(healed, "user") == 30
  end

  test "counted potions run out" do
    state = arena() |> put_in([Access.key(:stats), "user", "potions"], 1)
    state = put_in(state.stats["user"]["hp"], 5)
    {state, _outputs, _steps} = run(state, [Event.heal("user", "user", item: "potion")])
    assert State.stat(state, "user", "potions") == 0

    assert {:error, %{message: "user has no potions left"}} =
             Runtime.step(state, Event.heal("user", "user", item: "potion"))
  end

  test "fleeing works by speed; failing gives the other a free blow" do
    {_state, outputs, _steps} = run(arena(), [Event.flee("user", "goblin")])
    assert [%{kind: first} | rest] = combat(outputs)

    case first do
      :fled -> assert rest == []
      :caught -> assert [%{character_id: "goblin", to: "user"}] = rest
    end
  end

  test "being attacked, seen attacking a friend, fighting beside, and being healed change how characters feel" do
    {state, _outputs, _steps} =
      run(put_in(arena().stats["mina"]["hp"], 10), [
        Event.attack("user", "yuna", observed_by: ["haru"]),
        Event.attack("user", "goblin", observed_by: ["mina"]),
        Event.heal("user", "mina", amount: 1)
      ])

    before = arena()
    rel = &State.get_relationship(&1, &2, "user")

    assert rel.(state, "yuna").affinity < rel.(before, "yuna").affinity
    assert rel.(state, "yuna").tension > rel.(before, "yuna").tension

    assert Enum.any?(
             state.memories,
             &(&1.character_id == "yuna" and &1.data["event"] == "attack")
           )

    # Haru cares about Yuna: he trusts you less. Mina saw you fight the goblin
    # beside her, and then you healed her.
    assert rel.(state, "haru").trust < rel.(before, "haru").trust
    assert rel.(state, "mina").trust > rel.(before, "mina").trust
    assert rel.(state, "mina").affinity > rel.(before, "mina").affinity
  end

  test "companions who trust the player fight beside them; the others hold back" do
    state =
      arena()
      |> put_in([Access.key(:stats), "mina", "party"], 1)
      |> put_in([Access.key(:stats), "haru", "party"], 1)
      |> put_in([Access.key(:stats), "user", "hp"], 10)

    # Mina trusts the user (25) and heals them; Haru (trust 15) strikes too.
    {_after, outputs, _steps} = run(state, [Event.attack("user", "goblin")])
    acted = for %{character_id: who, kind: kind} <- combat(outputs), do: {who, kind}
    assert {"mina", :healed} in acted
    assert Enum.any?(acted, &match?({"haru", k} when k in [:hit, :critical, :defeated], &1))

    # After an insult, Haru no longer trusts them enough, and it shows.
    {state, _outputs, _steps} =
      run(state, [Event.message_sent("user", "haru", "Useless.", tone: :hostile)])

    {_after, outputs, _steps} = run(state, [Event.attack("user", "goblin")])

    assert {"haru", :holds_back} in for(
             %{character_id: who, kind: kind} <- combat(outputs),
             do: {who, kind}
           )
  end

  test "a player's words become a combat action" do
    state = arena()

    assert %{type: :attack, from: "user", to: "goblin"} =
             Combat.action(state, "user", "goblin", "I swing my sword!")

    assert %{type: :defend} = Combat.action(state, "user", "goblin", "방패를 들어 막는다")

    assert %{type: :heal, to: "user", item: "potion"} =
             Combat.action(state, "user", "goblin", "포션을 마신다")

    assert %{type: :flee, to: "goblin"} = Combat.action(state, "user", "goblin", "run away!")
  end

  test "the story ends the moment the fight is settled, and the fight replays from a journal" do
    {:ok, quest} = "priv/casts/quest.json" |> File.read!() |> Jason.decode!() |> State.parse()
    quest = put_in(quest.stats["wolf"]["hp"], 1)

    path =
      Path.join(System.tmp_dir!(), "aethrion-fight-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm(path) end)
    :ok = Journal.create(path, quest)

    {:ok, step} = Runtime.step(quest, Event.attack("user", "wolf", observed_by: ["ria", "kael"]))
    :ok = Journal.append(path, step.event)

    assert [%{ending: ending}] = for(%{type: :ending_reached} = o <- step.outputs, do: o)
    assert ending in ["companions", "alone"]
    assert {:ok, replayed, [_step]} = Journal.replay(path)
    assert replayed == step.state

    assert Combat.describe(hd(combat(step.outputs)), step.state, :ko) =~ "늑대왕에게"
  end

  test "the fallen are not revived, the unhurt are not healed, and nobody fights once it is decided" do
    down = put_in(arena().stats["yuna"]["hp"], 0)

    assert {:error, %{message: "yuna is already down"}} =
             Runtime.step(down, Event.heal("mina", "yuna"))

    assert {:error, %{message: "mina is not hurt"}} =
             Runtime.step(arena(), Event.heal("user", "mina"))

    fallen_healer = put_in(arena().stats["mina"]["hp"], 0)
    fallen_healer = put_in(fallen_healer.stats["user"]["hp"], 10)

    assert {:error, %{message: "mina is down and cannot heal"}} =
             Runtime.step(fallen_healer, Event.heal("mina", "user"))

    {:ok, quest} = "priv/casts/quest.json" |> File.read!() |> Jason.decode!() |> State.parse()
    {:ok, step} = Runtime.step(put_in(quest.stats["wolf"]["hp"], 1), Event.attack("user", "wolf"))
    assert Combat.over?(step.state)

    assert {:error, %{message: "the fight is over: the story has reached its ending"}} =
             Runtime.step(step.state, Event.defend("user"))
  end

  test "guarding or healing costs a turn: the enemies strike" do
    state = put_in(arena().stats["goblin"]["enemy"], 1)
    {state, outputs, _steps} = run(state, [Event.defend("user")])

    assert [%{kind: :guarded}, %{character_id: "goblin", to: "user", guarded: true}] =
             combat(outputs)

    refute Map.has_key?(state.cooldowns, Combat.guard_key("user"))

    # The companions still act on that turn, before the enemy: a healer
    # tends a player who is badly hurt.
    hurt =
      arena()
      |> put_in([Access.key(:stats), "goblin", "enemy"], 1)
      |> put_in([Access.key(:stats), "mina", "party"], 1)
      |> put_in([Access.key(:stats), "user", "hp"], 8)

    {_after, outputs, _steps} = run(hurt, [Event.defend("user")])

    assert [
             %{kind: :guarded},
             %{kind: :healed, character_id: "mina", to: "user"},
             %{character_id: "goblin"}
           ] =
             combat(outputs)
  end

  test "an ally is never a target for the party, and a cascade does not strike the fallen" do
    state =
      arena()
      |> put_in([Access.key(:stats), "haru", "party"], 1)
      |> put_in([Access.key(:stats), "mina", "party"], 1)

    {_after, outputs, _steps} = run(state, [Event.attack("user", "mina")])
    refute Enum.any?(combat(outputs), &(&1.character_id == "haru"))

    weak = put_in(state.stats["goblin"]["hp"], 1)
    {_after, outputs, _steps} = run(weak, [Event.attack("user", "goblin")])
    assert [%{kind: _hit}, %{kind: :defeated}] = combat(outputs)
  end

  test "someone who does not trust the player says so once, not every round" do
    state =
      arena()
      |> put_in([Access.key(:stats), "haru", "party"], 1)
      |> put_in([Access.key(:stats), "goblin", "hp"], 200)
      |> put_in([Access.key(:stats), "goblin", "max_hp"], 200)

    {state, _outputs, _steps} =
      run(state, [Event.message_sent("user", "haru", "Useless.", tone: :hostile)])

    {_after, outputs, _steps} =
      run(state, [Event.attack("user", "goblin"), Event.attack("user", "goblin")])

    assert [_once] = for(%{kind: :holds_back} = o <- combat(outputs), do: o)
  end

  test "a forged counter flag from a client is ignored" do
    {:ok, event} =
      Event.from_data(%{
        "type" => "attack",
        "from" => "user",
        "to" => "goblin",
        "counter" => true
      })

    refute Map.get(event, :counter, false)
  end

  test "words are read as verbs, and who is meant comes from the cast" do
    state =
      arena()
      |> put_in([Access.key(:stats), "goblin", "enemy"], 1)
      |> put_in([Access.key(:stats), "mina", "party"], 1)

    assert Combat.foe(state) == "goblin"
    assert Combat.party(state) == ["mina"]

    assert %{type: :attack, to: "goblin", observed_by: ["mina"]} =
             Combat.action(state, "user", nil, "방패로 후려친다")

    assert %{type: :attack} = Combat.action(state, "user", nil, "도망치지 않고 벤다")
    assert %{type: :flee, to: "goblin"} = Combat.action(state, "user", nil, "뒤로 후퇴한다")
    assert %{type: :flee} = Combat.action(state, "user", nil, "등을 돌려 도망친다!")
    assert %{type: :attack} = Combat.action(state, "user", nil, "몽둥이로 머리를 친다")
    assert %{type: :heal, to: "mina"} = Combat.action(state, "user", "mina", "붕대를 감아 준다")
    assert %{type: :heal, to: "user"} = Combat.action(state, "user", "goblin", "potion, now")
    assert %{type: :defend} = Combat.action(state, "user", nil, "숨을 고른다")

    # The words name the target, whoever the player was talking to; a
    # potion they drink is their own.
    assert %{type: :attack, to: "goblin"} = Combat.action(state, "user", "mina", "Goblin을 벤다")
    assert %{type: :heal, to: "user"} = Combat.action(state, "user", "mina", "포션을 마신다")

    assert %{type: :attack, to: "goblin"} =
             Combat.action(state, "user", nil, "Mina를 지키며 Goblin을 벤다")

    assert %{type: :heal, to: "mina"} =
             Combat.action(state, "user", nil, "Goblin에게 맞은 Mina를 치료한다")
  end

  test "told in Korean, with the right particles and tense" do
    state = arena()
    ko = &Combat.describe(&1, state, :ko)

    assert ko.(%{
             kind: :healed,
             character_id: "user",
             to: "user",
             subject: "user",
             amount: 5,
             hp: 20,
             max_hp: 30
           }) ==
             "너는 체력을 5 회복했다. (너 20/30)"

    assert ko.(%{
             kind: :healed,
             character_id: "mina",
             to: "user",
             subject: "user",
             amount: 8,
             hp: 28,
             max_hp: 30
           }) ==
             "Mina가 네 상처를 8만큼 치료했다. (너 28/30)"

    assert ko.(%{
             kind: :hit,
             character_id: "goblin",
             to: "user",
             subject: "user",
             amount: 3,
             hp: 27,
             max_hp: 30,
             guarded: true
           }) =~
             "3의 피해를 입혔다 (방어로 절반)."

    assert ko.(%{kind: :holds_back, character_id: "haru", to: "user"}) =~ "지켜보기만 했다"
  end
end
