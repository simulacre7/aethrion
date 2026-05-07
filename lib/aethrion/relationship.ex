defmodule Aethrion.Relationship do
  @moduledoc """
  Directed relationship values from one actor to another.
  """

  @enforce_keys [:from, :to]
  defstruct [:from, :to, affinity: 0, trust: 0, tension: 0, tags: []]

  def clamp(%__MODULE__{} = relationship) do
    %{
      relationship
      | affinity: clamp_value(relationship.affinity),
        trust: clamp_value(relationship.trust),
        tension: clamp_value(relationship.tension)
    }
  end

  defp clamp_value(value) when value < -100, do: -100
  defp clamp_value(value) when value > 100, do: 100
  defp clamp_value(value), do: value
end
