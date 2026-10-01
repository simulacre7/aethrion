defmodule Aethrion.LLM do
  @moduledoc """
  Calls on a model adapter that do not belong to one adapter.
  """

  @doc """
  A reply to a conversation (`[%{"role" => ..., "content" => ...}]`): the
  adapter's `chat/2` when it has one, otherwise `complete/3` with the
  system messages as the system prompt and the rest as a transcript.
  """
  @spec chat(module(), [map()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(adapter, messages, opts \\ []) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :chat, 2) do
      adapter.chat(messages, opts)
    else
      {system, rest} = Enum.split_with(messages, &(&1["role"] == "system"))

      transcript =
        Enum.map_join(rest, "\n\n", fn m -> "#{label(m["role"])}: #{m["content"]}" end) <>
          "\n\nWrite the next assistant message only, without a label."

      adapter.complete(Enum.map_join(system, "\n\n", & &1["content"]), transcript, opts)
    end
  end

  defp label("assistant"), do: "Assistant"
  defp label(_user), do: "User"
end
