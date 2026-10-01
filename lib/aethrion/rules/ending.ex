defmodule Aethrion.Rules.Ending do
  @moduledoc """
  When the world's clock reaches the story's `deadline`
  (`Aethrion.Story`), the ending is decided, once: the first ending whose
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
    deadline = Map.get(state.story, :deadline)

    cond do
      deadline == nil or state.clock < deadline -> transition
      Map.has_key?(state.cooldowns, @key) -> transition
      true -> decide(transition, Story.ending(state))
    end
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
