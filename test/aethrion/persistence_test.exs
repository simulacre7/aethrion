defmodule Aethrion.PersistenceTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Event, Runtime, State}
  alias Aethrion.Persistence.{InMemory, JsonFile}

  test "in-memory adapter loads caller-provided state" do
    state = Runtime.demo_state()

    assert :ok = InMemory.save(state)
    assert {:ok, ^state} = InMemory.load(state: state)
  end

  test "json file adapter saves and loads state" do
    path = Path.join(System.tmp_dir!(), "aethrion-persistence-#{System.unique_integer()}.json")
    on_exit(fn -> File.rm(path) end)

    {:ok, state, _outputs, _log} =
      Runtime.demo_state()
      |> Runtime.dispatch(Event.gift_received("user", "mina", "flower", observed_by: ["yuna"]))

    assert :ok = JsonFile.save(state, path: path)
    assert {:ok, loaded} = JsonFile.load(path: path)

    assert State.to_data(loaded) == State.to_data(state)
  end

  test "loaded json state can continue a scenario" do
    path = Path.join(System.tmp_dir!(), "aethrion-continue-#{System.unique_integer()}.json")
    on_exit(fn -> File.rm(path) end)

    {:ok, state, _outputs, _log} =
      Runtime.demo_state()
      |> Runtime.dispatch(Event.gift_received("user", "mina", "flower", observed_by: ["yuna"]))

    assert :ok = JsonFile.save(state, path: path)
    assert {:ok, loaded} = JsonFile.load(path: path)

    assert {:ok, continued, outputs, _log} =
             Runtime.dispatch(loaded, Event.time_tick("demo:t2", hours: 2))

    assert continued.characters["yuna"].state.loneliness == 34
    assert Enum.any?(outputs, &(&1.type == :proactive_message))
  end
end
