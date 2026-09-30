defmodule Aethrion do
  @moduledoc """
  A shared social layer for persistent AI characters.

  Aethrion keeps memory, emotion, relationships, and proactive behavior in a
  deterministic runtime. LLM adapters are expression layers, not authorities
  over simulation state.

      state = Aethrion.demo_state()
      event = Aethrion.Event.gift_received("user", "mina", "flower", observed_by: ["yuna"])

      {:ok, state, outputs, log} = Aethrion.dispatch(state, event)

  Start with `Aethrion.Runtime` for the core loop, `Aethrion.Pipeline` for how
  rules are organized, `Aethrion.Expression` for the LLM boundary, and
  `Aethrion.World` for a supervised long-running world.
  """

  alias Aethrion.Runtime

  @doc """
  Dispatches an event through the deterministic runtime.
  See `Aethrion.Runtime.dispatch/3`.
  """
  defdelegate dispatch(state, event, opts \\ []), to: Runtime

  @doc """
  Dispatches an event and returns the full `Aethrion.Step` with trace.
  See `Aethrion.Runtime.step/3`.
  """
  defdelegate step(state, event, opts \\ []), to: Runtime

  @doc """
  Dispatches a list of events in order. See `Aethrion.Runtime.run/3`.
  """
  defdelegate run(state, events, opts \\ []), to: Runtime

  @doc """
  Builds the default demo state with Mina, Yuna, and Haru.
  """
  defdelegate demo_state(), to: Runtime

  @doc """
  Builds a runtime state from explicit characters and relationships.
  """
  defdelegate new_state(opts), to: Aethrion.State, as: :new
end
