defmodule Aethrion.Character do
  @moduledoc """
  Persistent character identity plus current social state.
  """

  alias Aethrion.CharacterState

  @enforce_keys [:id, :name]
  defstruct [:id, :name, profile: "", traits: [], state: %CharacterState{}]
end
