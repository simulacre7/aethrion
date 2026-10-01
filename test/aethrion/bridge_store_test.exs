defmodule Aethrion.BridgeStoreTest do
  use ExUnit.Case, async: false

  alias Aethrion.Bridge.Store

  @moduletag :tmp_dir

  test "what is kept comes back after a restart; a line that cannot be read is skipped",
       %{tmp_dir: dir} do
    path = Path.join(dir, "store.jsonl")
    pid = start_supervised!({Store, name: :store_test, path: path})

    Store.put(:store_test, "a", %{state: [1, 2]})
    Store.put(:store_test, "a", %{state: [1, 2]})
    Store.put(:store_test, "b", :ok)
    _ = :sys.get_state(pid)
    assert Store.get(:store_test, "a") == %{state: [1, 2]}
    # The same value twice is written once.
    assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 2

    File.write!(path, "not json\n" <> ~s({"key": "c", "value": "@@"}\n), [:append])
    stop_supervised!(:store_test)
    assert Store.get(:store_test, "a") == nil

    start_supervised!({Store, name: :store_test, path: path})
    assert Store.get(:store_test, "a") == %{state: [1, 2]}
    assert Store.get(:store_test, "b") == :ok
    assert Store.get(:store_test, "c") == nil
  end

  test "a store that is not running finds nothing and keeps nothing" do
    cache = Store.cache(:not_started)
    assert cache.put.("a", 1) == :ok
    assert cache.get.("a") == nil
  end
end
