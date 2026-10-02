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

  test "mistakes in a hand-written cast are errors with a path" do
    c = fn id -> %{"id" => id, "name" => id} end

    for {data, message} <- [
          {%{"characters" => [c.("a"), c.("a")]}, "used by more than one character"},
          {%{"characters" => [c.("a")], "relationships" => [%{"from" => "elena", "to" => "a"}]},
           "not a character"},
          {%{"characters" => [c.("a")], "relationships" => [%{"from" => "a", "to" => "a"}]},
           "themselves"},
          {%{
             "characters" => [c.("a")],
             "relationships" => [%{"from" => "a", "to" => "user", "affinity" => 250}]
           }, "from -100 to 100"}
        ] do
      assert {:error, %{code: :invalid_state, message: got}} = Aethrion.State.parse(data)
      assert got =~ message
    end
  end
end
