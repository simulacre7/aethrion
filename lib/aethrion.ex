defmodule Aethrion do
  @moduledoc """
  A shared social layer for persistent AI characters.

  Aethrion keeps memory, emotion, relationships, and proactive behavior in a
  deterministic runtime. LLM adapters are expression layers, not authorities
  over simulation state.

      iex> state = Aethrion.demo_state()
      iex> event = Aethrion.Event.gift_received("user", "mina", "flower", observed_by: ["yuna"])
      iex> {:ok, state, outputs, _log} = Aethrion.dispatch(state, event)
      iex> state.characters["yuna"].state.mood
      :jealous
      iex> outputs |> Enum.map(& &1.type) |> Enum.frequencies()
      %{memory_created: 2, mood_changed: 2, relationship_changed: 2}

  Start with `Aethrion.Runtime` for the core loop, `Aethrion.Pipeline` for how
  rules are organized, `Aethrion.Expression` for the LLM boundary, and
  `Aethrion.World` for a supervised long-running world.
  """

  alias Aethrion.Runtime

  @doc """
  Dispatches an event through the deterministic runtime.
  See `Aethrion.Runtime.dispatch/3`.
  """
  @spec dispatch(Aethrion.State.t(), Aethrion.Event.t(), keyword()) ::
          {:ok, Aethrion.State.t(), [map()], [String.t()]} | {:error, Aethrion.Error.t()}
  defdelegate dispatch(state, event, opts \\ []), to: Runtime

  @doc """
  Dispatches an event and returns the full `Aethrion.Step` with trace.
  See `Aethrion.Runtime.step/3`.
  """
  @spec step(Aethrion.State.t(), Aethrion.Event.t(), keyword()) ::
          {:ok, Aethrion.Step.t()} | {:error, Aethrion.Error.t()}
  defdelegate step(state, event, opts \\ []), to: Runtime

  @doc """
  Dispatches a list of events in order. See `Aethrion.Runtime.run/3`.
  """
  @spec run(Aethrion.State.t(), [Aethrion.Event.t()], keyword()) ::
          {:ok, Aethrion.State.t(), [Aethrion.Step.t()]} | {:error, Aethrion.Error.t()}
  defdelegate run(state, events, opts \\ []), to: Runtime

  @doc """
  Builds the default demo state with Mina, Yuna, and Haru.
  """
  @spec demo_state() :: Aethrion.State.t()
  defdelegate demo_state(), to: Runtime

  @doc """
  Builds a runtime state from explicit characters and relationships.
  """
  @spec new_state(keyword()) :: Aethrion.State.t()
  defdelegate new_state(opts), to: Aethrion.State, as: :new
end
