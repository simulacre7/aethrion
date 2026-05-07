defmodule Aethrion.Runtime do
  @moduledoc """
  Deterministic runtime entry point.
  """

  alias Aethrion.Rules.{GiftRules, JealousyRules, LonelinessRules}
  alias Aethrion.State

  def demo_state, do: State.demo()

  def dispatch(%State{} = state, %{type: :gift_received} = event) do
    {state, gift_outputs, gift_log} = GiftRules.apply(state, event)
    {state, observer_outputs, observer_log} = JealousyRules.apply_observers(state, event)
    {state, proactive_outputs, proactive_log} = JealousyRules.apply_thresholds(state)

    {state, gift_outputs ++ observer_outputs ++ proactive_outputs,
     gift_log ++ observer_log ++ proactive_log}
  end

  def dispatch(%State{} = state, %{type: :time_tick} = event) do
    {state, time_outputs, time_log} = LonelinessRules.apply(state, event)
    {state, proactive_outputs, proactive_log} = JealousyRules.apply_thresholds(state)

    {state, time_outputs ++ proactive_outputs, time_log ++ proactive_log}
  end
end
