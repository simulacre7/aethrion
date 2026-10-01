# mix run examples/companion_week.exs
#
# A companion app over ten days with the demo cast. The user talks to Mina
# most mornings, gives her something small, says one thing they regret and
# apologizes, then goes quiet for five days. What each character says along
# the way is printed as it happens; on the user's return, the app shows a
# "while you were away" digest in English and Korean.

alias Aethrion.{Digest, Event, Runtime, State}
alias Aethrion.Rules.Bond

say = fn text, tone -> Event.message_sent("user", "mina", text, tone: tone) end
morning = fn hours -> Event.time_tick("next morning", hours: hours) end

week =
  [
    say.("Morning! Did you sleep well?", :warm),
    morning.(24),
    say.("That idea of yours worked, thank you.", :warm),
    Event.gift_received("user", "mina", "notebook"),
    morning.(24),
    say.("Busy day. Talk later.", :neutral),
    morning.(24),
    say.("Can you not? I'm tired of this.", :hostile),
    morning.(6),
    Event.apology_offered("user", "mina", "I was rude this morning. I'm sorry."),
    morning.(18),
    say.("Morning. Still friends?", :warm),
    morning.(24)
  ]

away = [morning.(24), morning.(24), morning.(24), morning.(24), morning.(24)]

play = fn state, events ->
  Enum.reduce(events, {state, []}, fn event, {state, outputs} ->
    {:ok, step} = Runtime.step(state, event)

    for output <- step.outputs do
      case output do
        %{type: :character_interaction, text: text} ->
          IO.puts("  (#{text})")

        %{type: type, character_id: id, to: "user", text: text}
        when type in [:reply, :proactive_message] ->
          IO.puts("  #{State.name(step.state, id)}: #{text}")

        _other ->
          :ok
      end
    end

    {step.state, outputs ++ step.outputs}
  end)
end

bond = fn state -> state |> State.get_relationship("mina", "user") |> Bond.derive(state) end

IO.puts("== A week with Mina")
{state, _outputs} = play.(Runtime.demo_state(), week)
IO.puts("  (Mina toward you: #{bond.(state)})")

IO.puts("\n== Five days away")
{state, while_away} = play.(state, away)

IO.puts("\n== Back again")
{state, _outputs} = play.(state, [say.("I'm back! Sorry I disappeared.", :warm)])
IO.puts("  (Mina toward you: #{bond.(state)})")

IO.puts("\n== While you were away")
for item <- Digest.of(while_away, state), do: IO.puts("  - " <> item.text)

IO.puts("\n== 네가 없는 동안")
for item <- Digest.of(while_away, state, locale: :ko), do: IO.puts("  - " <> item.text)
