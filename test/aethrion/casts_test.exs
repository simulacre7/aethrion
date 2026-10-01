defmodule Aethrion.CastsTest do
  use ExUnit.Case, async: true

  # Bundled casts are what `mix aethrion.serve --cast` starts from.
  for path <- Path.wildcard("priv/casts/*.json") do
    test "#{Path.basename(path)} loads, and its characters have a voice" do
      assert {:ok, state} =
               unquote(path) |> File.read!() |> Jason.decode!() |> Aethrion.State.parse()

      assert map_size(state.characters) > 0
      assert Enum.all?(Map.values(state.characters), &(&1.voice != ""))
    end
  end
end
