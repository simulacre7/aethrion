defmodule Aethrion.Character do
  @moduledoc """
  Persistent character identity plus current social state.

  Traits are plain atoms that rules may read as modifiers. The built-in rules
  understand `:sensitive`, `:calm`, `:playful`, and `:talkative`; unknown traits
  are kept as descriptive data for expression adapters.
  """

  alias Aethrion.CharacterState

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          profile: String.t(),
          traits: [atom()],
          state: CharacterState.t()
        }

  @enforce_keys [:id, :name]
  defstruct [:id, :name, profile: "", traits: [], state: %CharacterState{}]

  @doc "Returns true when the character has `trait`."
  def trait?(%__MODULE__{traits: traits}, trait), do: trait in traits

  @doc "Returns true when the character may initiate outputs."
  def can_act?(%__MODULE__{state: state}), do: state.active? and not state.blocked?
end
