defmodule Aethrion.Rule do
  @moduledoc """
  Behaviour for deterministic simulation rules.

  A rule receives an `Aethrion.Transition` for the event being processed and
  returns it, usually after calling tracked helpers such as
  `Aethrion.Transition.adjust_character/5`. Rules must be pure: the same
  transition in must always produce the same transition out. They must not
  perform I/O, read the clock, or use randomness.

  Which rules run for which event is decided by `Aethrion.Pipeline`, not by the
  rule itself.

      defmodule MyGame.Rules.Rivalry do
        use Aethrion.Rule,
          id: :rivalry,
          description: "Rivals grow tense when either receives a gift."

        alias Aethrion.Transition

        @impl true
        def apply(%Transition{event: event} = transition) do
          Transition.adjust_relationship(transition, "rival", event.to, :tension, 5)
        end
      end
  """

  alias Aethrion.Transition

  @doc "Stable identifier recorded in traces and outputs."
  @callback id() :: atom()

  @doc "One sentence describing what the rule does."
  @callback description() :: String.t()

  @doc "Applies the rule to the transition for the current event."
  @callback apply(Transition.t()) :: Transition.t()

  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)
    description = Keyword.fetch!(opts, :description)

    quote do
      @behaviour Aethrion.Rule

      @impl Aethrion.Rule
      def id, do: unquote(id)

      @impl Aethrion.Rule
      def description, do: unquote(description)
    end
  end
end
