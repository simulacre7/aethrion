defmodule Aethrion.RuntimeServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Aethrion.{Event, Runtime, RuntimeServer, Scheduler, State}

  test "dispatch stores updated state inside the runtime server" do
    {:ok, server} = RuntimeServer.start_link(initial_state: Runtime.demo_state())

    event = Event.gift_received("user", "mina", "flower", observed_by: ["yuna"])

    assert {:ok, next_state, outputs, _log} = RuntimeServer.dispatch(server, event)
    assert RuntimeServer.get_state(server) == next_state
    assert State.get_relationship(next_state, "mina", "user").affinity == 50
    assert Enum.any?(outputs, &(&1.type == :memory_created))
  end

  test "invalid events return structured errors without mutating server state" do
    {:ok, server} = RuntimeServer.start_link(initial_state: Runtime.demo_state())

    before_state = RuntimeServer.get_state(server)

    assert {:error, %{code: :unknown_character}} =
             RuntimeServer.dispatch(server, Event.gift_received("user", "nobody", "flower"))

    assert RuntimeServer.get_state(server) == before_state
  end

  test "runtime server can be supervised and restarted" do
    name = :"runtime_server_#{System.unique_integer([:positive])}"

    {:ok, _supervisor} =
      Supervisor.start_link(
        [{RuntimeServer, initial_state: Runtime.demo_state(), name: name}],
        strategy: :one_for_one
      )

    pid = Process.whereis(name)
    ref = Process.monitor(pid)

    capture_log(fn ->
      catch_exit(RuntimeServer.crash(name))
      assert_receive {:DOWN, ^ref, :process, ^pid, {%RuntimeError{}, _stack}}, 1_000
    end)

    assert eventually(fn -> restarted?(name, pid) end)
  end

  test "scheduler emits time_tick events to the runtime server" do
    {:ok, server} = RuntimeServer.start_link(initial_state: Runtime.demo_state())

    {:ok, _scheduler} =
      Scheduler.start_link(
        runtime: server,
        interval_ms: 10,
        tick_hours: 2,
        now_fun: fn -> "scheduler:test" end,
        notify: self()
      )

    assert_receive {:aethrion_scheduler_tick, {:ok, next_state, _outputs, _log}}, 1_000
    assert next_state.characters["mina"].state.loneliness == 20
    assert RuntimeServer.get_state(server).characters["mina"].state.loneliness == 20
  end

  defp restarted?(name, old_pid) do
    case Process.whereis(name) do
      nil -> false
      ^old_pid -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    fun.() || (Process.sleep(10) && eventually(fun, attempts - 1))
  end

  defp eventually(_fun, 0), do: false
end
