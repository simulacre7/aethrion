defmodule Aethrion.CharacterState do
  @moduledoc """
  Mutable social and emotional state for a character.
  """

  defstruct mood: :neutral,
            energy: 100,
            loneliness: 0,
            jealousy: 0,
            active?: true,
            blocked?: false,
            last_active_at: nil
end
