defmodule Aethrion.Persistence do
  @moduledoc """
  Persistence behaviour for runtime state adapters.
  """

  alias Aethrion.State

  @callback save(State.t(), keyword()) :: :ok | {:error, term()}
  @callback load(keyword()) :: {:ok, State.t()} | {:error, term()}
end
