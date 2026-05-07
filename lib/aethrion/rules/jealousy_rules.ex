defmodule Aethrion.Rules.JealousyRules do
  @moduledoc """
  Deterministic jealousy and social observation rules.
  """

  alias Aethrion.{Output, State}
  alias Aethrion.LLM.FakeAdapter

  @jealousy_delta 15
  @tension_delta 8
  @threshold 45

  def apply_observers(%State{} = state, %{type: :gift_received, observed_by: observers} = event) do
    Enum.reduce(observers, {state, [], []}, fn observer, {state, outputs, log} ->
      state =
        state
        |> State.update_character_state(observer, fn character_state ->
          %{character_state | jealousy: min(character_state.jealousy + @jealousy_delta, 100)}
        end)
        |> State.update_relationship(observer, event.to, fn relationship ->
          %{relationship | tension: relationship.tension + @tension_delta}
        end)

      observer_name = name(state, observer)
      receiver_name = name(state, event.to)

      next_outputs = [
        Output.relationship_changed(observer, event.to, %{tension: @tension_delta}) | outputs
      ]

      next_log =
        log ++
          [
            "[Rule] #{observer_name} noticed the gift to #{receiver_name}",
            "[State] #{observer_name} jealousy +#{@jealousy_delta}",
            "[State] #{observer_name} tension toward #{receiver_name} +#{@tension_delta}"
          ]

      {state, next_outputs, next_log}
    end)
    |> then(fn {state, outputs, log} -> {state, Enum.reverse(outputs), log} end)
  end

  def apply_thresholds(%State{} = state) do
    Enum.reduce(state.characters, {state, [], []}, fn {character_id, character},
                                                      {state, outputs, log} ->
      reason = :jealous
      already_emitted? = State.proactive_emitted?(state, character_id, reason)

      social_pressure = character.state.jealousy + character.state.loneliness

      if can_message?(character) and social_pressure >= @threshold and not already_emitted? do
        text = FakeAdapter.proactive_message(character_id, reason)

        state = State.mark_proactive_emitted(state, character_id, reason)

        output = Output.proactive_message(character_id, "user", reason, text)
        line = "[Output] #{character.name} -> user: \"#{text}\""

        {state, [output | outputs], [line | log]}
      else
        {state, outputs, log}
      end
    end)
    |> then(fn {state, outputs, log} -> {state, Enum.reverse(outputs), Enum.reverse(log)} end)
  end

  defp can_message?(character) do
    character.state.active? and not character.state.blocked?
  end

  defp name(%State{} = state, character_id) do
    state.characters |> Map.fetch!(character_id) |> Map.fetch!(:name)
  end
end
