defmodule Aethrion.Rules.Reply do
  @moduledoc """
  Characters reply when someone outside the cast (such as the user) talks to
  them. The reply is an expressive output; the only state it keeps is when
  this person last talked to this character (the `"contact:<character>:<person>"`
  cooldown key), so the reply can notice a long absence
  (`Aethrion.Expression.Request` `:since_contact`).
  """

  use Aethrion.Rule,
    id: :reply,
    description:
      "The receiver replies to external actors, phrased from their current mood and memories."

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

      request =
        Expression.build_request(state, :reply, event.to, event.from,
          reason: :reply,
          tone: event.tone,
          message: event.text,
          since_contact: since_contact,
          memories: memories(state, event.to, event.from)
        )

      output =
        Output.reply(event.to, event.from, event.tone, request.fallback_text,
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

    amends =
      state
      |> Memories.for_character(character)
      |> Enum.filter(fn memory ->
        match?(%Memory{data: %{"event" => "apology_offered", "from" => ^sender}}, memory) and
          memory.data["to"] in wronged
      end)

    Enum.uniq_by(selected ++ amends, & &1.id)
  end
end
