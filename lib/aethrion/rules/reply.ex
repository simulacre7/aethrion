defmodule Aethrion.Rules.Reply do
  @moduledoc """
  Characters reply when someone outside the cast (such as the user) talks to
  them. The reply is an expressive output only; it does not change state.
  """

  use Aethrion.Rule,
    id: :reply,
    description:
      "The receiver replies to external actors, phrased from their current mood and memories."

  alias Aethrion.{Character, Expression, Output, State, Transition}

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    receiver = State.character(state, event.to)

    if Character.can_act?(receiver) and not State.character?(state, event.from) do
      request =
        Expression.build_request(state, :reply, event.to, event.from,
          reason: :reply,
          tone: event.tone,
          message: event.text
        )

      output =
        Output.reply(event.to, event.from, event.tone, request.fallback_text,
          memory_refs: Enum.map(request.memories, & &1.id),
          context: request
        )

      transition
      |> Transition.emit(output)
      |> Transition.log("[Output] #{receiver.name} -> #{event.from}: \"#{output.text}\"")
    else
      transition
    end
  end
end
