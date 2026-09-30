defmodule Aethrion.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Aethrion.{Event, Expression, Memory, Runtime, State}
  alias Aethrion.Rules.Mood

  @characters ["mina", "yuna", "haru"]
  @actors ["user" | @characters]

  defp event_gen do
    one_of([
      gen all(
            from <- member_of(@actors),
            to <- member_of(@characters),
            item <- member_of(["flower", "book", "tea", "ring"]),
            observers <- list_of(member_of(@characters), max_length: 3)
          ) do
        Event.gift_received(from, to, item, observed_by: observers)
      end,
      gen all(
            from <- member_of(@actors),
            to <- member_of(@characters),
            tone <- member_of(Event.tones())
          ) do
        Event.message_sent(from, to, "...", tone: tone)
      end,
      gen all(to <- member_of(@characters)) do
        Event.apology_offered("user", to, "sorry")
      end,
      gen all(from <- member_of(@actors), to <- member_of(@characters)) do
        Event.comfort_offered(from, to)
      end,
      gen all(hours <- integer(1..30)) do
        Event.time_tick("prop", hours: hours)
      end
    ])
  end

  defp run(events) do
    Enum.reduce(events, {Runtime.demo_state(), [], 0}, fn event, {state, outputs, processed} ->
      case Runtime.step(state, event) do
        {:ok, step} ->
          {step.state, outputs ++ step.outputs, processed + length(step.events)}

        {:error, %Aethrion.Error{}} ->
          {state, outputs, processed}
      end
    end)
  end

  property "state stays within bounds and mood matches the numbers" do
    check all(events <- list_of(event_gen(), max_length: 40)) do
      {state, _outputs, processed} = run(events)

      assert state.seq == processed

      for character <- Map.values(state.characters),
          field <- Aethrion.CharacterState.numeric_fields() do
        assert Map.fetch!(character.state, field) in 0..100
      end

      for character <- Map.values(state.characters) do
        assert character.state.mood == Mood.derive(character.state)
      end

      for relationship <- Map.values(state.relationships),
          field <- Aethrion.Relationship.fields() do
        assert Map.fetch!(relationship, field) in -100..100
      end

      for memory <- state.memories do
        assert %Memory{} = memory
        assert memory.strength in 0..memory.importance
      end

      assert state.memories |> Enum.map(& &1.id) |> Enum.uniq() |> length() ==
               length(state.memories)
    end
  end

  property "the same events always produce the same result" do
    check all(events <- list_of(event_gen(), max_length: 30)) do
      assert run(events) == run(events)
    end
  end

  property "invalid events never change state" do
    check all(
            events <- list_of(event_gen(), max_length: 20),
            bad <-
              member_of([
                Event.gift_received("user", "ghost", "rock"),
                Event.message_sent("mina", "mina", "hi"),
                Event.time_tick("t", hours: -1),
                %{type: :unknown}
              ])
          ) do
      {state, _outputs, _processed} = run(events)
      assert {:error, _} = Runtime.dispatch(state, bad)
    end
  end

  property "persistence round-trips any reachable state" do
    check all(events <- list_of(event_gen(), max_length: 30)) do
      {state, _outputs, _processed} = run(events)
      data = state |> State.to_data() |> Jason.encode!() |> Jason.decode!()

      assert State.from_data(data) == state
    end
  end

  property "follow-up events always point at an earlier event" do
    check all(events <- list_of(event_gen(), max_length: 30)) do
      Enum.reduce(events, Runtime.demo_state(), fn event, state ->
        case Runtime.step(state, event) do
          {:ok, step} ->
            ids = Enum.map(step.events, & &1.id)

            for {event, index} <- Enum.with_index(step.events), index > 0 do
              assert event.cause in Enum.take(ids, index)
            end

            step.state

          {:error, _error} ->
            state
        end
      end)
    end
  end

  property "expression rendering only changes text" do
    check all(events <- list_of(event_gen(), max_length: 20)) do
      {_state, outputs, _processed} = run(events)
      rendered = Expression.render(outputs)

      assert Enum.map(rendered, &Map.delete(&1, :expression)) == outputs
    end
  end
end
