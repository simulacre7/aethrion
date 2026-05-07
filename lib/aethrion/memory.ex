defmodule Aethrion.Memory do
  @moduledoc """
  A deterministic memory record created by runtime rules.
  """

  @enforce_keys [:id, :character_id, :content, :importance, :created_at]
  defstruct [:id, :character_id, :content, :importance, :created_at, related_characters: []]
end
