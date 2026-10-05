defmodule Aethrion.BridgeStoreTest do
  use ExUnit.Case, async: false

  alias Aethrion.Bridge.Store

  @moduletag :tmp_dir

  test "what is kept comes back after a restart, as JSON; a line that cannot be read is skipped",
       %{tmp_dir: dir} do
    path = Path.join(dir, "store.jsonl")
    pid = start_supervised!({Store, name: :store_test, path: path})

    Store.put(:store_test, "a", %{state: [1, 2]})
    Store.put(:store_test, "a", %{state: [1, 2]})
    Store.put(:store_test, "b", :ok)
    _ = :sys.get_state(pid)
    # What comes back is what the file holds: JSON, in this VM too.
    assert Store.get(:store_test, "a") == %{"state" => [1, 2]}
    # The same value twice is written once.
    assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 2

    File.write!(path, "not json\n" <> ~s({"value": "no key"}\n), [:append])
    stop_supervised!(:store_test)
    assert Store.get(:store_test, "a") == nil

    start_supervised!({Store, name: :store_test, path: path})
    assert Store.get(:store_test, "a") == %{"state" => [1, 2]}
    assert Store.get(:store_test, "b") == "ok"
    assert :ets.info(:store_test, :size) == 2
  end

  test "a staged cache keeps its puts back until they are committed, or drops them" do
    pid = start_supervised!({Store, name: :staged_test})
    {cache, commit, discard} = Store.staged(:staged_test)

    cache.put.("a", 1)
    assert cache.get.("a") == 1
    _ = :sys.get_state(pid)
    assert Store.get(:staged_test, "a") == nil

    commit.()
    _ = :sys.get_state(pid)
    assert Store.get(:staged_test, "a") == 1

    {cache, _commit, discard2} = Store.staged(:staged_test)
    cache.put.("b", 2)
    discard2.()
    discard.()
    _ = :sys.get_state(pid)
    assert Store.get(:staged_test, "b") == nil
    assert cache.get.("b") == nil
  end

  test "replace puts a value in place of what was kept, and a restart remembers it", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "store.jsonl")
    pid = start_supervised!({Store, name: :replace_test, path: path})

    Store.put(:replace_test, "a", 1)
    Store.put(:replace_test, "b", 1)
    _ = :sys.get_state(pid)
    assert Store.replace(:replace_test, "a", %{rules: ["x"]}) == :ok
    # Kept by the time it returns; a value of nil forgets.
    assert Store.get(:replace_test, "a") == %{"rules" => ["x"]}
    assert Store.replace(:replace_test, "b", nil) == :ok
    assert Store.all(:replace_test) == [{"a", %{"rules" => ["x"]}}]
    # What is forgotten is gone: the next thing put under the key is kept.
    Store.put(:replace_test, "b", 2)
    assert Store.replace(:replace_test, "c", nil) == :ok
    _ = :sys.get_state(pid)
    assert Store.get(:replace_test, "b") == 2

    stop_supervised!(:replace_test)
    start_supervised!({Store, name: :replace_test, path: path})
    assert Store.get(:replace_test, "a") == %{"rules" => ["x"]}
    assert Store.get(:replace_test, "b") == 2
    assert Store.get(:replace_test, "c") == nil
    # A store that is not running keeps nothing and has nothing.
    assert Store.replace(:not_running, "a", 1) == :ok
    assert Store.all(:not_running) == []
  end

  test "what was kept first stays: an answered turn is not rewritten by a racing one" do
    pid = start_supervised!({Store, name: :first_test})
    Store.put(:first_test, "a", 1)
    Store.put(:first_test, "a", 2)
    _ = :sys.get_state(pid)
    assert Store.get(:first_test, "a") == 1
  end

  test "a store that is not running finds nothing and keeps nothing" do
    cache = Store.cache(:not_started)
    assert cache.put.("a", 1) == :ok
    assert cache.get.("a") == nil
  end
end
