defmodule Aethrion.Runtime do
  @moduledoc """
  Deterministic runtime entry point.
  """

  alias Aethrion.Rules.{GiftRules, JealousyRules, LonelinessRules}
  alias Aethrion.{State, Validator}

  def demo_state, do: State.demo()

  @doc """
  Dispatches an event through the deterministic runtime.

  Returns `{:ok, state, outputs, log}` on success or `{:error, error}` when the
  input is invalid.
  """
  def dispatch(%State{} = state, %{type: :gift_received} = event) do
    with :ok <- Validator.validate_dispatch(state, event) do
      do_dispatch_gift(state, event)
    end
  end

  def dispatch(%State{} = state, %{type: :time_tick} = event) do
    with :ok <- Validator.validate_dispatch(state, event) do
      do_dispatch_time_tick(state, event)
    end
  end

  def dispatch(state, event) do
    Validator.validate_dispatch(state, event)
  end

  defp do_dispatch_gift(state, event) do
    {state, gift_outputs, gift_log} = GiftRules.apply(state, event)
    {state, observer_outputs, observer_log} = JealousyRules.apply_observers(state, event)
    {state, proactive_outputs, proactive_log} = JealousyRules.apply_thresholds(state)

    {:ok, state, gift_outputs ++ observer_outputs ++ proactive_outputs,
     gift_log ++ observer_log ++ proactive_log}
  end

  defp do_dispatch_time_tick(state, event) do
    {state, time_outputs, time_log} = LonelinessRules.apply(state, event)
    {state, proactive_outputs, proactive_log} = JealousyRules.apply_thresholds(state)

    {:ok, state, time_outputs ++ proactive_outputs, time_log ++ proactive_log}
  end
end
