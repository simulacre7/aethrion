defmodule Aethrion.Relationship do
  @moduledoc """
  Directed relationship values from one actor to another.

  `affinity`, `trust`, and `tension` are bounded to `-100..100`.

  `bond` is the last bond `Aethrion.Rules.Bond` announced for the
  relationship, or `nil` before any event touched it. It is what makes bonds
  settle instead of flickering at a threshold; read the current bond with
  `Aethrion.Rules.Bond.derive/2`.
  """

  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t(),
          affinity: -100..100,
          trust: -100..100,
          tension: -100..100,
          tags: [atom()],
          bond: Aethrion.Rules.Bond.bond() | nil
        }

  @fields [:affinity, :trust, :tension]

  @enforce_keys [:from, :to]
  defstruct [:from, :to, affinity: 0, trust: 0, tension: 0, tags: [], bond: nil]

  @doc "Numeric relationship fields that rules may adjust."
  def fields, do: @fields

  @doc false
  def clamp(%__MODULE__{} = relationship) do
    %{
      relationship
      | affinity: clamp_value(relationship.affinity),
        trust: clamp_value(relationship.trust),
        tension: clamp_value(relationship.tension)
    }
  end

  @doc false
  def clamp_value(value) when value < -100, do: -100
  def clamp_value(value) when value > 100, do: 100
  def clamp_value(value), do: value
end
