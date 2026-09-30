defmodule Aethrion.SoakTest do
  # A journaled, compacting world that keeps crashing still ends up exactly
  # where the pure core says it should.
  use ExUnit.Case, async: true

  alias Aethrion.{Event, Runtime, World}

  @characters ["mina", "yuna", "haru"]

  defp events(count, seed) do
    :rand.seed(:exsss, {seed, seed + 1, seed + 2})
    pick = &Enum.random/1

    for _ <- 1..count do
      case :rand.uniform(6) do
        1 ->
          Event.gift_received("user", pick.(@characters), "gift",
            observed_by: Enum.take_random(@characters, 2)
          )

        2 ->
          Event.message_sent("user", pick.(@characters), "...",
            tone: pick.([:warm, :neutral, :cold, :hostile]),
            observed_by: Enum.take_random(@characters, 1)
          )

        3 ->
          Event.apology_offered("user", pick.(@characters), "sorry",
            observed_by: Enum.take_random(@characters, 1)
          )

        _ ->
          Event.time_tick("soak", hours: :rand.uniform(30))
      end
    end
  end

  @tag :tmp_dir
  test "crashes and compaction never change where the world ends up", %{tmp_dir: dir} do
    name = :"soak_#{System.unique_integer([:positive])}"
    path = Path.join(dir, "world.jsonl")
    events = events(300, 7)

    start_supervised!({World, name: name, journal: path, journal_compact_every: 23})

    events
    |> Enum.with_index(1)
    |> Enum.each(fn {event, index} ->
      # Events the rules reject are rejected the same way in both runs.
      _result = World.dispatch(name, event)

      if rem(index, 41) == 0 do
        runtime = Process.whereis(World.runtime(name))
        ref = Process.monitor(runtime)
        Process.exit(runtime, :kill)
        assert_receive {:DOWN, ^ref, :process, ^runtime, :killed}, 1_000
        wait_for_restart(name, runtime)
      end
    end)

    expected =
      Enum.reduce(events, Runtime.demo_state(), fn event, state ->
        case Runtime.step(state, event) do
          {:ok, step} -> step.state
          {:error, _error} -> state
        end
      end)

    assert World.state(name) == expected
    assert expected.seq > 300

    # The journal was compacted along the way: far fewer lines than events.
    assert {:ok, _state, remaining} = Aethrion.Journal.read(path)
    assert length(remaining) < 23
  end

  @tag :tmp_dir
  test "a snapshotting world survives the same crashes", %{tmp_dir: dir} do
    name = :"soak_snap_#{System.unique_integer([:positive])}"
    events = events(200, 11)

    start_supervised!(
      {World,
       name: name,
       persistence: {Aethrion.Persistence.JsonFile, path: Path.join(dir, "world.json")}}
    )

    events
    |> Enum.with_index(1)
    |> Enum.each(fn {event, index} ->
      _result = World.dispatch(name, event)

      if rem(index, 37) == 0 do
        runtime = Process.whereis(World.runtime(name))
        Process.exit(runtime, :kill)
        wait_for_restart(name, runtime)
      end
    end)

    expected =
      Enum.reduce(events, Runtime.demo_state(), fn event, state ->
        case Runtime.step(state, event) do
          {:ok, step} -> step.state
          {:error, _error} -> state
        end
      end)

    assert World.state(name) == expected
  end

  defp wait_for_restart(name, old, attempts \\ 50) do
    case Process.whereis(World.runtime(name)) do
      pid when is_pid(pid) and pid != old ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_restart(name, old, attempts - 1)
    end
  end
end
