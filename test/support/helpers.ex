defmodule Aethrion.TestHelpers do
  @moduledoc false

  import ExUnit.Assertions

  alias Aethrion.{Character, CharacterState, Event, Relationship, Runtime, State}

  @doc "Dispatches an event that must succeed; returns `{state, outputs}`."
  def dispatch!(state, event, opts \\ []) do
    assert {:ok, state, outputs, _log} = Runtime.dispatch(state, event, opts)
    {state, outputs}
  end

  @doc "Dispatches events in order; returns `{state, all_outputs}`."
  def run!(state, events, opts \\ []) do
    Enum.reduce(events, {state, []}, fn event, {state, outputs} ->
      {state, next_outputs} = dispatch!(state, event, opts)
      {state, outputs ++ next_outputs}
    end)
  end

  @doc "The shared setup of the demo drama: the user gives Mina a flower while Yuna watches."
  def flower_for_mina(at \\ "test:t1") do
    Event.gift_received("user", "mina", "flower", observed_by: ["yuna"], at: at)
  end

  def of_type(outputs, type), do: Enum.filter(outputs, &(&1.type == type))

  def proactive(outputs, character_id) do
    outputs |> of_type(:proactive_message) |> Enum.filter(&(&1.character_id == character_id))
  end

  def character_state(state, id), do: state.characters[id].state

  @doc "Builds a minimal character."
  def character(id, opts \\ []) do
    %Character{
      id: id,
      name: Keyword.get(opts, :name, String.capitalize(id)),
      traits: Keyword.get(opts, :traits, []),
      state: struct(CharacterState, Keyword.get(opts, :state, []))
    }
  end

  def relationship(from, to, values \\ []) do
    struct(Relationship, [from: from, to: to] ++ values)
  end

  def state(characters, relationships \\ []) do
    State.new(characters: characters, relationships: relationships)
  end
end
