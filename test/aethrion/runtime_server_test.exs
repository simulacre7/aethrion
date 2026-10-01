defmodule Aethrion.RuntimeServerTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers
  import ExUnit.CaptureLog

  alias Aethrion.{Event, Runtime, RuntimeServer, Scheduler, State, World}
  alias Aethrion.Expression.Request

  defmodule EchoAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(%Request{} = request, _opts), do: {:ok, "[llm] " <> request.fallback_text}
  end

  defmodule SlowAdapter do
    @behaviour Aethrion.LLM.Adapter

    @impl true
    def render(_request, opts) do
      Process.sleep(Keyword.get(opts, :sleep, 5_000))
      {:ok, "too late"}
    end
  end

  defmodule KilledAdapter do
    @behaviour Aethrion.LLM.Adapter

    # Simulates a rendering task killed from outside (e.g. out of memory).
    @impl true
    def render(_request, _opts), do: Process.exit(self(), :kill)
  end

  defp jealous_yuna_server(opts) do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    start_supervised!({RuntimeServer, [initial_state: state] ++ opts})
  end

  test "dispatch stores updated state inside the runtime server" do
    server = start_supervised!({RuntimeServer, initial_state: Runtime.demo_state()})

    assert {:ok, next_state, outputs, _log} = RuntimeServer.dispatch(server, flower_for_mina())
    assert RuntimeServer.get_state(server) == next_state
    assert State.get_relationship(next_state, "mina", "user").affinity == 50
    assert Enum.any?(outputs, &(&1.type == :memory_created))
  end

  test "invalid events return structured errors without mutating server state" do
    server = start_supervised!({RuntimeServer, initial_state: Runtime.demo_state()})
    before_state = RuntimeServer.get_state(server)

    assert {:error, %{code: :unknown_character}} =
             RuntimeServer.dispatch(server, Event.gift_received("user", "nobody", "flower"))

    assert RuntimeServer.get_state(server) == before_state
    assert RuntimeServer.history(server) == []
  end

  test "subscribers receive every dispatched step" do
    server = start_supervised!({RuntimeServer, initial_state: Runtime.demo_state()})
    :ok = RuntimeServer.subscribe(server)
    :ok = RuntimeServer.subscribe(server)

    {:ok, step} = RuntimeServer.step(server, flower_for_mina())

    assert_receive {:aethrion, ^server, {:dispatched, ^step}}
    refute_receive {:aethrion, ^server, {:dispatched, _step}}, 50

    :ok = RuntimeServer.unsubscribe(server)
    {:ok, _step} = RuntimeServer.step(server, Event.time_tick("t", hours: 1))
    refute_receive {:aethrion, ^server, _payload}, 50
  end

  test "dead subscribers are dropped" do
    server = start_supervised!({RuntimeServer, initial_state: Runtime.demo_state()})
    subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
    :ok = RuntimeServer.subscribe(server, subscriber)

    ref = Process.monitor(subscriber)
    send(subscriber, :stop)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    assert {:ok, _state, _outputs, _log} = RuntimeServer.dispatch(server, flower_for_mina())
    assert %{subscribers: subscribers} = :sys.get_state(server)
    assert subscribers == %{}
  end

  test "history keeps host events with their ids, bounded by history_limit" do
    server =
      start_supervised!({RuntimeServer, initial_state: Runtime.demo_state(), history_limit: 2})

    for hours <- 1..3, do: RuntimeServer.dispatch(server, Event.time_tick("t", hours: hours))

    assert [%{id: "e2", hours: 2}, %{id: "e3", hours: 3}] = RuntimeServer.history(server)
  end

  test "put_state replaces the state and clears history" do
    server = start_supervised!({RuntimeServer, initial_state: Runtime.demo_state()})
    RuntimeServer.dispatch(server, flower_for_mina())

    :ok = RuntimeServer.put_state(server, Runtime.demo_state())

    assert RuntimeServer.get_state(server) == Runtime.demo_state()
    assert RuntimeServer.history(server) == []
  end

  test "expressive outputs are rendered asynchronously by the adapter" do
    server = jealous_yuna_server(expression: [adapter: EchoAdapter])
    :ok = RuntimeServer.subscribe(server)

    {:ok, step} = RuntimeServer.step(server, Event.time_tick("t2", hours: 2))
    expressive = Enum.filter(step.outputs, &Aethrion.Output.expressive?/1)

    # Dispatch returns deterministic fallback text immediately.
    assert Enum.all?(expressive, &(not String.starts_with?(&1.text, "[llm]")))

    for _output <- expressive do
      assert_receive {:aethrion, ^server, {:expressed, %{expression: %{status: :ok}} = rendered}}
      assert "[llm] " <> _ = rendered.text
    end
  end

  test "slow adapters time out without blocking dispatch" do
    server =
      jealous_yuna_server(
        expression: [adapter: SlowAdapter, adapter_opts: [sleep: 5_000], timeout: 50]
      )

    :ok = RuntimeServer.subscribe(server)

    {elapsed, {:ok, step}} =
      :timer.tc(fn -> RuntimeServer.step(server, Event.time_tick("t2", hours: 2)) end)

    assert elapsed < 1_000_000

    expressive = Enum.filter(step.outputs, &Aethrion.Output.expressive?/1)
    assert length(expressive) > 1

    # Every pending rendering times out and is delivered with its fallback text.
    for _output <- expressive do
      assert_receive {:aethrion, ^server,
                      {:expressed, %{expression: %{status: :fallback, reason: :timeout}} = output}},
                     1_000

      assert output.text == Enum.find(expressive, &(&1.context == output.context)).text
    end

    assert Process.alive?(server)
    assert :sys.get_state(server).pending == %{}

    assert eventually(fn ->
             Task.Supervisor.children(:sys.get_state(server).expression.task_supervisor) == []
           end)
  end

  test "crashing adapters fall back and never crash the runtime" do
    server = jealous_yuna_server(expression: [adapter: KilledAdapter])
    :ok = RuntimeServer.subscribe(server)

    capture_log(fn ->
      {:ok, _step} = RuntimeServer.step(server, Event.time_tick("t2", hours: 2))

      assert_receive {:aethrion, ^server,
                      {:expressed,
                       %{expression: %{status: :fallback, reason: {:crashed, :killed}}}}},
                     1_000
    end)

    assert Process.alive?(server)
    assert {:ok, _state, _outputs, _log} = RuntimeServer.dispatch(server, flower_for_mina())
  end

  test "persistence restores state across restarts" do
    path = Path.join(System.tmp_dir!(), "aethrion-server-#{System.unique_integer()}.json")
    on_exit(fn -> File.rm(path) end)
    persistence = {Aethrion.Persistence.JsonFile, path: path}

    {:ok, first} = RuntimeServer.start_link(persistence: persistence)
    {:ok, state, _outputs, _log} = RuntimeServer.dispatch(first, flower_for_mina())
    GenServer.stop(first)

    {:ok, second} = RuntimeServer.start_link(persistence: persistence)
    assert RuntimeServer.get_state(second) == state
    GenServer.stop(second)
  end

  test "invalid initial state stops the server" do
    Process.flag(:trap_exit, true)

    assert {:error, %{code: :invalid_state, details: %{state: :nope}}} =
             RuntimeServer.start_link(initial_state: :nope)
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

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    assert eventually(fn -> restarted?(name, pid) end)
  end

  test "scheduler emits time_tick events to the runtime server" do
    server = start_supervised!({RuntimeServer, initial_state: Runtime.demo_state()})

    {:ok, _scheduler} =
      Scheduler.start_link(
        runtime: server,
        interval_ms: 10,
        tick_hours: 2,
        now_fun: fn -> "scheduler:test" end,
        notify: self()
      )

    assert_receive {:aethrion, _scheduler, {:scheduler_tick, {:ok, next_state, _outputs, _log}}},
                   1_000

    assert next_state.characters["mina"].state.loneliness == 16
    assert RuntimeServer.get_state(server).clock >= 2
  end

  describe "world" do
    test "a world runs the runtime, scheduler, and expression under one supervisor" do
      name = :"world_#{System.unique_integer([:positive])}"

      start_supervised!(
        {World,
         name: name,
         scheduler: [interval_ms: 20, tick_hours: 1, notify: self()],
         expression: [adapter: EchoAdapter]}
      )

      :ok = World.subscribe(name)
      assert {:ok, _state, _outputs, _log} = World.dispatch(name, flower_for_mina())

      assert_receive {:aethrion, _scheduler, {:scheduler_tick, {:ok, _state, _outputs, _log}}},
                     1_000

      assert World.get_state(name).clock >= 1
      assert [%{type: :gift_received} | _] = World.history(name)
    end

    test "a crashed world runtime resumes from its snapshot" do
      name = :"world_#{System.unique_integer([:positive])}"
      path = Path.join(System.tmp_dir!(), "aethrion-world-#{System.unique_integer()}.json")
      on_exit(fn -> File.rm(path) end)

      start_supervised!(
        {World, name: name, persistence: {Aethrion.Persistence.JsonFile, path: path}}
      )

      {:ok, state, _outputs, _log} = World.dispatch(name, flower_for_mina())
      pid = Process.whereis(World.runtime(name))

      Process.exit(pid, :kill)

      assert eventually(fn -> restarted?(World.runtime(name), pid) end)
      assert World.get_state(name) == state
    end
  end

  defp restarted?(name, old_pid) do
    case Process.whereis(name) do
      nil -> false
      ^old_pid -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    fun.() || (Process.sleep(10) && eventually(fun, attempts - 1))
  end

  defp eventually(_fun, 0), do: false
end
