defmodule Aethrion.Persistence.InMemory do
  @moduledoc """
  Reference persistence adapter that keeps state in the caller.
  """

  @behaviour Aethrion.Persistence

  @impl true
  def save(%Aethrion.State{}, _opts \\ []) do
    :ok
  end

  @impl true
  def load(opts \\ []) do
    case Keyword.fetch(opts, :state) do
      {:ok, %Aethrion.State{} = state} -> {:ok, state}
      :error -> {:error, :missing_state}
    end
  end
end
