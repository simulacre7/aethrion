defmodule Aethrion.Rules.Reputation do
  @moduledoc """
  Characters judge people by how they treat others.

  - **Witnesses.** Characters in a message's or apology's `:observed_by`
    remember a warm, cold, or hostile message, or an apology, as an
    `:observed` memory of the same topic as the receiver's.
  - **Judgement.** A witness who cares about the receiver (affinity >=
    `care_threshold`) changes how they feel about the sender: hostility costs
    trust and adds tension, coldness costs a little trust, warmth earns a little
    affinity and trust, and an apology earns a little trust and eases tension
    (never below zero): making amends in public repairs a reputation. What
    a character only sees or hears raises affinity and trust no higher than
    `goodwill_cap` (60).
  - **Hearsay.** A character who hears about such a message or apology through
    `:gossip_shared` judges the sender the same way, at `heard_percent` of the
    effect.

  Inactive or blocked characters are not witnesses. Nobody judges a message
  they sent or received themselves; the receiver's own
  reaction is `Aethrion.Rules.Message`. Over time, faded observed and heard
  memories fold into reputation impressions (see
  `Aethrion.Rules.Consolidation`), which change how the sender's own messages
  land later.
  """

  use Aethrion.Rule,
    id: :reputation,
    description:
      "Witnesses remember how someone treated another; those who care about the receiver judge the sender (hearsay at 50%), raising affinity and trust no higher than 60.",
    params: [
      care_threshold: 20,
      hostile_trust: -4,
      hostile_tension: 4,
      cold_trust: -2,
      cold_tension: 2,
      warm_affinity: 2,
      warm_trust: 1,
      heard_percent: 50,
      hostile_importance: 60,
      cold_importance: 35,
      warm_importance: 40,
      apology_trust: 2,
      apology_tension: -3,
      apology_importance: 45,
      goodwill_cap: 60
    ]

  alias Aethrion.{Character, Memory, State, Transition}
  alias Aethrion.Rules.{Apology, Gossip, Message}

  # Which relationship fields each tone touches; amounts are params named
  # <tone>_<field>.
  @effects %{
    warm: [:affinity, :trust],
    cold: [:trust, :tension],
    hostile: [:trust, :tension],
    apology: [:trust, :tension]
  }

  @treatments %{"warm" => :warm, "cold" => :cold, "hostile" => :hostile}

  @impl true
  def apply(%Transition{event: %{type: :message_sent, tone: tone} = event} = transition)
      when is_map_key(@effects, tone),
      do: witnessed(transition, event, tone)

  def apply(%Transition{event: %{type: :apology_offered} = event} = transition),
    do: witnessed(transition, event, :apology)

  def apply(%Transition{event: %{type: :gossip_shared} = event, state: state} = transition) do
    with %Memory{data: data} <- State.memory(state, Gossip.heard_memory_id(event)),
         {actor, target, tone} <- treatment(data),
         false <- event.to in [actor, target] do
      judge(
        transition,
        event.to,
        actor,
        target,
        tone,
        :heard,
        Transition.param(transition, :heard_percent)
      )
    else
      _ -> transition
    end
  end

  def apply(%Transition{} = transition), do: transition

  defp witnessed(transition, event, tone) do
    event
    |> Map.get(:observed_by, [])
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [event.from, event.to]))
    |> Enum.filter(&(transition.state |> State.character(&1) |> Character.can_act?()))
    |> Enum.reduce(transition, fn witness, transition ->
      transition
      |> Transition.remember(witness_memory(transition, event, witness))
      |> judge(witness, event.from, event.to, tone, :saw, 100)
    end)
  end

  @doc """
  Reads a memory's data as a treatment: `{actor, target, tone}` for a warm,
  cold, or hostile message or an apology (tone `:apology`), or `nil`.
  """
  @spec treatment(map()) :: {String.t(), String.t(), :warm | :cold | :hostile | :apology} | nil
  def treatment(%{"event" => "message_sent", "from" => from, "to" => to, "tone" => tone})
      when is_map_key(@treatments, tone),
      do: {from, to, Map.fetch!(@treatments, tone)}

  def treatment(%{"event" => "apology_offered", "from" => from, "to" => to}),
    do: {from, to, :apology}

  def treatment(_data), do: nil

  defp judge(%Transition{state: state} = transition, judge, actor, target, tone, how, percent) do
    if State.get_relationship(state, judge, target).affinity >=
         Transition.param(transition, :care_threshold) do
      transition =
        Transition.note(transition, note(transition, judge, actor, target, tone, how),
          subject: judge
        )

      Enum.reduce(Map.fetch!(@effects, tone), transition, fn field, transition ->
        amount = div(Transition.param(transition, :"#{tone}_#{field}") * percent, 100)
        adjust(transition, judge, actor, field, amount)
      end)
    else
      transition
    end
  end

  # Easing tension never makes it negative.
  defp adjust(transition, judge, actor, :tension, amount) when amount < 0,
    do: Apology.ease_tension(transition, judge, actor, amount)

  # What others see earns liking and trust only up to `goodwill_cap`: past
  # that, it takes dealing with the person yourself.
  defp adjust(transition, judge, actor, field, amount)
       when field in [:affinity, :trust] and amount > 0 do
    current = Map.fetch!(State.get_relationship(transition.state, judge, actor), field)

    case min(amount, Transition.param(transition, :goodwill_cap) - current) do
      room when room > 0 -> Transition.adjust_relationship(transition, judge, actor, field, room)
      _none -> transition
    end
  end

  defp adjust(transition, judge, actor, field, amount),
    do: Transition.adjust_relationship(transition, judge, actor, field, amount)

  defp note(transition, judge, actor, target, tone, how) do
    [judge, actor, target] = Enum.map([judge, actor, target], &Transition.name(transition, &1))
    verb = if how == :saw, do: "saw", else: "heard"

    case tone do
      :warm ->
        "#{judge} #{verb} #{actor} be kind to #{target} and warms to #{actor}"

      :apology ->
        "#{judge} #{verb} #{actor} apologize to #{target} and trusts #{actor} a little more"

      tone ->
        "#{judge} #{verb} #{actor} be #{tone} to #{target} and trusts #{actor} less"
    end
  end

  defp witness_memory(transition, %{type: :apology_offered} = event, witness) do
    observed(transition, event, witness,
      content: "#{witness} saw #{event.from} apologize to #{event.to}: #{event.reason}",
      importance: Transition.param(transition, :apology_importance),
      topic: Apology.topic(event),
      data: Apology.data(event)
    )
  end

  defp witness_memory(transition, event, witness) do
    observed(transition, event, witness,
      content: "#{witness} saw #{event.from} be #{event.tone} to #{event.to}: \"#{event.text}\"",
      importance: Transition.param(transition, :"#{event.tone}_importance"),
      topic: Message.topic(event),
      data: Message.data(event)
    )
  end

  defp observed(_transition, event, witness, fields) do
    Memory.new(
      [
        id: "memory:#{witness}:observed:#{event.id}",
        character_id: witness,
        created_at: event.at,
        related_characters: [event.from, event.to],
        kind: :observed
      ] ++ fields
    )
  end
end
