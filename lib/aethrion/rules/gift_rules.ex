defmodule Aethrion.Rules.GiftRules do
  @moduledoc """
  Deterministic rules for gift events.
  """

  alias Aethrion.{Memory, Output, State}

  @affinity_delta 10

  def apply(%State{} = state, %{type: :gift_received} = event) do
    receiver = event.to
    giver = event.from

    memory = %Memory{
      id: "memory:#{receiver}:gift:#{event.item}:#{event.at}",
      character_id: receiver,
      content: "#{giver} gave #{receiver} a #{event.item}.",
      importance: 60,
      created_at: event.at,
      related_characters: [giver]
    }

    state =
      state
      |> State.update_relationship(receiver, giver, fn relationship ->
        %{relationship | affinity: relationship.affinity + @affinity_delta}
      end)
      |> State.add_memory(memory)

    outputs = [
      Output.relationship_changed(receiver, giver, %{affinity: @affinity_delta}),
      Output.memory_created(memory)
    ]

    log = [
      "[Rule] #{name(state, receiver)} affinity toward #{giver} +#{@affinity_delta}",
      "[Memory] #{name(state, receiver)} remembers: \"#{memory.content}\""
    ]

    {state, outputs, log}
  end

  defp name(%State{} = state, character_id) do
    state.characters |> Map.fetch!(character_id) |> Map.fetch!(:name)
  end
end
