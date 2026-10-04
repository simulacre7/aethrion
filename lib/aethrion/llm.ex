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

  @doc """
  A conversation as its system prompt and its turns: the system messages
  that come before anything is said are the system prompt, and one that
  comes later stays where it is, as a note in the conversation (a turn
  with the role `"note"`). A chat app puts a card's instructions for the
  next reply there, and the bridge its own note: at the end, where the
  model reads them last, not above the whole chat.
  """
  @spec split([map()]) :: {String.t(), [map()]}
  def split(messages) do
    {leading, rest} = Enum.split_while(messages, &(&1["role"] == "system"))

    turns =
      Enum.map(rest, fn
        %{"role" => "system"} = m -> %{"role" => "note", "content" => m["content"]}
        m -> %{"role" => m["role"], "content" => m["content"]}
      end)

    {Enum.map_join(leading, "\n\n", & &1["content"]), turns}
  end

  @doc false
  # A note in the conversation, as a model that has no such role reads it.
  def note(content), do: "[System note]\n" <> content

  @doc false
  # A conversation as one system prompt and one transcript, for adapters
  # that take a single prompt.
  def transcript(messages) do
    {system, turns} = split(messages)

    transcript =
      Enum.map_join(turns, "\n\n", fn
        %{"role" => "note", "content" => content} -> note(content)
        m -> "#{label(m["role"])}: #{m["content"]}"
      end) <>
        "\n\nWrite the next assistant message only, without a label."

    {system, transcript}
  end

  defp label("assistant"), do: "Assistant"
  defp label(_user), do: "User"
end
