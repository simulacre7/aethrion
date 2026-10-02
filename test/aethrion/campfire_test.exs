defmodule Aethrion.CampfireTest do
  # The campfire cast, played through the chat-app bridge as a player
  # would: what one does early on changes who does what in the fight.
  use ExUnit.Case, async: true

  alias Aethrion.{Bridge, State}

  defp cast do
    {:ok, state} =
      "priv/casts/campfire.json" |> File.read!() |> Jason.decode!() |> State.parse()

    state
  end

  # Plays the lines one request at a time; returns every turn's outputs
  # and the last world.
  defp play(lines) do
    read =
      Bridge.reader(
        [interpreter: Aethrion.Interpreter.Rules],
        %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}
      )

    {_messages, outputs, now} =
      Enum.reduce(lines, {[], [], nil}, fn line, {messages, outputs, _now} ->
        messages = messages ++ [%{"role" => "user", "content" => line}]
        {_all, chat} = Bridge.transcript(messages)
        {_before, now, turn} = Bridge.replay(cast(), chat, read, to: "sera")
        reply = %{"role" => "assistant", "content" => "…\n\n" <> Bridge.status(now, turn, :ko)}
        {messages ++ [reply], outputs ++ turn.outputs, now}
      end)

    {outputs, now}
  end

  @fight [
    "도윤, 왜 그렇게 조용해?",
    "고블린 두목을 공격한다!",
    "고블린 두목을 다시 벤다",
    "고블린 척후를 벤다",
    "고블린 궁수를 벤다",
    "고블린 궁수를 다시 벤다"
  ]

  test "a gift seen by a jealous friend gets around, and makes Sera shield the player" do
    {outputs, now} = play(["세라, 목걸이 사 왔어. 선물이야" | @fight])

    assert Enum.any?(
             outputs,
             &match?(
               %{type: :character_interaction, kind: :gossip, character_id: "doyun", to: "harin"},
               &1
             )
           )

    assert Enum.any?(
             outputs,
             &match?(%{type: :combat, kind: :protected, character_id: "sera", to: "user"}, &1)
           )

    assert Enum.any?(
             outputs,
             &match?(%{type: :combat, character_id: "sera", advantage: true}, &1)
           )

    # Harin came back in time to fight, and the night ends with four.
    assert Enum.any?(outputs, &match?(%{type: :combat, character_id: "harin"}, &1))
    assert %{id: "four"} = Aethrion.Rules.Ending.reached(now)
  end

  test "without the gift, Sera does not care enough to take the blows" do
    {outputs, _now} = play(["세라, 오늘 밤 조용하네" | @fight])
    refute Enum.any?(outputs, &match?(%{type: :combat, kind: :protected}, &1))
    refute Enum.any?(outputs, &match?(%{type: :character_interaction, kind: :gossip}, &1))
  end

  describe "from a review" do
    test "a world where Sera shielded the player saves and reads back, and a trimmed chat goes on from it" do
      start_supervised!({Aethrion.Bridge.Store, name: Aethrion.Bridge.Checkpoints})
      checkpoints = Aethrion.Bridge.Store.cache(Aethrion.Bridge.Checkpoints)

      read =
        Bridge.reader(
          [interpreter: Aethrion.Interpreter.Rules],
          %{get: fn _key -> nil end, put: fn _key, _value -> :ok end}
        )

      replay = fn messages ->
        {_all, chat} = Bridge.transcript(messages)
        result = Bridge.replay(cast(), chat, read, to: "sera", checkpoints: checkpoints)
        _ = :sys.get_state(Aethrion.Bridge.Checkpoints)
        result
      end

      messages =
        Enum.reduce(["세라, 목걸이 사 왔어. 선물이야" | @fight], [], fn line, messages ->
          messages = messages ++ [%{"role" => "user", "content" => line}]
          {_before, now, turn} = replay.(messages)
          assert {:ok, _state} = State.parse(State.to_data(now))

          messages ++
            [%{"role" => "assistant", "content" => "…\n\n" <> Bridge.status(now, turn, :ko)}]
        end)

      next = [%{"role" => "user", "content" => "세라, 고마워"}]
      {_before, full, _turn} = replay.(messages ++ next)
      {_before, trimmed, _turn} = replay.([List.last(messages)] ++ next)
      assert State.to_data(trimmed) == State.to_data(full)
    end

    test "a healer who is away does not heal when asked" do
      state = %{
        cast()
        | stats: cast().stats |> put_in(["sera", "away"], 3) |> put_in(["user", "hp"], 5)
      }

      event = Aethrion.Combat.action(state, "user", nil, "세라, 치료해 줘")
      assert {:error, %{message: message}} = Aethrion.Runtime.step(state, event)
      assert message =~ "away"
      refute "sera" in Aethrion.Interpreter.schema(state, "user", "sera").healers
    end
  end
end
