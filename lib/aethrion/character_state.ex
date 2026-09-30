defmodule Aethrion.CharacterState do
  @moduledoc """
  Social and emotional state for a character.

  Numeric fields are bounded to `0..100`. `mood` is not set directly by hosts;
  `Aethrion.Rules.Mood` derives it from the numeric fields after every event.
  """

  @type mood :: :neutral | :happy | :lonely | :jealous | :upset

  @type t :: %__MODULE__{
          mood: mood(),
          energy: 0..100,
          loneliness: 0..100,
          jealousy: 0..100,
          joy: 0..100,
          stress: 0..100,
          active?: boolean(),
          blocked?: boolean(),
          last_active_at: String.t() | nil
        }

  @moods [:neutral, :happy, :lonely, :jealous, :upset]
  @numeric_fields [:energy, :loneliness, :jealousy, :joy, :stress]

  defstruct mood: :neutral,
            energy: 100,
            loneliness: 0,
            jealousy: 0,
            joy: 0,
            stress: 0,
            active?: true,
            blocked?: false,
            last_active_at: nil

  @doc "Moods the runtime can derive."
  def moods, do: @moods

  @doc "Numeric fields that rules may adjust."
  def numeric_fields, do: @numeric_fields

  @doc "Moods that signal the character is struggling socially."
  def distressed?(mood), do: mood in [:lonely, :jealous, :upset]

  @doc false
  def clamp(value) when value < 0, do: 0
  def clamp(value) when value > 100, do: 100
  def clamp(value), do: value
end
