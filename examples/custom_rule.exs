# mix run examples/custom_rule.exs
#
# Add your own rule and your own event type to the pipeline.

defmodule Example.Rules.Rivalry do
  use Aethrion.Rule,
    id: :rivalry,
    description: "Mina grows tense toward anyone else who receives a gift."

  alias Aethrion.Transition

  @impl true
  def apply(%Transition{event: %{to: to}} = transition) when to != "mina" do
    Transition.adjust_relationship(transition, "mina", to, :tension, 6)
  end

  def apply(transition), do: transition
end

defmodule Example.Rules.Festival do
  use Aethrion.Rule,
    id: :festival,
    description: "A festival lifts everyone's spirits and eases loneliness."

  alias Aethrion.{State, Transition}

  @impl true
  def apply(%Transition{} = transition) do
    transition.state
    |> State.sorted_characters()
    |> Enum.reduce(transition, fn character, transition ->
      transition
      |> Transition.adjust_character(character.id, :joy, 25)
      |> Transition.adjust_character(character.id, :loneliness, -15)
    end)
    |> Transition.note("The festival lifts everyone's spirits")
  end
end

alias Aethrion.{Event, Pipeline, Runtime}

pipeline =
  Pipeline.default()
  |> Pipeline.append(:gift_received, Example.Rules.Rivalry)
  |> Pipeline.append(:festival, Example.Rules.Festival)

state = Runtime.demo_state()

{:ok, state, _outputs, log} =
  Runtime.dispatch(state, Event.gift_received("user", "yuna", "ribbon"), pipeline: pipeline)

IO.puts("== gift to Yuna, with the rivalry rule")
Enum.each(log, &IO.puts/1)

{:ok, _state, _outputs, log} = Runtime.dispatch(state, %{type: :festival}, pipeline: pipeline)

IO.puts("\n== a custom :festival event")
Enum.each(log, &IO.puts/1)
