defmodule Aethrion.Rules.Activity do
  @moduledoc """
  A character spends time on an activity from the world's story
  (`Aethrion.Story`): its effects change their stats (`"intelligence"`,
  `"charm"`, anything) and their feelings (`energy`, `loneliness`,
  `jealousy`, `joy`, `stress`, kept within 0..100).

  The event is `Aethrion.Event.activity(character, name)`; validation
  rejects activities the story does not have. Stats stay at 0 or more.
  """

  use Aethrion.Rule,
    id: :activity,
    description:
      "A character does an activity from the story: its effects change their stats and feelings."

  alias Aethrion.{CharacterState, State, Transition}

  @feelings Enum.map(CharacterState.numeric_fields(), &Atom.to_string/1)

  @impl true
  def apply(%Transition{event: event, state: state} = transition) do
    character = Map.get(event, :character)
    name = Map.get(event, :activity)
    effects = state.story |> Map.get(:activities, %{}) |> Map.get(name)

    cond do
      not State.character?(state, character) ->
        Transition.note(transition, "No character #{inspect(character)} to do #{inspect(name)}")

      effects == nil ->
        Transition.note(transition, "The story has no activity #{inspect(name)}")

      true ->
        effects
        |> Enum.sort()
        |> Enum.reduce(transition, fn
          {field, delta}, transition when field in @feelings ->
            Transition.adjust_character(
              transition,
              character,
              String.to_existing_atom(field),
              delta
            )

          {stat, delta}, transition ->
            Transition.adjust_stat(transition, character, stat, delta, min: 0)
        end)
        |> Transition.note("#{Transition.name(transition, character)} spent time on #{name}")
    end
  end
end
