defmodule Aethrion.Rules.Ending do
  @moduledoc """
  When the world's clock reaches the story's `deadline`, or any of its
  `decide_when` conditions holds (`Aethrion.Story`), the ending is decided,
  once: the first ending whose
  conditions all hold. It is an `:ending_reached` output with the ending's
  `id`, `title`, `description`, and `because` (its conditions, as they
  stood).
  """

  use Aethrion.Rule,
    id: :ending,
    description:
      "At the story's deadline, the first ending whose conditions hold is reached, once."

  alias Aethrion.{State, Story, Transition}

  @key "story:ending"

  @doc false
  def key, do: @key

  @impl true
  def apply(%Transition{state: state} = transition) do
    cond do
      Map.has_key?(state.cooldowns, @key) -> transition
      due?(state) -> decide(transition, Story.ending(state))
      true -> transition
    end
  end

  # The deadline has come, or something that settles the story happened.
  defp due?(%State{story: story} = state) do
    deadline = Map.get(story, :deadline)

    (deadline != nil and state.clock >= deadline) or
      Enum.any?(Map.get(story, :decide_when, []), &Story.holds?(state, &1))
  end

  defp decide(transition, :none) do
    transition
    |> Transition.put_cooldown(@key)
    |> Transition.note("The story reached its deadline, but no ending matched")
  end

  defp decide(transition, {:ok, ending}) do
    transition
    |> Transition.put_cooldown(@key)
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
end
