defmodule Aethrion.PersistenceTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Runtime, State}
  alias Aethrion.Persistence.{InMemory, JsonFile}

  setup do
    path = Path.join(System.tmp_dir!(), "aethrion-persistence-#{System.unique_integer()}.json")
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "in-memory adapter loads caller-provided state" do
    state = Runtime.demo_state()

    assert :ok = InMemory.save(state)
    assert {:ok, ^state} = InMemory.load(state: state)
    assert {:error, %{code: :not_found}} = InMemory.load([])
  end

  test "json file adapter round-trips the full state", %{path: path} do
    {state, _outputs} =
      run!(Runtime.demo_state(), [flower_for_mina(), Event.time_tick("t2", hours: 30)])

    assert :ok = JsonFile.save(state, path: path)
    assert {:ok, loaded} = JsonFile.load(path: path)

    assert loaded == state
    assert loaded.clock == 30
    assert map_size(loaded.cooldowns) > 0
    assert Enum.any?(loaded.memories, &(&1.kind == :heard and &1.source == "yuna"))
  end

  test "loaded json state continues a scenario identically", %{path: path} do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())

    assert :ok = JsonFile.save(state, path: path)
    assert {:ok, loaded} = JsonFile.load(path: path)

    tick = Event.time_tick("t2", hours: 2)
    assert dispatch!(loaded, tick) == dispatch!(state, tick)
  end

  test "v0.1 data is migrated" do
    legacy = %{
      "characters" => [
        %{
          "id" => "yuna",
          "name" => "Yuna",
          "traits" => ["sensitive"],
          "state" => %{"mood" => "neutral", "loneliness" => 30, "jealousy" => 20}
        }
      ],
      "relationships" => [%{"from" => "yuna", "to" => "user", "affinity" => 38}],
      "memories" => [
        %{
          "id" => "memory:yuna:apology:demo:t2",
          "character_id" => "yuna",
          "content" => "user apologized to yuna: sorry",
          "importance" => 70,
          "created_at" => "demo:t2",
          "related_characters" => ["user"]
        }
      ],
      "emitted_proactive" => [%{"character_id" => "yuna", "reason" => "jealous"}]
    }

    state = State.from_data(legacy)

    assert state.clock == 0
    assert character_state(state, "yuna").joy == 0
    assert [%{strength: 70, kind: :experienced}] = state.memories
    assert state.cooldowns == %{"proactive:yuna:jealous" => 0}
  end

  test "malformed v1 proactive records are errors, not crashes" do
    path =
      Path.join(System.tmp_dir!(), "aethrion-v1-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(path) end)

    for emitted <- [[42], [%{"character_id" => 1, "reason" => "jealous"}], [%{}], "yuna"] do
      data = %{"version" => 1, "emitted_proactive" => emitted}

      assert {:error, %Aethrion.Error{code: :invalid_state, message: message}} = State.parse(data)
      assert message =~ "emitted_proactive"

      File.write!(path, Jason.encode!(data))
      assert {:error, %Aethrion.Error{code: :invalid_state}} = JsonFile.load(path: path)
    end
  end

  test "unknown enumerated values fall back instead of creating atoms" do
    data = %{
      "characters" => [
        %{
          "id" => "a",
          "name" => "A",
          "state" => %{"mood" => "definitely-not-a-mood-#{System.unique_integer()}"}
        }
      ]
    }

    assert character_state(State.from_data(data), "a").mood == :neutral
  end

  test "json adapter reports missing paths and files" do
    assert {:error, %{code: :invalid_options}} = JsonFile.save(Runtime.demo_state(), [])
    assert {:error, %{code: :invalid_options}} = JsonFile.load([])
    assert {:error, %{code: :not_found}} = JsonFile.load(path: "/nonexistent/aethrion.json")
  end
end
