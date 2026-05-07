defmodule Aethrion.Error do
  @moduledoc """
  Structured runtime error returned by public APIs.
  """

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]
end
