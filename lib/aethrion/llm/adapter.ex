defmodule Aethrion.LLM.Adapter do
  @moduledoc """
  Behaviour for optional language-model adapters.

  Adapters sit on the expression side of the runtime boundary:

  - `c:render/2` phrases an output from an `Aethrion.Expression.Request`
    snapshot. It returns text only.
  - `c:interpret/2` (optional) proposes a structured intent for free text a user
    typed. The proposal is validated and turned into an event by
    `Aethrion.Intent`; it still has to pass the runtime's validation and rules
    before anything changes.

  Adapters never receive `Aethrion.State` and cannot return state. If an adapter
  fails, times out, or is absent, the deterministic fallback text is used and
  the simulation continues unchanged.
  """

  alias Aethrion.Expression.Request

  @typedoc """
  A structured intent proposal. `intent` is `:message` or `:apology`; `tone` is
  required for `:message`.
  """
  @type proposal :: %{required(:intent) => :message | :apology, optional(:tone) => atom()}

  @callback render(Request.t(), keyword()) :: {:ok, String.t()} | {:error, term()}

  @callback interpret(Aethrion.Intent.Request.t(), keyword()) ::
              {:ok, proposal()} | {:error, term()}

  @doc """
  A plain completion: a system prompt and a user message in, the model's
  text out. `Aethrion.Interpreter.LLM` uses it to read what a chat line does.
  """
  @callback complete(system :: String.t(), user :: String.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @optional_callbacks interpret: 2, complete: 3
end
