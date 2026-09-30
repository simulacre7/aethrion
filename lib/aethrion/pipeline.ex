defmodule Aethrion.Pipeline do
  @moduledoc """
  Explicit, ordered mapping from event types to rules.

  For each event the runtime runs:

  1. the event rules registered for the event's type, in order
  2. the reactive rules, in order, for every event

  Reactive rules re-evaluate derived state (mood) and thresholds (proactive
  messages) no matter what caused the change.

  The default pipeline is visible with `mix aethrion.rules`. Hosts can build
  their own:

      pipeline =
        Aethrion.Pipeline.default()
        |> Aethrion.Pipeline.append(:gift_received, MyGame.Rules.Rivalry)

      Aethrion.Runtime.dispatch(state, event, pipeline: pipeline)
  """

  alias Aethrion.Rules

  @type t :: %__MODULE__{
          event_rules: %{optional(atom()) => [module()]},
          reactive_rules: [module()]
        }

  defstruct event_rules: %{}, reactive_rules: []

  @doc """
  The built-in rule pipeline.
  """
  def default do
    %__MODULE__{
      event_rules: %{
        gift_received: [Rules.Gift, Rules.Observation],
        message_sent: [Rules.Message, Rules.Reply],
        apology_offered: [Rules.Apology],
        time_tick: [Rules.TimePassage, Rules.MemoryDecay, Rules.Autonomy],
        gossip_shared: [Rules.Gossip, Rules.Empathy],
        comfort_offered: [Rules.Comfort]
      },
      reactive_rules: [Rules.Mood, Rules.Proactive]
    }
  end

  @doc "Event types that have at least one rule."
  def event_types(%__MODULE__{event_rules: event_rules}) do
    event_rules |> Map.keys() |> Enum.sort()
  end

  @doc "Returns true when the pipeline knows how to handle `type`."
  def handles?(%__MODULE__{event_rules: event_rules}, type), do: Map.has_key?(event_rules, type)

  @doc "Rules that run for an event of `type`, including reactive rules."
  def rules_for(%__MODULE__{} = pipeline, type) do
    Map.get(pipeline.event_rules, type, []) ++ pipeline.reactive_rules
  end

  @doc "Appends `rule` to the rules for `type`, registering the type if needed."
  def append(%__MODULE__{} = pipeline, type, rule) when is_atom(type) and is_atom(rule) do
    update_in(
      pipeline.event_rules,
      &Map.update(&1, type, [rule], fn rules -> rules ++ [rule] end)
    )
  end

  @doc "Inserts `rule` before the other rules for `type`."
  def prepend(%__MODULE__{} = pipeline, type, rule) when is_atom(type) and is_atom(rule) do
    update_in(pipeline.event_rules, &Map.update(&1, type, [rule], fn rules -> [rule | rules] end))
  end

  @doc "Removes `rule` from every event type and from the reactive rules."
  def remove(%__MODULE__{} = pipeline, rule) do
    %__MODULE__{
      event_rules: Map.new(pipeline.event_rules, fn {type, rules} -> {type, rules -- [rule]} end),
      reactive_rules: pipeline.reactive_rules -- [rule]
    }
  end

  @doc "Appends a reactive rule that runs after every event."
  def add_reactive(%__MODULE__{} = pipeline, rule) when is_atom(rule) do
    %{pipeline | reactive_rules: pipeline.reactive_rules ++ [rule]}
  end

  @doc """
  Describes the pipeline as `[{type, [{rule_id, description}]}]`, with reactive
  rules listed under `:reactive`.
  """
  def describe(%__MODULE__{} = pipeline) do
    event_rows =
      for type <- event_types(pipeline) do
        {type, Enum.map(pipeline.event_rules[type], &{&1.id(), &1.description()})}
      end

    event_rows ++ [{:reactive, Enum.map(pipeline.reactive_rules, &{&1.id(), &1.description()})}]
  end
end
