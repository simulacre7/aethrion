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
      {system, transcript} = transcript(messages)
      adapter.complete(system, transcript, opts)
    end
  end

  @doc """
  Like `chat/3`, but `on_delta` gets the reply piece by piece as the model
  writes it, so a chat app can show it coming in. Adapters with
  `stream_chat/3` stream; the others reply whole, in one piece.
  """
  @spec stream_chat(module(), [map()], keyword(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def stream_chat(adapter, messages, opts, on_delta) do
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :stream_chat, 3) do
      adapter.stream_chat(messages, opts, on_delta)
    else
      with {:ok, text} <- chat(adapter, messages, opts) do
        on_delta.(text)
        {:ok, text}
      end
    end
  end

  @doc false
  # A conversation as one system prompt and one transcript, for adapters
  # that take a single prompt.
  def transcript(messages) do
    {system, rest} = Enum.split_with(messages, &(&1["role"] == "system"))

    transcript =
      Enum.map_join(rest, "\n\n", fn m -> "#{label(m["role"])}: #{m["content"]}" end) <>
        "\n\nWrite the next assistant message only, without a label."

    {Enum.map_join(system, "\n\n", & &1["content"]), transcript}
  end

  defp label("assistant"), do: "Assistant"
  defp label(_user), do: "User"
end
