defmodule Aethrion.Rules.ReconciliationRules do
  @moduledoc """
  Deterministic reconciliation rules.
  """

  alias Aethrion.{Memory, Output, State}

  @trust_delta 8
  @jealousy_delta -15
  @loneliness_delta -6

  def apply_apology(%State{} = state, %{type: :apology_offered} = event) do
    receiver = event.to
    apologizer = event.from

    memory = %Memory{
      id: "memory:#{receiver}:apology:#{event.at}",
      character_id: receiver,
      content: "#{apologizer} apologized to #{receiver}: #{event.reason}",
      importance: 70,
      created_at: event.at,
      related_characters: [apologizer]
    }

    state =
      state
      |> State.update_character_state(receiver, fn character_state ->
        %{
          character_state
          | jealousy: max(character_state.jealousy + @jealousy_delta, 0),
            loneliness: max(character_state.loneliness + @loneliness_delta, 0)
        }
      end)
      |> State.update_relationship(receiver, apologizer, fn relationship ->
        %{relationship | trust: relationship.trust + @trust_delta}
      end)
      |> State.add_memory(memory)

    outputs = [
      Output.relationship_changed(receiver, apologizer, %{trust: @trust_delta}),
      Output.memory_created(memory)
    ]

    receiver_name = name(state, receiver)

    log = [
      "[Rule] #{receiver_name} accepted an apology from #{apologizer}",
      "[State] #{receiver_name} jealousy #{@jealousy_delta}",
      "[State] #{receiver_name} loneliness #{@loneliness_delta}",
      "[Rule] #{receiver_name} trust toward #{apologizer} +#{@trust_delta}",
      "[Memory] #{receiver_name} remembers: \"#{memory.content}\""
    ]

    {state, outputs, log}
  end

  defp name(%State{} = state, character_id) do
    state.characters |> Map.fetch!(character_id) |> Map.fetch!(:name)
  end
end
