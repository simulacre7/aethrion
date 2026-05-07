defmodule Aethrion.CLI.CommandParserTest do
  use ExUnit.Case, async: true

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
    assert {:ok, :memories} = CommandParser.parse("memories")
    assert {:ok, :help} = CommandParser.parse("help")
    assert {:ok, :quit} = CommandParser.parse("quit")
  end
end
