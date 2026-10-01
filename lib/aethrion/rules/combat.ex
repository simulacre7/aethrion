defmodule Aethrion.Rules.Combat do
  @moduledoc """
  Fights, decided by the numbers (`Aethrion.Combat`). Fighters are actors
  with an `"hp"` stat; `"attack"`, `"defense"`, `"max_hp"`, `"speed"`, and
  `"heal"` are read when present.

  - **attack**: damage is `attack + roll - defense`, at least 1, where the
    roll (0..5) comes from who acts on whom and both fighters' hp, so a
    fight replays exactly. A roll of 5 is a critical hit (half again as
    much). A raised guard halves the blow and is spent. At 0 hp a fighter is
    defeated. A character still standing hits back once (counterattacks and
    a companion's assisting blows are not answered).
  - **defend**: the next blow taken is halved; the enemies (characters with
    an `"enemy"` stat) take their turn.
  - **heal**: restores `amount` (or the healer's `"heal"` stat, or 10), up
    to `"max_hp"`. The healer must be standing and the target hurt and
    standing: the fallen are not revived. A potion uses one of the healer's
    `"potions"` if they have that stat. The enemies take their turn.
  - **flee**: gets away when `speed + roll >= the other's speed + 3` (adding
    1 to the runner's `"fled"` stat, which a story can end on); otherwise
    the other gets a free blow.
  - **party**: when a player attacks, characters with a `"party"` stat
    move before the enemy answers, if they trust the player (trust >=
    `party_trust`): healers tend a player below 60% hp, the others strike
    the same target (never an ally). Those who do not trust the player hold
    back (`:holds_back`, said once until they join in again).
  - Once the story's ending is decided, no one fights; a blow queued in a
    cascade is dropped if its fighter or target has fallen.

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
      attacked_affinity: -20,
      attacked_trust: -15,
      attacked_tension: 20,
      witness_care: 30,
      witness_trust: -6,
      fought_beside_trust: 2,
      healed_affinity: 5,
      healed_trust: 4,
      default_heal: 10
    ]

  alias Aethrion.{Combat, Event, Memory, State, Transition}

  @impl true
  @actions [:attack, :defend, :heal, :flee]

  # Checked again when the action happens, not only when it was queued: a
  # blow in a cascade may land after its target has fallen.
  def apply(%Transition{event: %{type: type} = event} = transition) when type in @actions do
    case problem(transition.state, event) do
      nil -> act(transition, event)
      reason -> Transition.note(transition, reason)
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

  defp actors(%{type: :defend, from: from}), do: [from]
  defp actors(%{from: from, to: to}), do: [from, to]

  defp act(transition, %{type: :attack} = event) do
    state = transition.state
    roll = Combat.roll(event, state)
    guard = Combat.guard_key(event.to)
    guarded? = Map.has_key?(state.cooldowns, guard)

    base =
      max(
        State.stat(state, event.from, "attack") + roll - State.stat(state, event.to, "defense"),
        1
      )

    critical? = roll == 5
    damage = if critical?, do: div(base * 3, 2), else: base
    damage = if guarded?, do: max(div(damage, 2), 1), else: damage

    transition =
      transition
      |> then(&if(guarded?, do: Transition.clear_cooldown(&1, guard), else: &1))
      |> Transition.adjust_stat(event.to, "hp", -damage, min: 0, log: false)

    hp = State.stat(transition.state, event.to, "hp")

    transition
    |> combat_output(event, event.to, if(critical?, do: :critical, else: :hit), damage,
      guarded?: guarded?
    )
    |> attacked(event)
    |> witnessed(event)
    |> then(fn transition ->
      if hp == 0,
        do:
          combat_output(
            transition,
            %{event | from: event.to, to: event.from},
            event.to,
            :defeated,
            0
          ),
        else: transition
    end)
    # The companions move before the enemy answers.
    |> party(event, hp)
    |> then(&if(hp > 0, do: counter(&1, event), else: &1))
  end

  defp act(transition, %{type: :defend} = event) do
    transition
    |> Transition.put_cooldown(Combat.guard_key(event.from))
    |> combat_output(Map.put(event, :to, nil), event.from, :guarded, 0)
    |> enemies_turn(event.from, event)
  end

  defp act(transition, %{type: :heal} = event) do
    state = transition.state

    amount =
      event.amount ||
        stat_or(state, event.from, "heal", Transition.param(transition, :default_heal))

    max_hp = stat_or(state, event.to, "max_hp", State.stat(state, event.to, "hp") + amount)
    before = State.stat(state, event.to, "hp")
    healed = max(min(before + amount, max_hp) - before, 0)

    transition
    |> Transition.adjust_stat(event.to, "hp", healed, log: false)
    |> use_potion(event)
    |> combat_output(event, event.to, :healed, healed)
    |> grateful(event, healed)
    |> enemies_turn(event.from, event)
  end

  defp act(transition, %{type: :flee} = event) do
    state = transition.state
    roll = Combat.roll(event, state)

    if State.stat(state, event.from, "speed") + roll >= State.stat(state, event.to, "speed") + 3 do
      transition
      |> Transition.adjust_stat(event.from, "fled", 1, log: false)
      |> combat_output(event, event.from, :fled, 0)
    else
      transition
      |> combat_output(event, event.from, :caught, 0)
      |> Transition.enqueue(Event.attack(event.to, event.from, counter: true, at: event.at))
    end
  end

  # While a player guards or heals, the companions still act (a healer
  # tends them, the others strike the first enemy standing), then the
  # enemies (characters with an "enemy" stat) strike: guarding costs a turn.
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
          %{id: event.id, type: :attack, from: player, to: foe, at: event.at},
          State.stat(state, foe, "hp")
        )
    end
  end

  defp enemies_strike(%Transition{state: state} = transition, player, event) do
    if State.stat(state, player, "hp") > 0 do
      state
      |> State.sorted_characters()
      |> Enum.filter(
        &(State.stat(state, &1.id, "enemy") > 0 and State.stat(state, &1.id, "hp") > 0)
      )
      |> Enum.reduce(transition, fn enemy, transition ->
        Transition.enqueue(
          transition,
          Event.attack(enemy.id, player, counter: true, at: event.at)
        )
      end)
    else
      transition
    end
  end

  # Players are people: "user", or someone the world names in people.
  defp player?(state, id),
    do: not State.character?(state, id) and (id == "user" or Map.has_key?(state.people, id))

  defp use_potion(%Transition{state: state} = transition, %{item: "potion", from: from}) do
    if State.stat?(state, from, "potions"),
      do: Transition.adjust_stat(transition, from, "potions", -1, min: 0),
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
        State.stat(state, id, "hp") > 0

  # A healer tends a hurt leader and otherwise strikes too. Someone holding
  # back says so once, until they fight beside the player again.
  defp join(%Transition{state: state} = transition, id, event, target_hp) do
    trust = State.get_relationship(state, id, event.from).trust
    leader_hp = State.stat(state, event.from, "hp")
    hurt? = leader_hp * 100 < stat_or(state, event.from, "max_hp", leader_hp) * 60
    held = Combat.held_key(id)

    cond do
      trust < Transition.param(transition, :party_trust) and Map.has_key?(state.cooldowns, held) ->
        transition

      trust < Transition.param(transition, :party_trust) ->
        transition
        |> Transition.put_cooldown(held)
        |> combat_output(%{event | from: id, to: event.from}, id, :holds_back, 0)

      State.stat(state, id, "heal") > 0 and hurt? and leader_hp > 0 ->
        transition
        |> Transition.clear_cooldown(held)
        |> Transition.enqueue(Event.heal(id, event.from, at: event.at))
        |> fought_beside(id, event.from)

      target_hp > 0 ->
        transition
        |> Transition.clear_cooldown(held)
        |> Transition.enqueue(
          event.to
          |> then(&Event.attack(id, &1, at: event.at))
          |> Map.put(:assist, true)
        )
        |> fought_beside(id, event.from)

      true ->
        transition
    end
  end

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
    if State.character?(state, event.to) and not Map.get(event, :counter, false) and
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
    output = %{
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

    output = Map.put(output, :text, Combat.describe(output, transition.state, :en))

    transition
    |> Transition.emit(output)
    |> Transition.log("[Output] #{output.text}")
  end
end
