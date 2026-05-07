defmodule Aethrion do
  @moduledoc """
  A shared social layer for persistent AI characters.

  Aethrion keeps memory, emotion, relationships, and proactive behavior in a
  deterministic runtime. LLM adapters are expression layers, not authorities
  over simulation state.
  """

  alias Aethrion.Runtime

  @doc """
  Dispatches an event through the deterministic runtime.
  """
  defdelegate dispatch(state, event), to: Runtime

  @doc """
  Builds the default demo state with Mina, Yuna, and Haru.
  """
  defdelegate demo_state(), to: Runtime

  @doc """
  Builds a runtime state from explicit characters and relationships.
  """
  defdelegate new_state(opts), to: Aethrion.State, as: :new
end
