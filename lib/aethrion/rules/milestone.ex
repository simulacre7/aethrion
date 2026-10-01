defmodule Aethrion.Rules.Milestone do
  @moduledoc """
  A story's `milestones` (`Aethrion.Story`): moments a relationship unlocks
  as it grows, the way a messenger game opens a character's next bond story
  when the bond reaches a new rank. Each is reached once, the first time
  its conditions hold; unlike an ending, the story goes on.

      "milestones": [
        {"id": "hana-1", "title": "인연 스토리: 고장 난 오르골",
         "from": "hana", "says": "선생님! 혹시 오늘 방과 후에 시간 있어요?",
         "when": [{"bond": ["hana", "user"], "at_least": "friendly"}]}
      ]

  It is a `:milestone_reached` output with the milestone's `id`, `title`,
  `description`, and `because`; with `from` and `says`, the character
  messages the person first (`character_id`, `to`, `text`), and the line is
  kept in their conversation.
  """

  use Aethrion.Rule,
    id: :milestone,
    description: "When a story milestone's conditions first hold, it is reached, once."

  alias Aethrion.{Story, Transition}

  @doc false
  def key(id), do: "story:milestone:" <> id

  @impl true
  def apply(%Transition{state: state} = transition) do
    state.story
    |> Map.get(:milestones, [])
    |> Enum.reject(&Map.has_key?(state.cooldowns, key(&1.id)))
    |> Enum.filter(&Enum.all?(&1.when, fn condition -> Story.holds?(state, condition) end))
    |> Enum.reduce(transition, &reach(&2, &1))
  end

  defp reach(%Transition{state: state} = transition, milestone) do
    output =
      %{
        type: :milestone_reached,
        milestone: milestone.id,
        title: milestone.title,
        description: milestone.description,
        because: Enum.map(milestone.when, &Story.describe(state, &1))
      }
      |> Map.merge(
        if milestone.from,
          do: %{character_id: milestone.from, to: milestone.to, text: milestone.says},
          else: %{}
      )

    transition
    |> Transition.put_cooldown(key(milestone.id))
    |> Transition.emit(output)
    |> Transition.log("[Output] Milestone: #{milestone.title}")
  end

  @doc "The ids of the milestones reached so far."
  @spec reached(Aethrion.State.t()) :: [String.t()]
  def reached(state) do
    for milestone <- Map.get(state.story, :milestones, []),
        Map.has_key?(state.cooldowns, key(milestone.id)),
        do: milestone.id
  end
end
