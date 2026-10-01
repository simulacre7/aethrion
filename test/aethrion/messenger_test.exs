defmodule Aethrion.MessengerTest do
  use ExUnit.Case, async: true

  alias Aethrion.{Conversation, Event, Replies, Runtime, State}
  alias Aethrion.Expression.{Request, Templates.Ko}

  defp academy do
    {:ok, state} = "priv/casts/academy.json" |> File.read!() |> Jason.decode!() |> State.parse()
    state
  end

  defp run(state, events) do
    Enum.reduce(events, {state, []}, fn event, {state, outputs} ->
      {:ok, step} = Runtime.step(state, event)
      {step.state, outputs ++ step.outputs}
    end)
  end

  test "a bond story unlocks once, with the student messaging first, and the story goes on" do
    warm = &Event.message_sent("user", "hana", &1, tone: :warm)

    {state, outputs} =
      run(academy(), [
        warm.("어제 만든 거 정말 대단하더라!"),
        Event.time_tick("later", hours: 8),
        warm.("덕분에 수업 준비가 금방 끝났어."),
        Event.time_tick("later", hours: 8),
        warm.("오늘도 고생 많았어.")
      ])

    assert [%{milestone: "hana-1", character_id: "hana", to: "user", text: text}] =
             for(%{type: :milestone_reached} = o <- outputs, do: o)

    assert text =~ "선생님!"
    assert Aethrion.Rules.Milestone.reached(state) == ["hana-1"]
    refute Aethrion.Rules.Ending.reached?(state)

    # Her first message is in the conversation, as a message she sent.
    assert Enum.any?(
             Conversation.recent(state, "hana", "user"),
             &(&1.from == "hana" and &1.text == text)
           )
  end

  test "milestones are checked like endings" do
    for {milestone, message} <- [
          {%{"id" => "a"}, "needs conditions"},
          {%{"id" => "a", "from" => "hana", "when" => [%{"clock" => true, "at_least" => 1}]},
           "from and says go together"},
          {%{"id" => "a", "when" => [%{"bond" => ["nobody", "user"], "is" => "close"}]},
           "not a character"}
        ] do
      data = academy() |> State.to_data() |> put_in(["story", "milestones"], [milestone])
      assert {:error, %{message: got}} = State.parse(data)
      assert got =~ message
    end
  end

  test "reply choices follow what the student last said, and carry their tone" do
    state = academy()
    assert [%{tone: :warm}, %{tone: :neutral}, %{tone: :cold}] = Replies.suggest(state, "hana")

    {state, _} =
      run(state, [Event.message_sent("user", "hana", "오늘 방과 후에 뭐 해?", tone: :neutral)])

    choices = Replies.suggest(state, "hana")
    assert Enum.map(choices, & &1.tone) == [:warm, :neutral, :cold]
    assert Replies.suggest(state, "hana") == choices
  end

  test "a polite student writes to 선생님 in 존댓말" do
    request = %Request{kind: :reply, speaker: %{traits: [:polite]}}
    polite = &Ko.polite(&1, request)

    assert polite.("나 주는 거야? 고마워!") == "저 주는 거예요? 고마워요!"
    assert polite.("너 진짜 최고야, 알지?") == "선생님 진짜 최고예요, 알죠?"
    assert polite.("반지? 우와, 고마워!") == "반지? 우와, 고마워요!"
    assert polite.("...응, 왜.") == "...네, 왜요."
    assert Ko.polite("고마워.", %Request{kind: :reply, speaker: %{traits: [:calm]}}) == "고마워."
  end
end
