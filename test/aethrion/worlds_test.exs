defmodule Aethrion.WorldsTest do
  # Counts atoms, so nothing else should run alongside.
  use ExUnit.Case, async: false

  alias Aethrion.{Conversation, Event, Runtime, Worlds}

  setup do
    dir = Path.join(System.tmp_dir!(), "aethrion-worlds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp start_worlds(name, opts) do
    start_supervised!({Worlds, [name: name] ++ opts})
    name
  end

  defp hello(text \\ "hi"), do: Event.message_sent("user", "mina", text, tone: :warm)

  test "one world per key, started on first use, without an atom per world", %{dir: dir} do
    worlds =
      start_worlds(Worlds.Test.Keys,
        world: fn key -> [journal: Path.join(dir, "#{key}.jsonl")] end
      )

    assert {:ok, _state, _outputs, _log} = Worlds.dispatch(worlds, "alice", hello())
    assert {:ok, alice} = Worlds.get_state(worlds, "alice")
    assert {:ok, bob} = Worlds.get_state(worlds, "bob")
    assert alice.seq == 1 and bob.seq == 0
    assert Enum.sort(Worlds.running(worlds)) == ["alice", "bob"]

    before = :erlang.system_info(:atom_count)

    for i <- 1..50 do
      {:ok, _state, _outputs, _log} = Worlds.dispatch(worlds, "user-#{i}", hello())
    end

    assert :erlang.system_info(:atom_count) - before < 10
    assert length(Worlds.running(worlds)) == 52
  end

  test "subscribers hear their world, and stay subscribed when it stops and starts", %{dir: dir} do
    worlds =
      start_worlds(Worlds.Test.Subscribe,
        world: fn key -> [journal: Path.join(dir, "#{key}.jsonl")] end
      )

    :ok = Worlds.subscribe(worlds, "alice")
    {:ok, _state, _outputs, _log} = Worlds.dispatch(worlds, "alice", hello())
    assert_receive {:aethrion, {^worlds, "alice"}, {:dispatched, _step}}

    {:ok, _state, _outputs, _log} = Worlds.dispatch(worlds, "bob", hello())
    refute_receive {:aethrion, {^worlds, "bob"}, _payload}, 50

    :ok = Worlds.stop(worlds, "alice")
    assert Worlds.whereis(worlds, "alice") == nil
    {:ok, _state, _outputs, _log} = Worlds.dispatch(worlds, "alice", hello("back"))
    assert_receive {:aethrion, {^worlds, "alice"}, {:dispatched, %{state: %{seq: 2}}}}
  end

  test "idle worlds stop and come back from their journal as they were", %{dir: dir} do
    worlds =
      start_worlds(Worlds.Test.Idle,
        idle_after: 100,
        world: fn key -> [journal: Path.join(dir, "#{key}.jsonl")] end
      )

    {:ok, before, _outputs, _log} = Worlds.dispatch(worlds, "alice", hello("remember me"))

    assert eventually(fn -> Worlds.running(worlds) == [] end)

    assert {:ok, ^before} = Worlds.get_state(worlds, "alice")
    assert [%{text: "remember me"} | _] = Conversation.recent(before, "mina", "user")
  end

  test "world options are checked when a world starts" do
    idle =
      start_worlds(Worlds.Test.NoStorage,
        idle_after: 1_000,
        world: fn _key -> [initial_state: Runtime.demo_state()] end
      )

    assert {:error, %{code: :invalid_options, message: message}} = Worlds.get_state(idle, "a")
    assert message =~ ":journal or :persistence"

    typo = start_worlds(Worlds.Test.Typo, world: fn _key -> [jornal: "x"] end)

    assert {:error, %{code: :invalid_options, message: "unknown world options: [:jornal]"}} =
             Worlds.dispatch(typo, "a", hello())

    assert Worlds.running(typo) == []
  end

  defp eventually(check, tries \\ 50) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(check, tries - 1)
    end
  end
end
