defmodule Aethrion.Rules.Bond do
  @moduledoc """
  Names what a relationship has become and announces when that changes.

  A bond is derived from a directed relationship's numbers, in priority order:

  | bond | when |
  | --- | --- |
  | `:estranged` | tension >= 50 or affinity <= -30 |
  | `:strained` | tension >= 20 or trust <= -10 |
  | `:close` | affinity >= 60 and trust >= 50 |
  | `:friendly` | affinity >= 25 and trust >= 15 |
  | `:neutral` | otherwise |

  Bonds are not stored: `derive/2` computes them from any relationship. After
  every event this reactive rule compares the bond of each relationship the
  event changed before and after, and emits a `:bond_changed` output when it
  moved, so hosts can react to "Mina and the user became close" without
  watching numbers. Relationships the event did not touch never announce, so
  loading a world does not produce a burst of changes.
  """

  use Aethrion.Rule,
    id: :bond,
    description:
      "Announces bond changes: estranged (tension>=50 or affinity<=-30) > strained (tension>=20 or trust<=-10) > close (affinity>=60, trust>=50) > friendly (affinity>=25, trust>=15) > neutral.",
    params: [
      estranged_tension: 50,
      estranged_affinity: -30,
      strained_tension: 20,
      strained_trust: -10,
      close_affinity: 60,
      close_trust: 50,
      friendly_affinity: 25,
      friendly_trust: 15
    ]

  alias Aethrion.{Output, Relationship, State, Transition}

  @bonds [:estranged, :strained, :close, :friendly, :neutral]

  @doc "Every bond, from worst to best-established."
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
      after_bond = derive(now, thresholds)

      if before == after_bond do
        transition
      else
        transition
        |> Transition.note(
          "#{Transition.name(transition, from)} toward #{Transition.name(transition, to)}: #{before} -> #{after_bond}",
          subject: from,
          log: "Bond"
        )
        |> Transition.emit(Output.bond_changed(from, to, before, after_bond))
      end
    end)
  end

  @doc """
  The bond of a relationship. Pass the world state to honor its
  `Aethrion.Tuning` overrides; without it the defaults are used.
  """
  def derive(relationship, world_or_thresholds \\ nil)

  def derive(%Relationship{} = r, %State{} = world), do: derive(r, thresholds(world))
  def derive(%Relationship{} = r, nil), do: derive(r, Map.new(params()))

  def derive(%Relationship{} = r, %{} = t) do
    cond do
      r.tension >= t.estranged_tension or r.affinity <= t.estranged_affinity -> :estranged
      r.tension >= t.strained_tension or r.trust <= t.strained_trust -> :strained
      r.affinity >= t.close_affinity and r.trust >= t.close_trust -> :close
      r.affinity >= t.friendly_affinity and r.trust >= t.friendly_trust -> :friendly
      true -> :neutral
    end
  end

  @doc "The world's bond thresholds, honoring tuning."
  def thresholds(%State{} = world) do
    Map.new(params(), fn {key, _default} -> {key, Aethrion.Tuning.get(world, __MODULE__, key)} end)
  end
end
