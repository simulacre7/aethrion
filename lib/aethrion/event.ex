defmodule Aethrion.Event do
  @moduledoc """
  Event constructors for the v0 runtime.
  """

  def gift_received(from, to, item, opts \\ []) do
    %{
      type: :gift_received,
      from: from,
      to: to,
      item: item,
      observed_by: Keyword.get(opts, :observed_by, []),
      at: Keyword.get(opts, :at, "demo:t0")
    }
  end

  def time_tick(now, opts \\ []) do
    %{type: :time_tick, now: now, hours: Keyword.get(opts, :hours, 1)}
  end
end
