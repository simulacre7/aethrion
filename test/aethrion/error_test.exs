defmodule Aethrion.ErrorTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Error, Journal, Scenario, State}
  alias Aethrion.Persistence.JsonFile

  doctest Aethrion.Error
  doctest Aethrion
  doctest Aethrion.Explain
  doctest Aethrion.Intent
  doctest Aethrion.Digest

  describe "format/1" do
    test "adds every location the details carry" do
      assert Error.format(Error.new(:invalid_journal, "bad line", %{line: 3})) ==
               "bad line (line 3)"

      assert Error.format(Error.new(:invalid_scenario, "not a string", %{path: ["events", 1]})) ==
               "not a string (at events.1)"

      assert Error.format(Error.new(:invalid_state, "broken", %{path: []})) == "broken"
      assert Error.format(Error.new(:not_found, "missing")) == "missing"
      assert Error.location(Error.new(:invalid_journal, "x", %{line: 2})) == "line 2"
    end
  end

  test "file errors name the file under :file and format without crashing" do
    assert {:error, %Error{code: :not_found, details: %{file: "/nope.jsonl"}} = error} =
             Journal.read("/nope.jsonl")

    assert Error.format(error) == "no journal at /nope.jsonl"
    assert Error.format(Error.new(:io_error, "odd", %{path: "/a/string"})) == "odd"
  end

  test "tasks report missing files instead of crashing" do
    for task <- [Mix.Tasks.Aethrion.Journal, Mix.Tasks.Aethrion.Report] do
      assert_raise Mix.Error, ~r/no (journal|scenario) at \/nope/, fn ->
        ExUnit.CaptureIO.capture_io(fn -> task.run(["/nope.json"]) end)
      end
    end
  end

  test "a hand-built event without a receiver says which field is missing" do
    assert {:error, %Error{code: :invalid_event, details: %{field: :to}, message: message}} =
             Aethrion.Runtime.dispatch(Aethrion.demo_state(), %{
               type: :gift_received,
               from: "user",
               item: "x"
             })

    assert message == "to must be a character id, got: nil"
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
