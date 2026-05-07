defmodule Aethrion.RuntimeServer do
  @moduledoc """
  Supervised stateful wrapper around the deterministic runtime.

  `Aethrion.Runtime.dispatch/2` remains the authoritative simulation core.
  This server only owns long-running state and delegates event handling to that
  deterministic function.
  """

  use GenServer

  alias Aethrion.{Runtime, State}

  @type server :: GenServer.server()

  @doc """
  Starts a runtime server.

  Options:

  - `:initial_state` - an `Aethrion.State` struct. Defaults to the demo state.
  - `:name` - optional GenServer name.
  """
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Dispatches an event and stores the updated state on success.
  """
  def dispatch(server, event) do
    GenServer.call(server, {:dispatch, event})
  end

  @doc """
  Returns the current runtime state.
  """
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc false
  def crash(server) do
    GenServer.call(server, :crash)
  end

  @impl true
  def init(opts) do
    initial_state = Keyword.get(opts, :initial_state, Runtime.demo_state())

    if match?(%State{}, initial_state) do
      {:ok, initial_state}
    else
      {:stop, {:invalid_initial_state, initial_state}}
    end
  end

  @impl true
  def handle_call({:dispatch, event}, _from, state) do
    case Runtime.dispatch(state, event) do
      {:ok, next_state, outputs, log} ->
        {:reply, {:ok, next_state, outputs, log}, next_state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:crash, _from, _state) do
    raise "intentional RuntimeServer crash"
  end
end
