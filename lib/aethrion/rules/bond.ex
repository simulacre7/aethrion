defmodule Aethrion.Rules.Bond do
  @moduledoc """
  Names what a relationship has become and announces when that changes.

  A bond is derived from a directed relationship's numbers, in priority order:

  | bond | when |
  | --- | --- |
  | `:estranged` | tension >= 50 or affinity <= -30 |
  | `:strained` | tension >= 20 or trust <= -10 |
  | `:close` | affinity >= 50, trust >= 30, and tension < 10 |
  | `:friendly` | affinity >= 25, trust >= 15, and tension < 10 |
  | `:neutral` | otherwise |

  Bonds settle rather than flicker. Once a relationship has a bond, it keeps
  it until the numbers move `hysteresis` (5) points past the threshold that
  would change it: a close friend stays close until affinity drops below 45,
  and a strained relationship stays strained until tension falls below 15.
  Things getting worse (becoming strained or estranged) still register at
  once, and so does getting closer.

  After every event this reactive rule compares the bond of each relationship
  the event changed before and after, records it on the relationship
  (`Aethrion.Relationship` `:bond`), and emits a `:bond_changed` output when it
  moved, so hosts can react to "Mina and the user became close" without
  watching numbers. Relationships the event did not touch never announce, so
  loading a world does not produce a burst of changes. `derive/2` gives the
  current bond of any relationship.
  """

  use Aethrion.Rule,
    id: :bond,
    description:
      "Announces bond changes: estranged (tension>=50 or affinity<=-30) > strained (tension>=20 or trust<=-10) > close (affinity>=50, trust>=30, tension<10) > friendly (affinity>=25, trust>=15, tension<10) > neutral; a bond holds until 5 points past its threshold.",
    params: [
      estranged_tension: 50,
      estranged_affinity: -30,
      strained_tension: 20,
      strained_trust: -10,
      close_affinity: 50,
      close_trust: 30,
      friendly_affinity: 25,
      friendly_trust: 15,
      hysteresis: 5,
      settled_tension: 10
    ]

  alias Aethrion.{Output, Relationship, State, Transition}

  @bonds [:estranged, :strained, :neutral, :friendly, :close]

  @type bond :: :estranged | :strained | :neutral | :friendly | :close

  @doc "Every bond, from worst to best-established."
  @spec bonds() :: [bond()]
  def bonds, do: @bonds

  @impl true
  def apply(%Transition{state: state} = transition) do
    thresholds = thresholds(state)

    # The trace is newest first, so the last entry per field holds the value
    # before this event.
    befores =
      transition.trace
      |> Enum.filter(&(&1.kind == :relationship))
      |> Enum.reduce(%{}, fn entry, befores ->
        Map.update(befores, entry.target, %{entry.field => entry.before}, fn fields ->
          Map.put(fields, entry.field, entry.before)
        end)
      end)

    befores
    |> Enum.sort()
    |> Enum.reduce(transition, fn {{from, to}, fields}, transition ->
      now = State.get_relationship(state, from, to)
      before = derive(struct(now, fields), thresholds)
      # A relationship touched for the first time has no recorded bond yet;
      # the bond it had before this event is the one to hold on to.
      after_bond = derive(%{now | bond: now.bond || before}, thresholds)

      transition = record(transition, now, after_bond)

      if before == after_bond do
        transition
      else
        line =
          "#{Transition.name(transition, from)} toward #{Transition.name(transition, to)}: #{before} -> #{after_bond}"

        transition
        |> Transition.derived(:bond, from, {from, to}, :bond, before, after_bond,
          detail: line,
          log: "[Bond] #{line}"
        )
        |> Transition.emit(Output.bond_changed(from, to, before, after_bond))
      end
    end)
  end

  defp record(transition, %Relationship{bond: bond}, bond), do: transition

  defp record(transition, %Relationship{from: from, to: to}, bond) do
    Transition.put_state(
      transition,
      State.update_relationship(transition.state, from, to, &%{&1 | bond: bond})
    )
  end

  @doc """
  The bond of a relationship: from its numbers, and from the bond it last had
  (see hysteresis above). Pass the world state to honor its
  `Aethrion.Tuning` overrides; without it the defaults are used.
  """
  @spec derive(Relationship.t(), State.t() | map() | nil) :: bond()
  def derive(relationship, world_or_thresholds \\ nil)

  def derive(%Relationship{} = r, %State{} = world), do: derive(r, thresholds(world))
  def derive(%Relationship{} = r, nil), do: derive(r, Map.new(params()))

  def derive(%Relationship{bond: last} = r, %{} = t) do
    now = from_numbers(r, t)

    if last in [nil, now] or not keeps?(last, now, r, t), do: now, else: last
  end

  # Getting worse into strained or estranged, and getting closer, register at
  # once; easing out of a bad bond or drifting out of a good one needs the
  # margin.
  defp keeps?(last, now, r, t) do
    cond do
      now in [:strained, :estranged] and rank(now) < rank(last) -> false
      last in [:close, :friendly] and rank(now) < rank(last) -> holds?(last, r, t)
      last in [:strained, :estranged] and rank(now) > rank(last) -> holds?(last, r, t)
      true -> false
    end
  end

  defp holds?(:close, r, t),
    do: r.affinity >= t.close_affinity - t.hysteresis and r.trust >= t.close_trust - t.hysteresis

  defp holds?(:friendly, r, t),
    do:
      r.affinity >= t.friendly_affinity - t.hysteresis and
        r.trust >= t.friendly_trust - t.hysteresis

  defp holds?(:strained, r, t),
    do:
      r.tension >= t.strained_tension - t.hysteresis or
        r.trust <= t.strained_trust + t.hysteresis

  defp holds?(:estranged, r, t),
    do:
      r.tension >= t.estranged_tension - t.hysteresis or
        r.affinity <= t.estranged_affinity + t.hysteresis

  defp rank(bond), do: Enum.find_index(@bonds, &(&1 == bond))

  defp from_numbers(%Relationship{} = r, t) do
    cond do
      r.tension >= t.estranged_tension or r.affinity <= t.estranged_affinity -> :estranged
      r.tension >= t.strained_tension or r.trust <= t.strained_trust -> :strained
      r.tension >= t.settled_tension -> :neutral
      r.affinity >= t.close_affinity and r.trust >= t.close_trust -> :close
      r.affinity >= t.friendly_affinity and r.trust >= t.friendly_trust -> :friendly
      true -> :neutral
    end
  end

  @doc "The world's bond thresholds, honoring tuning."
  @spec thresholds(State.t()) :: %{atom() => integer()}
  def thresholds(%State{} = world) do
    Map.new(params(), fn {key, _default} -> {key, Aethrion.Tuning.get(world, __MODULE__, key)} end)
  end
end
