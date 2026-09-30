defmodule Aethrion.Rules.Message do
  @moduledoc """
  A message changes how the receiver feels about the sender, according to its
  structured `tone`. Rules never parse the message text.

  | tone     | receiver effects                                                         |
  | -------- | ------------------------------------------------------------------------ |
  | warm     | affinity +4, trust +2, loneliness -15 (half of it after a quiet stretch, if more), joy +8, tension -2 (not below 0), remembers it |
  | neutral  | loneliness -6                                                            |
  | cold     | affinity -3, tension +4, joy -5, remembers it                            |
  | hostile  | affinity -8, trust -6, tension +10, stress +20 (`:sensitive` +10), joy -10, remembers it (with the trust it took) |

  History changes how a message lands. Impressions are built by
  `Aethrion.Rules.Consolidation` from faded memories:

  - **Goodwill.** If the receiver holds impressions of at least 3 kind acts
    (warm messages, gifts, comfort, time together) from the sender, and more
    kind acts than hostile messages (remembered ones and impressions alike),
    cold and hostile effects are halved: the receiver gives the sender the
    benefit of the doubt.
  - **Wariness.** If the receiver holds an impression of at least 2 hostile
    messages from the sender, warm effects are halved.

  Reputation only counts when the receiver has no firsthand impression of the
  sender at all, and counts for less: a sender the receiver has seen or heard
  be hostile to others at least twice gets 75% of a warm message's effect,
  and one known for warmth to others (3+) gets 75% of a cold or hostile
  one's (see `Aethrion.Rules.Reputation`).
  """

  use Aethrion.Rule,
    id: :message,
    description:
      "Tone-driven effects on the receiver: warm comforts, cold cools, hostile hurts; notable messages are remembered.",
    params: [
      warm_affinity: 4,
      warm_trust: 2,
      warm_loneliness: -15,
      warm_joy: 8,
      warm_tension: -2,
      warm_return_percent: 50,
      neutral_loneliness: -6,
      cold_affinity: -3,
      cold_tension: 4,
      cold_joy: -5,
      hostile_affinity: -8,
      hostile_trust: -6,
      hostile_tension: 10,
      hostile_stress: 20,
      hostile_joy: -10,
      sensitive_stress: 10,
      warm_importance: 45,
      cold_importance: 35,
      hostile_importance: 65,
      goodwill_count: 3,
      goodwill_percent: 50,
      wariness_count: 2,
      wariness_percent: 50,
      reputation_goodwill_count: 3,
      reputation_goodwill_percent: 75,
      reputation_wariness_count: 2,
      reputation_wariness_percent: 75
    ]

  alias Aethrion.{Memories, Memory, State, Transition}
  alias Aethrion.Rules.Consolidation

  @kind_patterns ["warm", "gift", "comfort", "together"]
  @firsthand_patterns @kind_patterns ++ ["cold", "hostile", "apology"]

  # Which fields each tone touches; the amounts are params named <tone>_<field>.
  @effects %{
    warm: [relationship: [:affinity, :trust], character: [:loneliness, :joy]],
    neutral: [relationship: [], character: [:loneliness]],
    cold: [relationship: [:affinity, :tension], character: [:joy]],
    hostile: [relationship: [:affinity, :trust, :tension], character: [:stress, :joy]]
  }

  @impl true
  def apply(%Transition{event: event} = transition) do
    effects = Map.fetch!(@effects, event.tone)
    {transition, percent} = history_modifier(transition)

    amount = fn field ->
      div(Transition.param(transition, :"#{event.tone}_#{field}") * percent, 100)
    end

    trust = fn transition ->
      Aethrion.State.get_relationship(transition.state, event.to, event.from).trust
    end

    trust_before = trust.(transition)

    transition =
      Enum.reduce(effects[:relationship], transition, fn field, transition ->
        Transition.adjust_relationship(transition, event.to, event.from, field, amount.(field))
      end)

    trust_lost = max(trust_before - trust.(transition), 0)

    transition =
      Enum.reduce(effects[:character], transition, fn field, transition ->
        Transition.adjust_character(
          transition,
          event.to,
          field,
          character_amount(transition, field, amount, percent)
        )
      end)

    transition = soothe(transition, percent)

    case event.tone do
      :neutral ->
        transition

      tone ->
        importance = Transition.param(transition, :"#{tone}_importance")
        Transition.remember(transition, memory(event, importance, trust_lost))
    end
  end

  # A kind word after a quiet stretch (no company for the time passage's
  # quiet hours) eases `warm_return_percent` (half) of whatever loneliness has
  # built up, if that is more than usual: coming back matters more than the
  # tenth message in a day.
  defp character_amount(
         %Transition{event: %{tone: :warm} = event, state: state} = transition,
         :loneliness,
         amount,
         percent
       ) do
    quiet = Aethrion.Tuning.get(state, Aethrion.Rules.TimePassage, :quiet_hours)
    key = Aethrion.Rules.TimePassage.company_key(event.to)

    base = amount.(:loneliness)

    if base < 0 and State.cooldown_ready?(state, key, quiet) do
      current = Transition.character_state(transition, event.to).loneliness
      share = Transition.param(transition, :warm_return_percent)
      min(base, -div(current * share * percent, 10_000))
    else
      base
    end
  end

  # Sensitive characters take harsh words harder.
  defp character_amount(
         %Transition{event: %{tone: :hostile} = event, state: state} = transition,
         :stress,
         amount,
         percent
       ) do
    case Aethrion.State.character(state, event.to) do
      %Aethrion.Character{} = character ->
        if Aethrion.Character.trait?(character, :sensitive),
          do:
            amount.(:stress) + div(Transition.param(transition, :sensitive_stress) * percent, 100),
          else: amount.(:stress)

      nil ->
        amount.(:stress)
    end
  end

  defp character_amount(_transition, field, amount, _percent), do: amount.(field)

  # Kind words ease leftover tension a little, never below zero.
  defp soothe(%Transition{event: %{tone: :warm} = event} = transition, percent) do
    Aethrion.Rules.Apology.ease_tension(
      transition,
      event.to,
      event.from,
      div(Transition.param(transition, :warm_tension) * percent, 100)
    )
  end

  defp soothe(transition, _percent), do: transition

  # Returns the percentage of the tone's normal effect that applies, noting why
  # when history changes it.
  defp history_modifier(%Transition{event: event, state: state} = transition) do
    counts = Consolidation.counts(state, event.to, event.from)
    count = &Map.get(counts, {"impression", &1}, 0)
    reputation = &Map.get(counts, {"reputation", &1}, 0)
    receiver = Transition.name(transition, event.to)
    sender = Transition.name(transition, event.from)
    param = &Transition.param(transition, &1)

    firsthand? = Enum.any?(@firsthand_patterns, &(count.(&1) > 0))

    cond do
      goodwill?(state, event) ->
        {Transition.note(
           transition,
           "#{receiver} gives #{sender} the benefit of the doubt after a long record of kindness",
           subject: event.to
         ), param.(:goodwill_percent)}

      event.tone == :warm and count.("hostile") >= param.(:wariness_count) ->
        {Transition.note(
           transition,
           "#{receiver} is wary of kindness from #{sender} after repeated hostility",
           subject: event.to
         ), param.(:wariness_percent)}

      firsthand? ->
        {transition, 100}

      event.tone in [:cold, :hostile] and
          reputation.("warm") >= param.(:reputation_goodwill_count) ->
        {Transition.note(
           transition,
           "#{receiver} has seen enough warmth from #{sender} toward others to give them some benefit of the doubt",
           subject: event.to
         ), param.(:reputation_goodwill_percent)}

      event.tone == :warm and reputation.("hostile") >= param.(:reputation_wariness_count) ->
        {Transition.note(
           transition,
           "#{receiver} is guarded with #{sender}, knowing how they have treated others",
           subject: event.to
         ), param.(:reputation_wariness_percent)}

      true ->
        {transition, 100}
    end
  end

  # Hostile messages from the sender that the receiver still remembers in
  # detail (not yet folded into an impression), counting this one.
  defp recent_hostility(state, %{from: sender, to: receiver, tone: tone} = event) do
    current = if tone == :hostile, do: 1, else: 0
    this_one = topic(event)

    state
    |> Memories.for_character(receiver)
    |> Enum.count(
      &(match?(
          %Memory{
            kind: :experienced,
            data: %{"event" => "message_sent", "tone" => "hostile", "from" => ^sender}
          },
          &1
        ) and &1.topic != this_one)
    )
    |> Kernel.+(current)
  end

  @doc false
  # Whether cold or hostile `event` lands at goodwill strength: the same
  # answer before or after this rule has remembered the message, so a reply
  # can ask too.
  @spec goodwill?(Aethrion.State.t(), map()) :: boolean()
  def goodwill?(state, %{tone: tone} = event) when tone in [:cold, :hostile] do
    counts = Consolidation.counts(state, event.to, event.from)
    count = &Map.get(counts, {"impression", &1}, 0)
    kindness = @kind_patterns |> Enum.map(count) |> Enum.sum()

    kindness >= Aethrion.Tuning.get(state, __MODULE__, :goodwill_count) and
      kindness > count.("hostile") + recent_hostility(state, event)
  end

  def goodwill?(_state, _event), do: false

  # The receiver's memory keeps how much trust the words took, so an apology
  # can give back no more than that (`Aethrion.Rules.Apology`).
  defp memory(event, importance, trust_lost) do
    Memory.new(
      id: "memory:#{event.to}:message:#{event.id}",
      character_id: event.to,
      content: "#{event.from} said to #{event.to} (#{event.tone}): \"#{event.text}\"",
      importance: importance,
      created_at: event.at,
      related_characters: [event.from],
      kind: :experienced,
      topic: topic(event),
      data:
        if(event.tone == :hostile,
          do: Map.put(data(event), "trust_lost", trust_lost),
          else: data(event)
        )
    )
  end

  @doc false
  def topic(event), do: "message:#{event.id}"

  @doc false
  def data(event) do
    %{
      "event" => "message_sent",
      "from" => event.from,
      "to" => event.to,
      "tone" => Atom.to_string(event.tone),
      "text" => event.text
    }
  end
end
