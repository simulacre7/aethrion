defmodule Aethrion.Persistence do
  @moduledoc """
  Persistence behaviour for runtime state adapters.

  `load/1` must return `{:error, %Aethrion.Error{code: :not_found}}` when
  nothing has been saved yet: `Aethrion.RuntimeServer` then starts from its
  initial state. Any other error means a snapshot exists but cannot be used,
  and the server refuses to start rather than overwrite it.

  Options passed by `Aethrion.RuntimeServer` include `:pipeline`, so an
  adapter can keep tuning for custom rules (see `Aethrion.State.parse/2`).
  """

  alias Aethrion.{Error, State}

  @callback save(State.t(), keyword()) :: :ok | {:error, Error.t()}
  @callback load(keyword()) :: {:ok, State.t()} | {:error, Error.t()}
end
