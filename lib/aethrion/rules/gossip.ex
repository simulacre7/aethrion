defmodule Aethrion.Rules.Gossip do
  @moduledoc """
  A character tells another about one of their memories.

  The listener gains a secondhand (`:heard`) memory of the same topic with
  importance reduced by 15 (minimum 20). Venting eases the teller's loneliness a little and
  builds their trust in the listener. Knowledge spreads through the social
  graph this way, one deterministic step at a time.
  """

  use Aethrion.Rule,
    id: :gossip,
    description:
      "Listener gains a secondhand memory (importance -15, min 20); teller loneliness -4 and trust toward listener +2.",
    params: [importance_drop: 15, min_importance: 20, loneliness_delta: -4, trust_delta: 2]

  alias Aethrion.{Expression, Memories, Memory, Output, State, Transition}

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    memory = State.memory(state, event.memory_id)
    teller = Transition.name(transition, event.from)
    listener = Transition.name(transition, event.to)

    if Memories.knows_topic?(state, event.to, memory.topic) do
      Transition.note(transition, "#{listener} already knew what #{teller} shared",
        subject: event.to
      )
    else
      request =
        Expression.build_request(state, :character_interaction, event.from, event.to,
          reason: :gossip,
          memories: [memory]
        )

      transition
      |> Transition.update_memory(
        memory.id,
        &%{&1 | shared_with: &1.shared_with ++ [event.to]},
        field: :shared_with
      )
      |> Transition.remember(heard_memory(transition, event, memory))
      |> Transition.adjust_character(
        event.from,
        :loneliness,
        Transition.param(transition, :loneliness_delta)
      )
      |> Transition.adjust_relationship(
        event.from,
        event.to,
        :trust,
        Transition.param(transition, :trust_delta)
      )
      |> Transition.emit(
        Output.character_interaction(:gossip, event.from, event.to, request.fallback_text,
          memory_refs: [memory.id],
          context: request
        )
      )
      |> Transition.log("[Scene] #{request.fallback_text}")
    end
  end

  @doc "The id of the memory a listener gains from `event`."
  def heard_memory_id(event), do: "memory:#{event.to}:heard:#{event.id}"

  defp heard_memory(transition, event, %Memory{} = original) do
    drop = Transition.param(transition, :importance_drop)
    floor = Transition.param(transition, :min_importance)

    Memory.new(
      id: heard_memory_id(event),
      character_id: event.to,
      content: "#{event.from} told #{event.to}: #{original.content}",
      importance: max(original.importance - drop, floor),
      created_at: event.at,
      related_characters: Enum.uniq([event.from | original.related_characters]) -- [event.to],
      kind: :heard,
      topic: original.topic,
      source: event.from,
      data: original.data
    )
  end
end
