defmodule Aethrion.Rules.Reply do
  @moduledoc """
  Characters reply when someone outside the cast (such as the user) talks to
  them, gives them something (a reply with tone `:gift`), or apologizes to
  them (tone `:apology`, which sees every apology from that person the
  character still remembers and the latest harsh words that prompted it). The reply is an expressive output; the only state it keeps is when
  this person last talked to this character (the `"contact:<character>:<person>"`
  cooldown key), so the reply can notice a long absence
  (`Aethrion.Expression.Request` `:since_contact`).
  """

  use Aethrion.Rule,
    id: :reply,
    description:
      "The receiver replies to external actors' messages, gifts, and apologies, phrased from their current mood and memories."

  alias Aethrion.{Character, Expression, Memories, Memory, Output, State, Transition}

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    receiver = State.character(state, event.to)

    if Character.can_act?(receiver) and not State.character?(state, event.from) do
      key = contact_key(event.to, event.from)

      since_contact =
        case Map.fetch(state.cooldowns, key) do
          {:ok, at} -> max(state.clock - at, 0)
          :error -> nil
        end

      {tone, message, memories, repeats} = incoming(state, event)

      request =
        Expression.build_request(state, :reply, event.to, event.from,
          reason: :reply,
          tone: tone,
          message: message,
          since_contact: since_contact,
          repeats: repeats,
          memories: memories
        )

      output =
        Output.reply(event.to, event.from, tone, request.fallback_text,
          memory_refs: Enum.map(request.memories, & &1.id),
          context: request
        )

      transition
      |> Transition.put_cooldown(key)
      |> Transition.emit(output)
      |> Transition.log("[Output] #{receiver.name} -> #{event.from}: \"#{output.text}\"")
    else
      transition
    end
  end

  @doc false
  def contact_key(character, person), do: "contact:#{character}:#{person}"

  defp incoming(state, %{type: :gift_received} = event) do
    gift? =
      &match?(
        %Memory{kind: :experienced, data: %{"event" => "gift_received", "from" => from}}
        when from == event.from,
        &1
      )

    {:gift, event.item, with_record(state, event), repeats(state, event, gift?)}
  end

  defp incoming(state, %{type: :apology_offered} = event),
    do: {:apology, event.reason, apology_memories(state, event.to, event.from), 1}

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

          _other ->
            false
        end
      end)

    Enum.uniq_by(memories(state, event.to, event.from) ++ record, & &1.id)
  end

  # How many such things from the sender the character still remembers, this
  # one included, so replies can vary and escalate.
  defp repeats(state, event, same?) do
    state |> Memories.for_character(event.to) |> Enum.count(same?) |> max(1)
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

    apologies ++ List.wrap(harsh) ++ List.wrap(gift)
  end

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
