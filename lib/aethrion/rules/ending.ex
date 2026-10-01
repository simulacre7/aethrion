defmodule Aethrion.Rules.Ending do
  @moduledoc """
  When the world's clock reaches the story's `deadline`, or any of its
  `decide_when` conditions holds (`Aethrion.Story`), the ending is decided,
  once: the first ending whose conditions all hold. If none does yet, the
  story stays open until one does. It is an `:ending_reached` output with the ending's
  `id`, `title`, `description`, and `because` (its conditions, as they
  stood).
  """

  use Aethrion.Rule,
    id: :ending,
    description:
      "At the story's deadline, the first ending whose conditions hold is reached, once."

  alias Aethrion.{State, Story, Transition}

  @key "story:ending"
  @undecided "story:undecided"

  @doc false
  def key, do: @key

  @impl true
  def apply(%Transition{state: state} = transition) do
    cond do
      Map.has_key?(state.cooldowns, @key) -> transition
      trigger = due(state) -> decide(transition, Story.ending(state), trigger)
      true -> transition
    end
  end

  # Something that settles the story happened, or the deadline has come.
  defp due(%State{story: story} = state) do
    deadline = Map.get(story, :deadline)

    cond do
      Enum.any?(Map.get(story, :decide_when, []), &Story.holds?(state, &1)) -> :decide_when
      deadline != nil and state.clock >= deadline -> :deadline
      true -> nil
    end
  end

  # No ending matches (a story without a catch-all): the story stays open,
  # and the first ending to match later is the one reached. Said once.
  defp decide(%Transition{state: state} = transition, :none, trigger) do
    if Map.has_key?(state.cooldowns, @undecided) do
      transition
    else
      transition
      |> Transition.put_cooldown(@undecided)
      |> Transition.note(
        case trigger do
          :deadline -> "The story reached its deadline, but no ending matched yet"
          :decide_when -> "Something settled the story, but no ending matched yet"
        end
      )
    end
  end

  defp decide(transition, {:ok, ending}, _trigger) do
    transition
    |> Transition.put_cooldown(@key)
    |> Transition.put_cooldown(@key <> ":" <> ending.id)
    |> Transition.emit(%{
      type: :ending_reached,
      ending: ending.id,
      title: ending.title,
      description: ending.description,
      because: ending.because
    })
    |> Transition.log("[Output] Ending: #{ending.title}")
  end

  @doc false
  def reached?(%State{cooldowns: cooldowns}), do: Map.has_key?(cooldowns, @key)

  @doc """
  The ending the story reached, as decided at the time (later changes to the
  numbers do not change it), or `nil`.
  """
  @spec reached(State.t()) :: map() | nil
  def reached(%State{cooldowns: cooldowns, story: story}) do
    prefix = @key <> ":"

    with key when is_binary(key) <-
           Enum.find(Map.keys(cooldowns), &String.starts_with?(&1, prefix)) do
      id = String.replace_prefix(key, prefix, "")
      Enum.find(Map.get(story, :endings, []), &(&1.id == id))
    end
  end
end
