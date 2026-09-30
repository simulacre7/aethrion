defmodule Aethrion.DigestTest do
  use ExUnit.Case, async: true

  import Aethrion.TestHelpers

  alias Aethrion.{Digest, Event, Runtime, State}

  defp digest(events, opts \\ []) do
    {start, opts} = Keyword.pop_lazy(opts, :state, &Runtime.demo_state/0)
    {:ok, state, steps} = Runtime.run(start, events)
    Digest.of(Enum.flat_map(steps, & &1.outputs), state, opts)
  end

  test "bonds are net changes: only where they ended up counts" do
    hostile = &Event.message_sent("user", "mina", &1, tone: :hostile)
    apology = Event.apology_offered("user", "mina", "sorry")

    assert [%{kind: :bond, text: "Mina cooled toward you (now strained)."}] =
             [hostile.("a"), hostile.("b")] |> digest() |> Enum.filter(&(&1.kind == :bond))

    # friendly -> neutral -> strained -> neutral is one net change.
    assert [%{text: "Mina cooled toward you (now neutral)."}] =
             [hostile.("a"), hostile.("b"), apology, apology]
             |> digest()
             |> Enum.filter(&(&1.kind == :bond))

    change =
      &%{type: :bond_changed, from: "mina", to: "user", before: &1, after: &2, event_id: "e1"}

    back = [change.(:friendly, :strained), change.(:strained, :friendly)]
    assert Digest.of(back, Runtime.demo_state()) == []
  end

  test "moods are grouped, and only ones worth telling" do
    # Haru and Yuna are not close enough to keep each other company.
    apart =
      Runtime.demo_state()
      |> State.update_relationship("haru", "yuna", &%{&1 | affinity: 0})
      |> State.update_relationship("yuna", "haru", &%{&1 | affinity: 0})

    items = digest([Event.time_tick("t", hours: 30)], state: apart)

    assert [%{kind: :mood, text: "Haru, Mina, and Yuna are lonely."}] =
             Enum.filter(items, &(&1.kind == :mood))

    assert [%{text: "지금 Haru, Mina, Yuna 모두 외롭다."}] =
             [Event.time_tick("t", hours: 30)]
             |> digest(locale: :ko, state: apart)
             |> Enum.filter(&(&1.kind == :mood))

    # Together, Haru is fine.
    assert [%{text: "지금 Mina와 Yuna 모두 외롭다."}] =
             [Event.time_tick("t", hours: 30)]
             |> digest(locale: :ko)
             |> Enum.filter(&(&1.kind == :mood))
  end

  test "scenes and messages come in order, in either language" do
    events = [flower_for_mina(), Event.time_tick("t", hours: 2)]

    assert [%{kind: :message, event_id: "e2"}, %{kind: :scene, event_id: "e3"} | _] =
             digest(events)

    assert [%{text: "Yuna가 너에게 먼저 연락했다: \"아까 Mina랑 있을 때 즐거워 보이더라. 혹시 나는 잊은 거 아니지?\""} | _] =
             digest(events, locale: :ko)
  end

  test "new beliefs are mentioned" do
    warm = &Event.message_sent("user", "mina", &1, tone: :warm)
    items = digest([warm.("a"), warm.("b"), Event.time_tick("t", hours: 100)])

    assert %{kind: :belief, event_id: "e3", text: "Mina remembers you being warm twice."} in items

    assert %{text: "Mina는 네가 두 번 다정하게 말한 걸 기억한다."} =
             [warm.("a"), warm.("b"), Event.time_tick("t", hours: 100)]
             |> digest(locale: :ko)
             |> Enum.find(&(&1.kind == :belief))
  end

  test "an unsupported locale is an error, not a silent fallback" do
    assert_raise ArgumentError, ~r/unsupported locale :fr/, fn -> digest([], locale: :fr) end
  end

  test "another person can be the one addressed as you" do
    state =
      State.new(
        characters: [character("mina")],
        relationships: [relationship("mina", "alex", affinity: 30, trust: 20)]
      )

    {:ok, step} = Runtime.step(state, Event.message_sent("alex", "mina", "a", tone: :hostile))

    {:ok, step2} =
      Runtime.step(step.state, Event.message_sent("alex", "mina", "b", tone: :hostile))

    assert [%{text: "Mina cooled toward you (now strained)."}] =
             Digest.of(step.outputs ++ step2.outputs, step2.state, you: "alex")
             |> Enum.filter(&(&1.kind == :bond))
  end

  test "reputation beliefs say how someone treats others" do
    hostile = &Event.message_sent("user", &1, "x", tone: :hostile, observed_by: ["haru"])

    items =
      digest([hostile.("mina"), hostile.("yuna"), Event.time_tick("t", hours: 120)])

    assert Enum.any?(
             items,
             &(&1.text == "Haru knows how you treat others: hostile to Mina and Yuna, twice.")
           )

    ko =
      digest([hostile.("mina"), hostile.("yuna"), Event.time_tick("t", hours: 120)], locale: :ko)

    assert Enum.any?(ko, &(&1.text == "Haru는 네가 Mina, Yuna에게 두 번 모질게 말한 걸 안다."))
  end
end
