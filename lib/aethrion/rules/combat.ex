defmodule Aethrion.Rules.Combat do
  @moduledoc """
  Fights, decided by the numbers (`Aethrion.Combat`). Fighters are actors
  with an `"hp"` stat; `"attack"`, `"defense"`, `"max_hp"`, `"speed"`, and
  `"heal"` are read when present.

  - **attack**: damage is `attack + roll - defense`, at least 1, where the
    roll (0..5) comes from who acts on whom, both fighters' hp, and how
    many turns the actor has taken (their `"turns"` stat), so a fight
    replays exactly and talking in between does not change the dice. A roll of 5 is a critical hit (half again as
    much). A raised guard halves the blow and is spent. At 0 hp a fighter is
    defeated. A character still standing hits back once (counterattacks and
    a companion's assisting blows are not answered).
  - **defend**: the next blow taken is halved, by the defender or by the
    companion they shield (`to`); the enemies (actors with an `"enemy"`
    stat) take their turn, each going for the weakest of the player's side
    (the player or a companion, by share of hp left).
  - **heal**: restores `amount` (or the healer's `"heal"` stat, or 10), up
    to `"max_hp"`. The healer must be standing and the target hurt and
    standing: the fallen are not revived. A potion uses one of the healer's
    `"potions"` if they have that stat. The enemies take their turn.
  - **flee**: gets away when `speed + roll >= the other's speed + 3` (adding
    1 to the runner's `"fled"` stat, which a story can end on); otherwise
    the other gets a free blow.
  - **party**: when a player attacks, characters with a `"party"` stat
    move before the enemy answers, if they trust the player (trust >=
    `party_trust`): healers tend the most hurt of the player and the
    companions below 60% hp, the others strike
    the same target (never an ally). They act on guard and heal turns too,
    but trust grows only from fighting side by side. Turning on someone who
    is not an enemy still gives the enemies their turn. Those who do not trust the player hold
    back (`:holds_back`, said once until they join in again).
  - Once the story's ending is decided, no one fights; a blow queued in a
    cascade is dropped if its fighter or target has fallen.

  How the fighters feel about each other changes the fight too:

  - **protecting**: when an enemy goes for someone on the player's side
    who is below `protect_below`% of their hp, a companion who cares about
    them (affinity >= `protect_affinity`) and still has `protect_above`% of
    their own steps in and takes the blow (`:protected`), once a round (a
    round ends with the player's next move). The one saved grows fonder of
    them and trusts them more.
  - **fury**: when someone on the player's side falls, the companions who
    cared about them (affinity >= `fury_affinity`) are enraged
    (`:enraged`, a `"fury"` stat): `fury_bonus` on their attacks for the
    rest of the story.
  - **fighting together**: a companion joining a blow beside a player they
    trust deeply (trust >= `team_trust`) attacks with advantage (two d20s,
    the higher counts; a guard's disadvantage cancels it), as the SRD's
    Help action gives.
  - **grudges**: a healer passes over someone they resent (tension >=
    `resent_tension`) until that one falls (`:ignores`, said once), and
    among those equally hurt tends the one they care about most.

  Fighting is social too. A character who is attacked loses affinity and
  trust toward the attacker, gains tension, and remembers it; witnesses who
  care about them (affinity >= 30) trust the attacker less, and the others
  (not companions, who earn it by joining in), unless they hold something
  against the attacker, trust someone who fights beside them a little more.
  A character healed by someone grows fonder of them and trusts them more.
  """

  use Aethrion.Rule,
    id: :combat,
    description:
      "Attacks, guards, heals, and flight change hp by the numbers; fighters hit back; being attacked or healed changes how characters feel about each other.",
    params: [
      party_trust: 10,
      flee_margin: 3,
      attacked_affinity: -20,
      attacked_trust: -15,
      attacked_tension: 20,
      witness_care: 30,
      witness_trust: -6,
      fought_beside_trust: 2,
      healed_affinity: 5,
      healed_trust: 4,
      protect_affinity: 50,
      protect_below: 50,
      protect_above: 50,
      protected_affinity: 5,
      protected_trust: 5,
      fury_affinity: 50,
      fury_bonus: 2,
      team_trust: 40,
      resent_tension: 50,
      default_heal: 10,
      potion_dice: 0,
      potion_die: 4,
      potion_bonus: 2
    ]

  alias Aethrion.{Combat, Event, Memory, State, Transition}

  @impl true
  @actions [:attack, :defend, :heal, :flee]

  # Checked again when the action happens, not only when it was queued: a
  # blow in a cascade may land after its target has fallen.
  def apply(%Transition{event: %{type: type} = event} = transition) when type in @actions do
    case problem(transition.state, event) do
      nil ->
        transition
        |> new_round(event)
        |> Transition.adjust_stat(event.from, "turns", 1, log: false)
        |> act(event)

      reason ->
        Transition.note(transition, reason)
    end
  end

  def apply(transition), do: transition

  defp problem(state, event) do
    down =
      Enum.find(
        actors(event),
        &(State.stat?(state, &1, "hp") and State.stat(state, &1, "hp") <= 0)
      )

    cond do
      Combat.over?(state) -> "The fight is over"
      down -> "#{down} is down"
      true -> nil
    end
  end

  # A round ends with the player's own move: companions may protect again.
  defp new_round(%Transition{state: state} = transition, event) do
    if player?(state, event.from) and not Map.get(event, :counter, false) do
      state.cooldowns
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "combat:protect:"))
      |> Enum.reduce(transition, &Transition.clear_cooldown(&2, &1))
    else
      transition
    end
  end

  defp actors(%{type: :heal, from: from}), do: [from]
  defp actors(%{type: :defend, from: from} = event), do: [from | List.wrap(Map.get(event, :to))]
  defp actors(%{from: from, to: to}), do: [from, to]

  defp act(transition, %{type: :attack} = event) do
    {transition, event} = protect(transition, event)
    state = transition.state
    guard = Combat.guard_key(event.to)
    guarded? = Map.has_key?(state.cooldowns, guard)

    {kind, damage, detail} =
      if d20?(state, event),
        do: d20_attack(state, event, guarded?, fury(transition, event.from)),
        else: classic_attack(state, event, guarded?, fury(transition, event.from))

    transition =
      transition
      |> then(&if(guarded?, do: Transition.clear_cooldown(&1, guard), else: &1))
      |> Transition.adjust_stat(event.to, "hp", -damage, min: 0, log: false)

    hp = State.stat(transition.state, event.to, "hp")

    transition
    |> combat_output(event, event.to, kind, damage, guarded?: guarded?, detail: detail)
    |> attacked(event)
    |> witnessed(event)
    |> then(fn transition ->
      if hp == 0,
        do:
          transition
          |> combat_output(
            %{event | from: event.to, to: event.from},
            event.to,
            :defeated,
            0
          )
          |> enraged(event),
        else: transition
    end)
    # The companions move before the enemy answers.
    |> party(event, hp)
    |> then(&if(hp > 0, do: counter(&1, event), else: &1))
    |> others_strike(event)
  end

  defp act(transition, %{type: :defend} = event) do
    shielded = Map.get(event, :to) || event.from

    transition
    |> Transition.put_cooldown(Combat.guard_key(shielded))
    |> combat_output(Map.put(event, :to, Map.get(event, :to)), shielded, :guarded, 0)
    |> enemies_turn(event.from, event)
  end

  # A companion asked to heal ("리아, 치료해 줘") does so if they trust the
  # one asking, and either way it was the asker's turn.
  defp act(transition, %{type: :heal, asked_by: asker} = event) do
    trust = State.get_relationship(transition.state, event.from, asker).trust

    if trust < Transition.param(transition, :party_trust) do
      transition
      |> combat_output(%{event | to: asker}, event.from, :holds_back, 0)
      |> enemies_turn(asker, event)
    else
      transition
      |> heal(event)
      |> enemies_turn(asker, event)
    end
  end

  defp act(transition, %{type: :heal} = event) do
    transition
    |> heal(event)
    |> enemies_turn(event.from, event)
  end

  defp act(transition, %{type: :flee} = event) do
    state = transition.state
    roll = Combat.roll(event, state)

    if State.stat(state, event.from, "speed") + roll >=
         State.stat(state, event.to, "speed") + Transition.param(transition, :flee_margin) do
      transition
      |> Transition.adjust_stat(event.from, "fled", 1, log: false)
      |> combat_output(event, event.from, :fled, 0)
    else
      transition
      |> combat_output(event, event.from, :caught, 0)
      |> Transition.enqueue(Event.attack(event.to, event.from, counter: true, at: event.at))
    end
  end

  # A player's blow is answered by its target; the other enemies standing
  # take their turn as well (all of them, if the player turned on someone
  # who is not an enemy).
  defp others_strike(%Transition{state: state} = transition, event) do
    if player?(state, event.from) and not Map.get(event, :counter, false),
      do: enemies_strike(transition, event.from, event, except: event.to),
      else: transition
  end

  defp classic_attack(state, event, guarded?, fury) do
    roll = Combat.roll(event, state)

    base =
      max(
        State.stat(state, event.from, "attack") + fury + roll -
          State.stat(state, event.to, "defense"),
        1
      )

    critical? = roll == 5
    damage = if critical?, do: div(base * 3, 2), else: base
    damage = if guarded?, do: max(div(damage, 2), 1), else: damage
    {if(critical?, do: :critical, else: :hit), damage, %{}}
  end

  # The d20 rules of the 5th edition SRD: an attacker with an
  # "attack_bonus" against a target with an "ac".
  defp d20?(state, event),
    do: State.stat?(state, event.from, "attack_bonus") and State.stat?(state, event.to, "ac")

  # d20 + attack bonus against armor class; a natural 20 always hits and
  # rolls the damage dice twice, a natural 1 always misses. A target who
  # took the Dodge action (a guard) is attacked with disadvantage: two d20s,
  # the lower counts; a companion fighting beside a player they trust has
  # advantage, the higher counts; both at once cancel out.
  defp d20_attack(state, event, guarded?, fury) do
    {rolls, d20, advantage?} = d20_rolls(state, event, guarded?)
    bonus = State.stat(state, event.from, "attack_bonus") + fury
    ac = State.stat(state, event.to, "ac")
    hit? = d20 == 20 or (d20 != 1 and d20 + bonus >= ac)
    critical? = d20 == 20
    {count, die, plus} = damage_dice(state, event.from)
    count = if critical?, do: count * 2, else: count
    dice = for i <- 1..count, do: Combat.die(event, state, die, 10 + i)
    damage = if hit?, do: max(Enum.sum(dice) + plus, 1), else: 0

    detail = %{
      d20: d20,
      d20_rolls: rolls,
      attack_bonus: bonus,
      ac: ac,
      dice: Combat.dice_label(count, die, plus),
      dice_rolls: if(hit?, do: dice, else: [])
    }

    detail = if advantage?, do: Map.put(detail, :advantage, true), else: detail

    kind =
      cond do
        not hit? -> :missed
        critical? -> :critical
        true -> :hit
      end

    {kind, damage, detail}
  end

  defp d20_rolls(state, event, guarded?) do
    advantage? = Map.get(event, :advantage, false) and not guarded?
    disadvantage? = guarded? and not Map.get(event, :advantage, false)

    rolls =
      if advantage? or disadvantage?,
        do: [Combat.die(event, state, 20, 0), Combat.die(event, state, 20, 1)],
        else: [Combat.die(event, state, 20, 0)]

    {rolls, if(advantage?, do: Enum.max(rolls), else: Enum.min(rolls)), advantage?}
  end

  # Bounded here too, whatever the state holds (`State.dice_limits/0`).
  defp damage_dice(state, id),
    do:
      {stat_or(state, id, "damage_dice", 1) |> max(1) |> min(20),
       stat_or(state, id, "damage_die", 6) |> max(2) |> min(100),
       State.stat(state, id, "damage_bonus")}

  # While a player guards or heals, the companions still act (a healer
  # tends them, the others strike the first enemy standing), then the
  # enemies (characters with an "enemy" stat) strike: guarding costs a turn.
  defp heal(%Transition{state: state} = transition, event) do
    {amount, detail} = heal_amount(transition, event)

    max_hp = stat_or(state, event.to, "max_hp", State.stat(state, event.to, "hp") + amount)
    before = State.stat(state, event.to, "hp")
    healed = max(min(before + amount, max_hp) - before, 0)

    transition
    |> Transition.adjust_stat(event.to, "hp", healed, log: false)
    |> use_potion(event)
    |> combat_output(event, event.to, :healed, healed, detail: detail)
    |> grateful(event, healed)
  end

  # How much: the event's amount; else a healer's dice ("heal_dice" d
  # "heal_die" + "heal_bonus", like a Cure Wounds); a potion's dice
  # (`potion_dice` d `potion_die` + `potion_bonus`: 2d4+2 is the SRD's
  # Potion of Healing); else the healer's "heal" stat or `default_heal`.
  defp heal_amount(%Transition{state: state} = transition, event) do
    param = &Transition.param(transition, &1)

    cond do
      event.amount != nil ->
        {event.amount, %{}}

      State.stat(state, event.from, "heal_dice") > 0 ->
        rolled(
          event,
          state,
          State.stat(state, event.from, "heal_dice"),
          stat_or(state, event.from, "heal_die", 8),
          State.stat(state, event.from, "heal_bonus")
        )

      event.item == "potion" and param.(:potion_dice) > 0 ->
        rolled(event, state, param.(:potion_dice), param.(:potion_die), param.(:potion_bonus))

      true ->
        {stat_or(state, event.from, "heal", param.(:default_heal)), %{}}
    end
  end

  defp rolled(event, state, count, die, plus) do
    {count, die} = {count |> max(1) |> min(20), die |> max(2) |> min(100)}
    dice = for i <- 1..count, do: Combat.die(event, state, die, 10 + i)
    {Enum.sum(dice) + plus, %{dice: Combat.dice_label(count, die, plus), dice_rolls: dice}}
  end

  defp enemies_turn(%Transition{state: state} = transition, player, event) do
    if player?(state, player) do
      transition
      |> companions_turn(player, event)
      |> enemies_strike(player, event)
    else
      transition
    end
  end

  defp companions_turn(%Transition{state: state} = transition, player, event) do
    case Combat.foe(state) do
      nil ->
        transition

      foe ->
        party(
          transition,
          %{
            id: event.id,
            type: :attack,
            from: player,
            to: foe,
            at: event.at,
            guarding: true,
            # A companion who already acted this turn (asked to heal) rests.
            acted: if(Map.has_key?(event, :asked_by), do: event.from)
          },
          State.stat(state, foe, "hp")
        )
    end
  end

  defp enemies_strike(%Transition{state: state} = transition, player, event, opts \\ []) do
    if State.stat(state, player, "hp") > 0 do
      state
      |> enemies()
      |> Enum.with_index()
      |> Enum.reject(fn {enemy, _i} -> enemy == Keyword.get(opts, :except) end)
      |> Enum.reduce(transition, fn {enemy, i}, transition ->
        Transition.enqueue(
          transition,
          Event.attack(enemy, target(state, enemy, player, i), counter: true, at: event.at)
        )
      end)
    else
      transition
    end
  end

  # Enemies go for someone badly hurt (below 40% of their hp) to finish
  # them, and otherwise take turns between the player and the companions
  # still standing, by the enemy's own turn count.
  defp target(state, enemy, player, index) do
    side = [player | for(id <- Combat.party(state), State.stat(state, id, "hp") > 0, do: id)]
    weakest = Enum.min_by(side, &share(state, &1))

    if share(state, weakest) < 40,
      do: weakest,
      else: Enum.at(side, rem(State.stat(state, enemy, "turns") + index, length(side)))
  end

  defp share(state, id) do
    hp = State.stat(state, id, "hp")
    hp * 100 / max(stat_or(state, id, "max_hp", hp), 1)
  end

  # Enemies are actors with an "enemy" stat, characters or not, still standing.
  defp enemies(state) do
    for id <- Enum.sort(Map.keys(state.stats)),
        State.stat(state, id, "enemy") > 0 and State.stat(state, id, "hp") > 0,
        do: id
  end

  # Players are people: "user", or someone the world names in people.
  defp player?(state, id),
    do: not State.character?(state, id) and (id == "user" or Map.has_key?(state.people, id))

  defp use_potion(%Transition{state: state} = transition, %{item: item, from: from})
       when is_binary(item) do
    count = item <> "s"

    if State.stat?(state, from, count),
      do: Transition.adjust_stat(transition, from, count, -1, min: 0),
      else: transition
  end

  defp use_potion(transition, _event), do: transition

  defp stat_or(state, id, stat, default),
    do: if(State.stat?(state, id, stat), do: State.stat(state, id, stat), else: default)

  # When a person (a player) attacks, the party members who trust them join
  # in: a healer tends them when they are hurt, the others strike the same
  # target. Those who do not trust them hold back, and it shows.
  defp party(%Transition{state: state} = transition, event, target_hp) do
    if player?(state, event.from) and not Map.get(event, :counter, false) and
         State.stat(state, event.to, "party") == 0 do
      state
      |> State.sorted_characters()
      |> Enum.filter(&party_member?(state, &1.id, event))
      |> Enum.reduce(transition, &join(&2, &1.id, event, target_hp))
    else
      transition
    end
  end

  defp party_member?(state, id, event),
    do:
      State.stat(state, id, "party") > 0 and id not in [event.from, event.to] and
        id != Map.get(event, :acted) and
        State.stat(state, id, "hp") > 0

  # A healer tends a hurt leader and otherwise strikes too. Someone holding
  # back says so once, until they fight beside the player again.
  defp join(%Transition{state: state} = transition, id, event, target_hp) do
    trust = State.get_relationship(state, id, event.from).trust
    resent = Transition.param(transition, :resent_tension)
    patient = most_hurt(state, event.from, id, resent)
    held = Combat.held_key(id)
    transition = passed_over(transition, id, event, resent, patient)
    state = transition.state

    cond do
      trust < Transition.param(transition, :party_trust) and Map.has_key?(state.cooldowns, held) ->
        transition

      trust < Transition.param(transition, :party_trust) ->
        transition
        |> Transition.put_cooldown(held)
        |> combat_output(%{event | from: id, to: event.from}, id, :holds_back, 0)

      Combat.healer?(state, id) and patient != nil and
          (target_hp > 0 or Combat.foe(state) != nil) ->
        transition
        |> Transition.clear_cooldown(held)
        |> Transition.enqueue(Event.heal(id, patient, at: event.at))
        |> fought_beside(id, event)

      target_hp > 0 ->
        transition
        |> Transition.clear_cooldown(held)
        |> Transition.enqueue(
          event.to
          |> then(&Event.attack(id, &1, at: event.at))
          |> Map.put(:assist, true)
          |> Map.put(:advantage, trust >= Transition.param(transition, :team_trust))
        )
        |> fought_beside(id, event)

      true ->
        transition
    end
  end

  # Who a healer tends: the most hurt of the player and the companions,
  # below 60% of their hp, someone knocked out first; not someone the
  # healer resents, unless they are down; among equals, the dearest.
  defp most_hurt(state, leader, healer, resent \\ nil) do
    [leader | Combat.party(state)]
    |> Enum.filter(&(share(state, &1) < 60))
    |> Enum.reject(fn id ->
      resent != nil and State.stat(state, id, "hp") > 0 and
        State.get_relationship(state, healer, id).tension >= resent
    end)
    |> Enum.min_by(
      &{share(state, &1), -State.get_relationship(state, healer, &1).affinity},
      fn -> nil end
    )
  end

  # A healer who would have tended someone they resent says so, once.
  defp passed_over(%Transition{state: state} = transition, id, event, resent, patient) do
    with true <- Combat.healer?(state, id),
         wanted when wanted not in [nil, patient] <- most_hurt(state, event.from, id),
         key = "combat:ignored:#{id}:#{wanted}",
         false <- Map.has_key?(state.cooldowns, key),
         true <- State.get_relationship(state, id, wanted).tension >= resent do
      transition
      |> Transition.put_cooldown(key)
      |> combat_output(%{event | from: id, to: wanted}, wanted, :ignores, 0)
    else
      _other -> transition
    end
  end

  # Someone on the player's side in danger, and a companion who cares about
  # them and can take it: the blow lands on the companion.
  defp protect(%Transition{state: state} = transition, %{to: to} = event) do
    param = &Transition.param(transition, &1)

    protector =
      if State.stat(state, event.from, "enemy") > 0 and on_side?(state, to) and
           not Map.has_key?(event, :protected) and State.stat?(state, to, "hp") and
           share(state, to) < param.(:protect_below) do
        state
        |> State.sorted_characters()
        |> Enum.map(& &1.id)
        |> Enum.filter(fn id ->
          State.stat(state, id, "party") > 0 and id not in [to, event.from] and
            State.stat(state, id, "hp") > 0 and share(state, id) >= param.(:protect_above) and
            State.get_relationship(state, id, to).affinity >= param.(:protect_affinity) and
            not Map.has_key?(state.cooldowns, "combat:protect:#{id}")
        end)
        |> Enum.max_by(&State.get_relationship(state, &1, to).affinity, fn -> nil end)
      end

    if protector do
      transition =
        transition
        |> Transition.put_cooldown("combat:protect:#{protector}")
        |> combat_output(%{event | from: protector}, protector, :protected, 0)
        |> saved(to, protector, event)

      {transition, event |> Map.put(:to, protector) |> Map.put(:protected, to)}
    else
      {transition, event}
    end
  end

  defp on_side?(state, id), do: player?(state, id) or State.stat(state, id, "party") > 0

  defp saved(%Transition{state: state} = transition, saved, protector, event) do
    if State.character?(state, saved) or player?(state, saved) do
      transition
      |> Transition.adjust_relationship(
        saved,
        protector,
        :affinity,
        Transition.param(transition, :protected_affinity)
      )
      |> Transition.adjust_relationship(
        saved,
        protector,
        :trust,
        Transition.param(transition, :protected_trust)
      )
      |> Transition.remember(
        Memory.new(
          id: "memory:#{protector}:protected:#{event.id}:#{saved}",
          character_id: protector,
          content: "#{protector} took a blow meant for #{saved}.",
          importance: 65,
          created_at: event.at,
          related_characters: [saved],
          kind: :experienced,
          topic: "protect:#{event.id}",
          data: %{"event" => "protect", "from" => protector, "to" => saved}
        )
      )
    else
      transition
    end
  end

  # Those who cared about someone on the player's side who just fell.
  defp enraged(%Transition{state: state} = transition, %{to: fallen} = event) do
    if on_side?(state, fallen) do
      state
      |> State.sorted_characters()
      |> Enum.map(& &1.id)
      |> Enum.filter(fn id ->
        State.stat(state, id, "party") > 0 and id != fallen and State.stat(state, id, "hp") > 0 and
          State.stat(state, id, "fury") == 0 and
          State.get_relationship(state, id, fallen).affinity >=
            Transition.param(transition, :fury_affinity)
      end)
      |> Enum.reduce(transition, fn id, transition ->
        transition
        |> Transition.adjust_stat(id, "fury", 1, log: false)
        |> combat_output(%{event | from: id, to: fallen}, id, :enraged, 0)
      end)
    else
      transition
    end
  end

  defp fury(transition, id) do
    if State.stat(transition.state, id, "fury") > 0,
      do: Transition.param(transition, :fury_bonus),
      else: 0
  end

  # Trust is earned fighting side by side; behind a raised shield, half.
  defp fought_beside(transition, id, %{guarding: true, from: leader}) do
    Transition.adjust_relationship(
      transition,
      id,
      leader,
      :trust,
      div(Transition.param(transition, :fought_beside_trust), 2)
    )
  end

  defp fought_beside(transition, id, %{from: leader}), do: fought_beside(transition, id, leader)

  defp fought_beside(transition, id, leader),
    do:
      Transition.adjust_relationship(
        transition,
        id,
        leader,
        :trust,
        Transition.param(transition, :fought_beside_trust)
      )

  # A character still standing answers a blow, once.
  defp counter(%Transition{state: state} = transition, event) do
    if (State.character?(state, event.to) or State.stat(state, event.to, "enemy") > 0) and
         not Map.get(event, :counter, false) and
         not Map.get(event, :assist, false) and State.stat(state, event.from, "hp") > 0 do
      Transition.enqueue(
        transition,
        Event.attack(event.to, event.from, counter: true, at: event.at)
      )
    else
      transition
    end
  end

  # Being attacked hurts how the character feels about the attacker, and is
  # remembered. A counterattack is self-defense, not an injury to resent.
  defp attacked(%Transition{state: state} = transition, event) do
    if State.character?(state, event.to) and not Map.get(event, :counter, false) do
      transition
      |> Transition.adjust_relationship(
        event.to,
        event.from,
        :affinity,
        Transition.param(transition, :attacked_affinity)
      )
      |> Transition.adjust_relationship(
        event.to,
        event.from,
        :trust,
        Transition.param(transition, :attacked_trust)
      )
      |> Transition.adjust_relationship(
        event.to,
        event.from,
        :tension,
        Transition.param(transition, :attacked_tension)
      )
      |> Transition.remember(memory(event, event.to, :experienced, 70))
    else
      transition
    end
  end

  defp witnessed(transition, event) do
    event
    |> Map.get(:observed_by, [])
    |> Enum.reject(&(&1 in [event.from, event.to]))
    |> Enum.filter(&State.character?(transition.state, &1))
    |> Enum.reduce(transition, fn witness, transition ->
      care = Transition.param(transition, :witness_care)
      state = transition.state

      cond do
        State.get_relationship(state, witness, event.to).affinity >= care ->
          transition
          |> Transition.adjust_relationship(
            witness,
            event.from,
            :trust,
            Transition.param(transition, :witness_trust)
          )
          |> Transition.remember(memory(event, witness, :observed, 55))

        # Not on the target's side, and not against the attacker: they saw
        # someone fight beside them. (Companions earn it by joining in, not
        # by watching: see join/4.)
        State.stat(state, witness, "party") == 0 and
            State.get_relationship(state, witness, event.from).affinity >= 0 ->
          Transition.adjust_relationship(
            transition,
            witness,
            event.from,
            :trust,
            Transition.param(transition, :fought_beside_trust)
          )

        true ->
          transition
      end
    end)
  end

  defp grateful(%Transition{state: state} = transition, event, healed) do
    if State.character?(state, event.to) and event.from != event.to and healed > 0 do
      transition
      |> Transition.adjust_relationship(
        event.to,
        event.from,
        :affinity,
        Transition.param(transition, :healed_affinity)
      )
      |> Transition.adjust_relationship(
        event.to,
        event.from,
        :trust,
        Transition.param(transition, :healed_trust)
      )
      |> Transition.remember(
        Memory.new(
          id: "memory:#{event.to}:healed:#{event.id}",
          character_id: event.to,
          content: "#{event.from} healed #{event.to}.",
          importance: 55,
          created_at: event.at,
          related_characters: [event.from],
          kind: :experienced,
          topic: "heal:#{event.id}",
          data: %{"event" => "heal", "from" => event.from, "to" => event.to}
        )
      )
    else
      transition
    end
  end

  defp memory(event, holder, kind, importance) do
    Memory.new(
      id: "memory:#{holder}:attack:#{event.id}",
      character_id: holder,
      content: "#{event.from} attacked #{event.to}.",
      importance: importance,
      created_at: event.at,
      related_characters: Enum.reject([event.from, event.to], &(&1 == holder)),
      kind: kind,
      topic: "attack:#{event.id}",
      data: %{"event" => "attack", "from" => event.from, "to" => event.to}
    )
  end

  # `subject` is whose hp the output reports: the one hit, healed, or down.
  defp combat_output(transition, event, subject, kind, amount, opts \\ []) do
    output =
      %{
        type: :combat,
        kind: kind,
        character_id: event.from,
        to: Map.get(event, :to),
        subject: subject,
        amount: amount,
        hp: State.stat(transition.state, subject, "hp"),
        max_hp: stat_or(transition.state, subject, "max_hp", nil),
        skill: Map.get(event, :skill) || Map.get(event, :item),
        guarded: Keyword.get(opts, :guarded?, false)
      }
      |> Map.merge(Keyword.get(opts, :detail, %{}))

    output = Map.put(output, :text, Combat.describe(output, transition.state, :en))

    transition
    |> Transition.emit(output)
    |> Transition.log("[Output] #{output.text}")
  end
end
