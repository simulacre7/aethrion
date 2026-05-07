defmodule Aethrion.Scheduler do
  @moduledoc """
  Small OTP scheduler that emits `time_tick` events to a runtime server.

  The scheduler is intentionally thin. It proves the long-running BEAM shape
  without moving rule authority out of `Aethrion.Runtime.dispatch/2`.
  """

  use GenServer

  alias Aethrion.{Event, RuntimeServer}

  @doc """
  Starts a scheduler.

  Required options:

  - `:runtime` - the `Aethrion.RuntimeServer` target.

  Optional options:

  - `:interval_ms` - tick interval. Defaults to 60 seconds.
  - `:tick_hours` - simulation hours per tick. Defaults to 1.
  - `:now_fun` - zero-arity function used to build event timestamps.
  - `:notify` - pid that receives `{:aethrion_scheduler_tick, result}`.
  - `:name` - optional GenServer name.
  """
  def start_link(opts) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)

    state = %{
      runtime: runtime,
      interval_ms: Keyword.get(opts, :interval_ms, 60_000),
      tick_hours: Keyword.get(opts, :tick_hours, 1),
      now_fun: Keyword.get(opts, :now_fun, &default_now/0),
      notify: Keyword.get(opts, :notify)
    }

    schedule_tick(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    event = Event.time_tick(state.now_fun.(), hours: state.tick_hours)
    result = RuntimeServer.dispatch(state.runtime, event)

    if state.notify do
      send(state.notify, {:aethrion_scheduler_tick, result})
    end

    schedule_tick(state)
    {:noreply, state}
  end

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, state.interval_ms)
  end

  defp default_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
