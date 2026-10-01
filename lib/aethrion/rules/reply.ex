defmodule Aethrion.Rules.Reply do
  @moduledoc """
  Characters reply when someone outside the cast (such as the user) talks to
  them, gives them something (a reply with tone `:gift`), or apologizes to
  them (tone `:apology`, which sees every apology from that person the
  character still remembers and the latest harsh words that prompted it).

  The reply is an expressive output. The only state it keeps is when this
  person last talked to this character (the `"contact:<character>:<person>"`
  cooldown key), so replies and lonely messages can notice a long absence
  (`Aethrion.Expression.Request` `:since_contact`), and when they last spoke
  coldly or harshly (`"rebuff:<character>:<person>"`), so a lonely character
  does not write right after being brushed off.
  """

  use Aethrion.Rule,
    id: :reply,
    description:
      "The receiver replies to external actors' messages, gifts, and apologies, phrased from their mood (after harsh words, the hurt; otherwise the mood the words found) and memories."

  alias Aethrion.{Character, Expression, Memories, Memory, Output, State, Transition}

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    # Harsh words are answered from the hurt they cause; anything that eases
    # (kind words, gifts, apologies) from the mood they found.
    mood =
      if Map.get(event, :tone) in [:cold, :hostile],
        do: nil,
        else: mood_before(transition, event.to)

    receiver = State.character(state, event.to)

    # An enemy in a fight (an "enemy" stat) does not chat back.
    if Character.can_act?(receiver) and not State.character?(state, event.from) and
         State.stat(state, event.to, "enemy") == 0 do
      key = contact_key(event.to, event.from)

      since_contact = State.hours_since(state, key)

      {tone, message, memories, repeats} = incoming(state, event)

      request =
        Expression.build_request(state, :reply, event.to, event.from,
          reason: reason(state, event),
          tone: tone,
          message: message,
          since_contact: since_contact,
          repeats: repeats,
          goodwill: Aethrion.Rules.Message.goodwill?(state, event),
          speaker_mood: mood,
          bond: Aethrion.Rules.Bond.during(transition, event.to, event.from),
          memories: memories
        )

      output =
        Output.reply(event.to, event.from, tone, request.fallback_text,
          memory_refs: Enum.map(request.memories, & &1.id),
          context: request
        )

      rebuffed =
        if Map.get(event, :tone) in [:cold, :hostile],
          do: [rebuff_key(event.to, event.from)],
          else: []

      [key | rebuffed]
      |> Enum.reduce(transition, &Transition.put_cooldown(&2, &1))
      |> Transition.emit(output)
      |> Transition.log("[Output] #{receiver.name} -> #{event.from}: \"#{output.text}\"")
    else
      transition
    end
  end

  @doc false
  @spec contact_key(String.t(), String.t()) :: String.t()
  def contact_key(character, person), do: "contact:#{character}:#{person}"

  @doc false
  # When this person last brushed the character off (cold or hostile words).
  @spec rebuff_key(String.t(), String.t()) :: String.t()
  def rebuff_key(character, person), do: "rebuff:#{character}:#{person}"

  # A reply comes from how the character felt when the words arrived: the
  # mood of their numbers before this event changed them. The trace is newest
  # first, so the last entry per field holds the value before the event.
  defp mood_before(%Transition{} = transition, id) do
    case State.character(transition.state, id) do
      nil ->
        nil

      character ->
        transition
        |> Transition.values_before(:character, id)
        |> Map.take(Aethrion.CharacterState.numeric_fields())
        |> then(&struct(character.state, &1))
        |> Aethrion.Rules.Mood.derive(transition.state)
    end
  end

  # A gift from someone the character felt jealous about (seeing them give to
  # someone else) since their last gift or apology, within the last three
  # days, is reassurance.
  defp reason(state, %{type: :gift_received, from: giver, to: receiver} = event) do
    this_one = Aethrion.Rules.Gift.topic(event)

    last_gift =
      state
      |> Memories.for_character(receiver)
      |> Enum.filter(
        &(match?(
            %Memory{kind: :experienced, data: %{"event" => event, "from" => ^giver}}
            when event in ["gift_received", "apology_offered"],
            &1
          ) and &1.topic != this_one)
      )
      |> Enum.map(& &1.created_tick)
      |> Enum.max(fn -> nil end)

    case Map.fetch(state.cooldowns, Aethrion.Rules.Observation.jealous_key(receiver, giver)) do
      {:ok, felt} when state.clock - felt <= 72 and (is_nil(last_gift) or felt > last_gift) ->
        :reassurance

      _other ->
        :reply
    end
  end

  defp reason(_state, _event), do: :reply

  defp incoming(state, %{type: :gift_received} = event) do
    gift? =
      &match?(
        %Memory{kind: :experienced, data: %{"event" => "gift_received", "from" => from}}
        when from == event.from,
        &1
      )

    {:gift, event.item, with_record(state, event), repeats(state, event, gift?)}
  end

  defp incoming(state, %{type: :apology_offered} = event) do
    apology? =
      &match?(
        %Memory{kind: :experienced, data: %{"event" => "apology_offered", "from" => from}}
        when from == event.from,
        &1
      )

    {:apology, event.reason, apology_memories(state, event.to, event.from),
     repeats(state, event, apology?)}
  end

  defp incoming(state, event) do
    tone = Atom.to_string(event.tone)

    same_tone? =
      &match?(
        %Memory{
          kind: :experienced,
          data: %{"event" => "message_sent", "from" => from, "tone" => ^tone}
        }
        when from == event.from,
        &1
      )

    {event.tone, event.text, with_record(state, event), repeats(state, event, same_tone?)}
  end

  # Every reply also weighs the whole record: every harsh message the
  # character still remembers from the sender, the sender's apologies, and
  # what the character makes of the sender, not only the three most relevant
  # memories.
  defp with_record(state, event) do
    record =
      state
      |> Memories.for_character(event.to)
      |> Enum.filter(fn memory ->
        case memory do
          %Memory{kind: :experienced, data: %{"from" => from} = data} when from == event.from ->
            match?(%{"event" => "message_sent", "tone" => "hostile"}, data) or
              data["event"] == "apology_offered"

          %Memory{kind: :impression, data: %{"event" => "impression", "from" => from}} ->
            from == event.from

          # Apologies they saw or heard the sender make to others, and the
          # hostile words those would answer for.
          %Memory{kind: kind, data: %{"event" => "apology_offered", "from" => from}}
          when kind in [:observed, :heard] ->
            from == event.from

          %Memory{
            kind: kind,
            data: %{"event" => "message_sent", "tone" => "hostile", "from" => from}
          }
          when kind in [:observed, :heard] ->
            from == event.from

          # Gifts they saw the sender give someone else.
          %Memory{kind: :observed, data: %{"event" => "gift_received", "from" => from}} ->
            from == event.from

          _other ->
            false
        end
      end)

    Enum.uniq_by(memories(state, event.to, event.from) ++ record, & &1.id)
  end

  # How many such things from the sender the character still remembers, this
  # one included, so replies can vary and escalate.
  # Counted over the last four days, faded details included: a cold word is
  # forgotten in a day, but not that there have been several.
  defp repeats(state, event, same?) do
    state
    |> Memories.for_character(event.to, include_faded: true)
    |> Enum.count(&(same?.(&1) and state.clock - &1.created_tick <= 96))
    |> max(1)
  end

  # Every apology from the sender the character remembers, newest first, the
  # latest harsh words from the sender to them, and the latest gift they saw
  # the sender give someone else (what a jealous character may be owed an
  # apology for).
  defp apology_memories(state, character, sender) do
    mine = Memories.for_character(state, character)

    apologies =
      Enum.filter(
        mine,
        &match?(
          %Memory{kind: :experienced, data: %{"event" => "apology_offered", "from" => ^sender}},
          &1
        )
      )

    harsh =
      Enum.find(mine, fn memory ->
        match?(
          %Memory{
            kind: :experienced,
            data: %{"event" => "message_sent", "from" => ^sender, "tone" => tone}
          }
          when tone in ["cold", "hostile"],
          memory
        )
      end)

    gift =
      Enum.find(mine, fn memory ->
        match?(
          %Memory{kind: :observed, data: %{"event" => "gift_received", "from" => ^sender}},
          memory
        )
      end)

    # What the character makes of the sender's harsh words, once faded.
    impressions =
      Enum.filter(mine, fn memory ->
        match?(
          %Memory{kind: :impression, data: %{"from" => ^sender, "pattern" => pattern}}
          when pattern in ["cold", "hostile"],
          memory
        )
      end)

    # How the sender treated others, as the character saw or heard it, with
    # any amends made for it.
    to_others = Enum.filter(mine, &toward_others?(&1, sender))

    apologies ++ List.wrap(harsh) ++ List.wrap(gift) ++ impressions ++ to_others
  end

  defp toward_others?(%Memory{kind: kind, data: data}, sender) when kind in [:observed, :heard] do
    data["from"] == sender and
      (data["event"] == "apology_offered" or
         (data["event"] == "message_sent" and data["tone"] == "hostile"))
  end

  defp toward_others?(_memory, _sender), do: false

  # The usual relevant memories, plus any apology the sender made to someone
  # whose mistreatment is among them: a reply should not bring up harsh words
  # the character also saw the sender make amends for.
  defp memories(state, character, sender) do
    selected = Memories.relevant(state, character, focus: [sender], limit: 3)

    wronged =
      for %Memory{
            data: %{"event" => "message_sent", "tone" => "hostile", "from" => ^sender, "to" => to}
          } <-
            selected,
          do: to

    case wronged -- [character] do
      [] ->
        selected

      wronged ->
        # The latest apology to each wronged person is enough.
        amends =
          state
          |> Memories.for_character(character)
          |> Enum.filter(fn memory ->
            match?(%Memory{data: %{"event" => "apology_offered", "from" => ^sender}}, memory) and
              memory.data["to"] in wronged
          end)
          |> Enum.uniq_by(& &1.data["to"])

        Enum.uniq_by(selected ++ amends, & &1.id)
    end
  end
end
