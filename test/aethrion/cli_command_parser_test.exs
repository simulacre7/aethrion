defmodule Aethrion.CLI.CommandParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aethrion.CLI.CommandParser

  test "parses gift command" do
    assert {:ok,
            %{
              type: :gift_received,
              from: "user",
              to: "mina",
              item: "flower",
              observed_by: []
            }} = CommandParser.parse("gift user mina flower")
  end

  test "parses gift command with observers" do
    assert {:ok, %{observed_by: ["yuna", "haru"]}} =
             CommandParser.parse("gift user mina flower observed_by yuna,haru")
  end

  test "parses tick command" do
    assert {:ok, %{type: :time_tick, hours: 2}} = CommandParser.parse("tick 2")
  end

  test "parses apology command" do
    assert {:ok,
            %{
              type: :apology_offered,
              from: "user",
              to: "yuna",
              reason: "I should have checked in too"
            }} = CommandParser.parse("apologize user yuna I should have checked in too")
  end

  test "rejects invalid tick command" do
    assert {:error, _message} = CommandParser.parse("tick nope")
  end

  test "parses control commands" do
    assert {:ok, :status} = CommandParser.parse("status")
    assert {:ok, {:memories, nil}} = CommandParser.parse("memories")
    assert {:ok, {:memories, "yuna"}} = CommandParser.parse("memories yuna")
    assert {:ok, {:why, "yuna"}} = CommandParser.parse("why yuna")
    assert {:ok, {:context, "haru"}} = CommandParser.parse("context haru")
    assert {:ok, :timeline} = CommandParser.parse("timeline")
    assert {:ok, :rules} = CommandParser.parse("rules")
    assert {:ok, :undo} = CommandParser.parse("undo")
    assert {:ok, {:save, "tmp/a.json"}} = CommandParser.parse("save tmp/a.json")
    assert {:ok, {:load, "tmp/a.json"}} = CommandParser.parse("load tmp/a.json")
    assert {:ok, {:record, "tmp/s.json"}} = CommandParser.parse("record tmp/s.json")
    assert {:ok, {:report, "tmp/s.html"}} = CommandParser.parse("report tmp/s.html")
    assert {:ok, :help} = CommandParser.parse("help")
    assert {:ok, :quit} = CommandParser.parse("quit")
  end

  test "parses free text for intent interpretation" do
    assert {:ok, {:say, "yuna", "sorry about earlier"}} =
             CommandParser.parse("say yuna sorry about earlier")

    assert {:error, _message} = CommandParser.parse("say yuna")
  end

  test "parses messages with a tone" do
    assert {:ok,
            %{type: :message_sent, from: "user", to: "mina", tone: :warm, text: "you did great"}} =
             CommandParser.parse("message user mina warm you did great")

    assert {:error, "tone must be one of: " <> _} =
             CommandParser.parse("message user mina smug hi")
  end

  test "parses comfort" do
    assert {:ok, %{type: :comfort_offered, from: "haru", to: "yuna"}} =
             CommandParser.parse("comfort haru yuna")
  end

  property "never raises, whatever is typed" do
    words =
      ~w(gift say message why context tick comfort apologize save load record report memories
         status undo user mina yuna yuna->haru -> trust jealousy warm smug observed_by a,b,, 0 -1 quit)

    check all(
            tokens <-
              list_of(one_of([member_of(words), string(:printable, max_length: 5)]),
                max_length: 6
              ),
            max_runs: 500
          ) do
      line = Enum.join(tokens, " ")

      assert match?({:ok, _}, CommandParser.parse(line)) or
               match?({:error, _}, CommandParser.parse(line))
    end
  end
end
