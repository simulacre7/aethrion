defmodule Aethrion.JournalTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Journal, Runtime, RuntimeServer, Scenario, World}

  setup do
    path =
      Path.join(System.tmp_dir!(), "aethrion-journal-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp journal_events(path, state, events) do
    :ok = Journal.create(path, state)

    Enum.reduce(events, state, fn event, state ->
      {:ok, step} = Runtime.step(state, event)
      :ok = Journal.append(path, step.event)
      step.state
    end)
  end

  test "replaying a journal rebuilds exactly the same world", %{path: path} do
    events = [
      flower_for_mina(),
      Event.message_sent("user", "haru", "thanks", tone: :warm),
      Event.time_tick("t", hours: 30)
    ]

    final = journal_events(path, Runtime.demo_state(), events)

    assert {:ok, ^final, steps} = Journal.replay(path)
    assert Enum.map(steps, & &1.event.id) == ["e1", "e2", "e3"]
    assert Enum.any?(List.last(steps).events, &(&1.type == :gossip_shared))
  end

  test "journals record the version that wrote them and warn when it differs", %{path: path} do
    :ok = Journal.create(path, Runtime.demo_state())
    header = path |> File.read!() |> String.split("\n") |> hd() |> Jason.decode!()
    assert header["aethrion"] == Mix.Project.config()[:version]

    assert ExUnit.CaptureLog.capture_log(fn -> Journal.read(path) end) == ""

    File.write!(path, Jason.encode!(%{header | "aethrion" => "0.1.0"}) <> "\n")

    assert ExUnit.CaptureLog.capture_log(fn -> {:ok, _state, []} = Journal.read(path) end) =~
             ~s(written by Aethrion "0.1.0")
  end

  test "a last line cut short by a crash is dropped, and repaired by a server", %{path: path} do
    final = journal_events(path, Runtime.demo_state(), [flower_for_mina()])
    File.write!(path, ~s({"id": "e9", "type": "time_t), [:append])
    torn = File.read!(path)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, ^final, [_step]} = Journal.replay(path)
      end)

    assert log =~ "dropping an incomplete last line"
    assert File.read!(path) == torn

    ExUnit.CaptureLog.capture_log(fn ->
      server = start_supervised!({RuntimeServer, journal: path})
      assert RuntimeServer.get_state(server) == final
      {:ok, _step} = RuntimeServer.step(server, Event.time_tick("t", hours: 1))
    end)

    # Without the repair the next append would have joined the torn line.
    assert {:ok, _state, [_gift, _tick]} = Journal.replay(path)
  end

  test "journals cannot be created twice", %{path: path} do
    :ok = Journal.create(path, Runtime.demo_state())
    assert {:error, %{code: :already_exists}} = Journal.create(path, Runtime.demo_state())
  end

  test "malformed journals report the line", %{path: path} do
    File.write!(path, "")

    assert {:error, %{code: :invalid_journal, details: %{line: 1, reason: :empty}}} =
             Journal.read(path)

    File.write!(path, ~s({"type": "time_tick", "hours": 1}\n))

    assert {:error, %{code: :invalid_journal, details: %{line: 1, reason: :missing_header}}} =
             Journal.read(path)

    File.rm!(path)
    :ok = Journal.create(path, Runtime.demo_state())
    File.write!(path, ~s({"type": "dance"}\n), [:append])
    assert {:error, %{code: :invalid_journal, details: %{line: 2}}} = Journal.read(path)
  end

  test "a journal that does not match its starting state is detected", %{path: path} do
    journal_events(path, Runtime.demo_state(), [flower_for_mina()])

    # Tamper with the recorded id.
    contents = path |> File.read!() |> String.replace(~s("id":"e1"), ~s("id":"e9"))
    File.write!(path, contents)

    assert {:error,
            %{code: :journal_mismatch, details: %{index: 0, expected: "e9", replayed: "e1"}}} =
             Journal.replay(path)
  end

  test "journals convert to passing scenarios", %{path: path} do
    journal_events(path, Runtime.demo_state(), [flower_for_mina(), Event.time_tick("t", hours: 2)])

    assert {:ok, data} = Journal.to_scenario(path)
    assert {:ok, scenario} = data |> Jason.encode!() |> Jason.decode!() |> Scenario.from_data()
    assert {:ok, result} = Scenario.run(scenario)
    assert Scenario.passed?(result)
  end

  describe "runtime server" do
    test "journals every dispatch and rebuilds on restart", %{path: path} do
      {:ok, first} = RuntimeServer.start_link(journal: path)
      {:ok, _state, _outputs, _log} = RuntimeServer.dispatch(first, flower_for_mina())
      {:ok, state, _outputs, _log} = RuntimeServer.dispatch(first, Event.time_tick("t", hours: 2))
      {:error, _} = RuntimeServer.dispatch(first, Event.gift_received("user", "ghost", "x"))
      GenServer.stop(first)

      assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 3

      {:ok, second} = RuntimeServer.start_link(journal: path)
      assert RuntimeServer.get_state(second) == state

      assert {:error, %{code: :journal_enabled}} =
               RuntimeServer.put_state(second, Runtime.demo_state())

      GenServer.stop(second)
    end

    test "a world restarts from its journal", %{path: path} do
      name = :"journal_world_#{System.unique_integer([:positive])}"
      start_supervised!({World, name: name, journal: path})

      {:ok, state, _outputs, _log} = World.dispatch(name, flower_for_mina())
      pid = Process.whereis(World.runtime(name))
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      assert wait_until(fn ->
               new = Process.whereis(World.runtime(name))
               is_pid(new) and new != pid and Process.alive?(new)
             end)

      assert World.state(name) == state
    end

    test "journal and snapshot persistence cannot be combined", %{path: path} do
      Process.flag(:trap_exit, true)

      assert {:error, %{code: :invalid_options}} =
               RuntimeServer.start_link(
                 journal: path,
                 persistence: {Aethrion.Persistence.JsonFile, path: path <> ".json"}
               )
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) || wait_until(fun, attempts - 1)
    end
  end

  test "the journal task replays and exports", %{path: path} do
    journal_events(path, Runtime.demo_state(), [flower_for_mina(), Event.time_tick("t", hours: 2)])

    report = path <> ".html"
    on_exit(fn -> File.rm(report) end)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Aethrion.Journal.run([path, "--report", report])
      end)

    assert output =~ "2 host events replayed (4 with cascades)"
    assert File.read!(report) =~ "<h2>Timeline</h2>"
  end

  describe "compaction" do
    @events [
      Aethrion.Event.gift_received("user", "mina", "flower", observed_by: ["yuna"]),
      Aethrion.Event.message_sent("user", "haru", "thanks", tone: :warm),
      Aethrion.Event.time_tick("t", hours: 30)
    ]

    test "starts the journal from the replayed state and keeps numbering", %{path: path} do
      final = journal_events(path, Runtime.demo_state(), @events)

      assert {:ok, ^final, 3} = Journal.compact(path)
      assert {:ok, ^final, []} = Journal.read(path)

      # New events continue the ids, and replay agrees with an uncompacted run.
      {:ok, step} = Runtime.step(final, Event.time_tick("t", hours: 5))
      :ok = Journal.append(path, step.event)
      id = "e#{final.seq + 1}"
      assert step.event.id == id
      assert {:ok, state, [%{event: %{id: ^id}}]} = Journal.replay(path)
      assert state == step.state
      assert Path.wildcard(path <> ".*tmp") == []
    end

    test "can archive the old journal first", %{path: path} do
      archive = path <> ".archive"
      on_exit(fn -> File.rm(archive) end)
      final = journal_events(path, Runtime.demo_state(), @events)
      old = File.read!(path)

      assert {:ok, ^final, 3} = Journal.compact(path, archive: archive)
      assert File.read!(archive) == old

      # An existing archive is never overwritten, and the journal is untouched.
      compacted = File.read!(path)
      assert {:error, %{code: :already_exists}} = Journal.compact(path, archive: archive)
      assert File.read!(path) == compacted
    end

    test "a journal that does not replay is left alone", %{path: path} do
      :ok = Journal.create(path, Runtime.demo_state())
      File.write!(path, ~s({"id": "e9", "type": "time_tick", "hours": 1}\n), [:append])
      before = File.read!(path)

      assert {:error, %{code: :journal_mismatch}} = Journal.compact(path)
      assert File.read!(path) == before
    end

    test "a running server compacts without losing events", %{path: path} do
      server = start_supervised!({RuntimeServer, journal: path}, id: :first)
      for event <- @events, do: {:ok, _step} = RuntimeServer.step(server, event)

      assert :ok = RuntimeServer.compact_journal(server)
      assert {:ok, _state, []} = Journal.read(path)

      {:ok, _step} = RuntimeServer.step(server, Event.time_tick("t", hours: 2))
      live = RuntimeServer.get_state(server)
      stop_supervised!(:first)

      restarted = start_supervised!({RuntimeServer, journal: path}, id: :second)
      assert RuntimeServer.get_state(restarted) == live
    end

    test "a world can compact its journal every n events", %{path: path} do
      name = :"compacting_#{System.unique_integer([:positive])}"
      start_supervised!({World, name: name, journal: path, journal_compact_every: 2}, id: :w1)

      for hours <- 1..5, do: {:ok, _step} = World.step(name, Event.time_tick("t", hours: hours))

      # Compacted after events 2 and 4; event 5 is the only one left.
      assert {:ok, _state, [%{type: :time_tick, hours: 5}]} = Journal.read(path)
      live = World.state(name)
      stop_supervised!(:w1)

      start_supervised!({World, name: name, journal: path}, id: :w2)
      assert World.state(name) == live
    end

    test "servers without a journal refuse to compact" do
      server = start_supervised!(RuntimeServer)

      assert {:error, %{code: :invalid_options}} = RuntimeServer.compact_journal(server)
    end

    test "a journal that changes while compacting is left alone", %{path: path} do
      final = journal_events(path, Runtime.demo_state(), @events)

      # Simulate a server appending between the replay and the rewrite.
      {:ok, step} = Runtime.step(final, Event.time_tick("t", hours: 1))
      line = Journal.encode(step.event) |> elem(1)

      pipeline =
        Aethrion.Pipeline.default()
        |> Aethrion.Pipeline.add_reactive(__MODULE__.AppendOnce)

      :persistent_term.put({__MODULE__, :append}, {path, line})
      on_exit(fn -> :persistent_term.erase({__MODULE__, :append}) end)

      assert {:error, %{code: :journal_changed}} = Journal.compact(path, pipeline: pipeline)
      assert {:ok, _state, events} = Journal.read(path)
      assert length(events) == 4
      assert Path.wildcard(path <> ".*tmp") == []
    end

    test "a journal whose tuning names rules outside the pipeline is refused", %{path: path} do
      state = %{Runtime.demo_state() | tuning: %{warmth_test: %{amount: 3}}}
      :ok = Journal.create(path, state)
      before = File.read!(path)

      assert {:error, %{code: :invalid_options, message: message}} = Journal.compact(path)
      assert message =~ "compact with the pipeline the world runs with"
      assert File.read!(path) == before
    end
  end

  defmodule AppendOnce do
    # A reactive rule that appends to the journal being compacted, once, while
    # it is replayed: a stand-in for a server that is still running.
    use Aethrion.Rule, id: :append_once_test, description: "Test rule."

    @impl true
    def apply(transition) do
      case :persistent_term.get({Aethrion.JournalTest, :append}, nil) do
        {path, line} ->
          :persistent_term.erase({Aethrion.JournalTest, :append})
          File.write!(path, line <> "\n", [:append])

        nil ->
          :ok
      end

      transition
    end
  end
end
