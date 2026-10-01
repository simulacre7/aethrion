defmodule Aethrion.Rules.Combat do
  @moduledoc """
  Fights, decided by the numbers (`Aethrion.Combat`). Fighters are actors
  with an `"hp"` stat; `"attack"`, `"defense"`, `"max_hp"`, `"speed"`, and
  `"heal"` are read when present.

  - **attack**: damage is `attack + roll - defense`, at least 1, where the
    roll (0..5) comes from the event itself, so a fight replays exactly. A
    roll of 5 is a critical hit (half again as much). A raised guard halves
    the blow and is spent. At 0 hp a fighter is defeated. A character still
    standing hits back once (`counter: true` events are not answered).
  - **defend**: the next blow taken is halved.
  - **heal**: restores `amount` (or the healer's `"heal"` stat, or 10), up
    to `"max_hp"`.
  - **flee**: gets away when `speed + roll >= the other's speed + 3`;
    otherwise the other gets a free blow.

  Fighting is social too. A character who is attacked loses affinity and
  trust toward the attacker, gains tension, and remembers it; witnesses who
  care about them (affinity >= 30) trust the attacker less, and the others,
  unless they hold something against the attacker, trust someone who fights
  beside them a little more. A character healed by
  someone grows fonder of them and trusts them more.
  """

  use Aethrion.Rule,
    id: :combat,
    description:
      "Attacks, guards, heals, and flight change hp by the numbers; fighters hit back; being attacked or healed changes how characters feel about each other.",
    params: [
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
  def apply(%Transition{event: %{type: :attack} = event} = transition) do
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
        else: counter(transition, event)
    end)
  end

  def apply(%Transition{event: %{type: :defend} = event} = transition) do
    transition
    |> Transition.put_cooldown(Combat.guard_key(event.from))
    |> combat_output(Map.put(event, :to, nil), event.from, :guarded, 0)
  end

  def apply(%Transition{event: %{type: :heal} = event} = transition) do
    state = transition.state

    amount =
      event.amount ||
        stat_or(state, event.from, "heal", Transition.param(transition, :default_heal))

    max_hp = stat_or(state, event.to, "max_hp", State.stat(state, event.to, "hp") + amount)
    before = State.stat(state, event.to, "hp")
    healed = max(min(before + amount, max_hp) - before, 0)

    transition
    |> Transition.adjust_stat(event.to, "hp", healed, log: false)
    |> combat_output(event, event.to, :healed, healed)
    |> grateful(event)
  end

  def apply(%Transition{event: %{type: :flee} = event} = transition) do
    state = transition.state
    roll = Combat.roll(event, state)

    if State.stat(state, event.from, "speed") + roll >= State.stat(state, event.to, "speed") + 3 do
      combat_output(transition, event, event.from, :fled, 0)
    else
      transition
      |> combat_output(event, event.from, :caught, 0)
      |> Transition.enqueue(Event.attack(event.to, event.from, counter: true, at: event.at))
    end
  end

  def apply(transition), do: transition

  defp stat_or(state, id, stat, default),
    do: if(State.stat?(state, id, stat), do: State.stat(state, id, stat), else: default)

  # A character still standing answers a blow, once.
  defp counter(%Transition{state: state} = transition, event) do
    if State.character?(state, event.to) and not Map.get(event, :counter, false) and
         State.stat(state, event.from, "hp") > 0 do
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
        # someone fight beside them.
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

  defp grateful(%Transition{state: state} = transition, event) do
    if State.character?(state, event.to) and event.from != event.to do
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
