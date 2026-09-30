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
      refute File.exists?(path <> ".tmp")
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

    test "servers without a journal refuse to compact" do
      server = start_supervised!(RuntimeServer)

      assert {:error, %{code: :invalid_options}} = RuntimeServer.compact_journal(server)
    end
  end
end
