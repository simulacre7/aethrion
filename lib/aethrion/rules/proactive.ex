defmodule Aethrion.Rules.Proactive do
  @moduledoc """
  Characters reach out to the user on their own when social pressure crosses a
  threshold. At most one proactive message per character per event.

  | reason     | condition                                                  | cooldown |
  | ---------- | ---------------------------------------------------------- | -------- |
  | `:jealous` | jealousy >= 15 and jealousy + loneliness >= 45             | 24h      |
  | `:lonely`  | loneliness >= 60 and jealousy < 15                         | 24h      |
  | `:curious` | heard secondhand news about the user and is `:playful` or has affinity >= 30 toward the user | once per topic |
  """

  use Aethrion.Rule,
    id: :proactive,
    description:
      "Jealous (pressure>=45), lonely (>=60), or curious (heard news about the user) characters message the user.",
    params: [
      jealousy_floor: 15,
      pressure_threshold: 45,
      loneliness_threshold: 60,
      cooldown_hours: 24,
      curious_affinity: 30
    ]

  alias Aethrion.{Character, Expression, Memories, Memory, Output, State, Transition}

  @recipient "user"

  @impl true
  def apply(%Transition{} = transition) do
    params = Map.new(params(), fn {key, _default} -> {key, Transition.param(transition, key)} end)

    transition.state
    |> State.sorted_characters()
    |> Enum.filter(&Character.can_act?/1)
    |> Enum.reduce(transition, fn character, transition ->
      case first_trigger(transition.state, character, params) do
        nil -> transition
        {reason, key, opts} -> send_message(transition, character, reason, key, opts)
      end
    end)
  end

  defp first_trigger(state, character, params) do
    Enum.find_value([:jealous, :lonely, :curious], &trigger(&1, state, character, params))
  end

  defp trigger(:jealous, state, %Character{id: id, state: cs}, params) do
    key = "proactive:#{id}:jealous"

    if cs.jealousy >= params.jealousy_floor and
         cs.jealousy + cs.loneliness >= params.pressure_threshold and
         State.cooldown_ready?(state, key, params.cooldown_hours) do
      {:jealous, key, []}
    end
  end

  defp trigger(:lonely, state, %Character{id: id, state: cs}, params) do
    key = "proactive:#{id}:lonely"

    if cs.loneliness >= params.loneliness_threshold and cs.jealousy < params.jealousy_floor and
         State.cooldown_ready?(state, key, params.cooldown_hours) do
      {:lonely, key, []}
    end
  end

  defp trigger(:curious, state, %Character{id: id} = character, params) do
    interested? =
      Character.trait?(character, :playful) or
        State.get_relationship(state, id, @recipient).affinity >= params.curious_affinity

    if interested? do
      state
      |> Memories.for_character(id)
      |> Enum.find_value(fn memory ->
        key = "proactive:#{id}:curious:#{memory.topic}"

        if memory.kind == :heard and Memory.involves?(memory, @recipient) and
             State.cooldown_ready?(state, key, :once) do
          {:curious, key, memories: [memory]}
        end
      end)
    end
  end

  defp send_message(transition, character, reason, key, opts) do
    request =
      Expression.build_request(
        transition.state,
        :proactive_message,
        character.id,
        @recipient,
        Keyword.put(opts, :reason, reason)
      )

    output =
      Output.proactive_message(character.id, @recipient, reason, request.fallback_text,
        memory_refs: Enum.map(request.memories, & &1.id),
        context: request
      )

    transition
    |> Transition.put_cooldown(key)
    |> Transition.emit(output)
    |> Transition.log("[Output] #{character.name} -> #{@recipient}: \"#{output.text}\"")
  end
end
