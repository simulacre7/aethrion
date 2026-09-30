defmodule Aethrion.ErrorTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Error, Journal, Scenario, State}
  alias Aethrion.Persistence.JsonFile

  doctest Aethrion.Error
  doctest Aethrion
  doctest Aethrion.Explain

  describe "format/1" do
    test "adds every location the details carry" do
      assert Error.format(Error.new(:invalid_journal, "bad line", %{line: 3})) ==
               "bad line (line 3)"

      assert Error.format(Error.new(:invalid_scenario, "not a string", %{path: ["events", 1]})) ==
               "not a string (at events.1)"

      assert Error.format(Error.new(:invalid_state, "broken", %{path: []})) == "broken"
      assert Error.format(Error.new(:not_found, "missing")) == "missing"
    end
  end

  test "a scenario name of null falls back to the default" do
    assert {:ok, scenario} =
             Scenario.from_data(%{"name" => nil, "description" => nil, "events" => []})

    assert scenario.name == "Untitled scenario"
    assert scenario.description == ""
  end

  @tag :tmp_dir
  test "saving a state that is not valid JSON returns an Aethrion error", %{tmp_dir: dir} do
    state = Aethrion.demo_state()
    state = put_in(state.characters["mina"].name, <<0xFF>>)

    assert {:error, %Error{code: :invalid_state}} =
             JsonFile.save(state, path: Path.join(dir, "state.json"))
  end

  test "a journal rejection reports the inner error's message, not a struct" do
    assert {:error, %Error{message: message}} =
             Journal.encode(%{type: :gift_received, from: "user", to: "nobody", item: 3})

    refute message =~ "%Aethrion.Error"
  end

  test "State.to_data output survives the default JSON encoder" do
    assert {:ok, _json} = Jason.encode(State.to_data(Aethrion.demo_state()))
  end
end
