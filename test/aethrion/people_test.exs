defmodule Aethrion.PeopleTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Event, Runtime}
  alias Aethrion.Rules.Proactive

  # Two people, "alex" and "sam", and three characters.
  defp world do
    state(
      [
        character("mina"),
        character("yuna", traits: [:sensitive], state: [loneliness: 30]),
        character("haru", traits: [:playful])
      ],
      [
        relationship("yuna", "alex", affinity: 40),
        relationship("yuna", "sam", affinity: 50),
        relationship("yuna", "haru", affinity: 25, trust: 40),
        relationship("haru", "yuna", affinity: 30, trust: 35),
        relationship("haru", "alex", affinity: 10),
        relationship("mina", "sam", affinity: 20)
      ]
    )
  end

  test "people are the non-characters a character relates to, closest first" do
    assert Proactive.people(world(), "yuna") == ["sam", "alex"]
    assert Proactive.people(world(), "haru") == ["alex"]
  end

  test "a world without people addresses the user" do
    state = state([character("a")])
    assert Proactive.people(state, "a") == ["user"]
  end

  test "jealousy reaches out to whoever gave the gift, not the closest person" do
    # Jealousy (15) plus loneliness (30) crosses the threshold right away.
    {_state, outputs} =
      dispatch!(world(), Event.gift_received("alex", "mina", "ring", observed_by: ["yuna"]))

    assert [%{reason: :jealous, to: "alex", text: "You looked happy with Mina earlier." <> _}] =
             proactive(outputs, "yuna")
  end

  test "loneliness reaches out to the closest person" do
    state = Aethrion.State.update_character_state(world(), "yuna", &%{&1 | loneliness: 70})
    {_state, outputs} = dispatch!(state, Event.time_tick("t", hours: 1))

    assert [%{reason: :lonely, to: "sam"}] = proactive(outputs, "yuna")
  end

  test "curiosity asks the person the news is about" do
    {state, _outputs} =
      dispatch!(world(), Event.gift_received("alex", "mina", "ring", observed_by: ["yuna"]))

    {_state, outputs} =
      dispatch!(state, Event.gossip_shared("yuna", "haru", "memory:yuna:observed:e1"))

    assert [%{reason: :curious, to: "alex", text: "Yuna told me you gave Mina a ring. Smooth."}] =
             proactive(outputs, "haru")
  end

  test "characters do not reach out to people they feel tense toward" do
    state =
      world()
      |> Aethrion.State.update_relationship("yuna", "sam", &%{&1 | tension: 20})
      |> Aethrion.State.update_character_state("yuna", &%{&1 | loneliness: 70})

    {_state, outputs} = dispatch!(state, Event.time_tick("t", hours: 1))

    assert [%{reason: :lonely, to: "alex"}] = proactive(outputs, "yuna")
  end

  test "the demo world is unchanged: everything goes to the user" do
    {state, _outputs} = dispatch!(Runtime.demo_state(), flower_for_mina())
    {_state, outputs} = dispatch!(state, Event.time_tick("t", hours: 2))

    assert Enum.all?(of_type(outputs, :proactive_message), &(&1.to == "user"))
  end
end
