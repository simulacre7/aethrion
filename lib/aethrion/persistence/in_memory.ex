defmodule Aethrion.Persistence.InMemory do
  @moduledoc """
  Reference persistence adapter that keeps state in the caller.
  """

  @behaviour Aethrion.Persistence

  alias Aethrion.Error

  @impl true
  def save(%Aethrion.State{}, _opts \\ []) do
    :ok
  end

  @impl true
  def load(opts \\ []) do
    case Keyword.fetch(opts, :state) do
      {:ok, %Aethrion.State{} = state} -> {:ok, state}
      _ -> {:error, Error.new(:not_found, "no state was given")}
    end
  end
end
