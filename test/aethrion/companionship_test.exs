defmodule Aethrion.CompanionshipTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Runtime, State}

  defp lonely_pair(affinity) do
    state(
      [
        character("ana", state: [loneliness: 60]),
        character("ben", state: [loneliness: 10]),
        character("cy", state: [loneliness: 10])
      ],
      [
        relationship("ana", "ben", affinity: affinity),
        relationship("ana", "cy", affinity: affinity - 5)
      ]
    )
  end

  test "a lonely character spends time with the friend they like most" do
    {:ok, step} = Runtime.step(lonely_pair(40), Event.time_tick("t", hours: 1))

    assert [_tick, %{type: :time_spent_together, from: "ana", to: "ben", cause: "e1"}] =
             step.events

    assert character_state(step.state, "ana").loneliness == 62 - 20
    assert character_state(step.state, "ben").joy == 6
    assert State.get_relationship(step.state, "ben", "ana").affinity == 2
    assert [%{kind: :together}] = of_type(step.outputs, :character_interaction)

    assert Enum.count(step.state.memories, &(&1.data["event"] == "time_spent_together")) == 2
  end

  test "no outing without a close enough friend" do
    {:ok, step} = Runtime.step(lonely_pair(29), Event.time_tick("t", hours: 1))
    assert [_tick] = step.events
  end

  test "outings with the same friend are rate limited" do
    {state, _outputs} = dispatch!(lonely_pair(40), Event.time_tick("t", hours: 1))
    state = State.update_character_state(state, "ana", &%{&1 | loneliness: 80})

    {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 1))
    assert [_tick, %{type: :time_spent_together, to: "cy"}] = step.events

    {:ok, step} = Runtime.step(step.state, Event.time_tick("t", hours: 1))
    assert [_tick] = step.events
  end

  test "each character joins at most one outing per tick" do
    state =
      state(
        [
          character("a", state: [loneliness: 60]),
          character("b", state: [loneliness: 60]),
          character("c")
        ],
        [
          relationship("a", "c", affinity: 50),
          relationship("b", "c", affinity: 50),
          relationship("b", "a", affinity: 40)
        ]
      )

    {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 1))

    assert [_tick, %{from: "a", to: "c"}] = step.events
  end

  test "blocked friends are skipped and cannot be invited directly" do
    state = State.update_character_state(lonely_pair(40), "ben", &%{&1 | blocked?: true})
    {:ok, step} = Runtime.step(state, Event.time_tick("t", hours: 1))

    assert [_tick, %{to: "cy"}] = step.events

    assert {:error, %{code: :unavailable_character}} =
             Runtime.dispatch(state, Event.time_spent_together("ana", "ben"))
  end

  test "repeated outings consolidate into an impression" do
    events =
      for _ <- 1..3 do
        [Event.time_spent_together("ana", "ben"), Event.time_tick("t", hours: 60)]
      end
      |> List.flatten()

    {state, _outputs} = run!(lonely_pair(40), events ++ [Event.time_tick("t", hours: 200)])

    assert Enum.any?(
             state.memories,
             &(&1.kind == :impression and &1.content =~ "has spent time with")
           )
  end
end
