defmodule Aethrion.Interpreter.Rules do
  @moduledoc """
  The built-in interpreter: keywords and patterns, no model
  (`Aethrion.Chat` for what a line does, `Aethrion.Intent` for the tone of
  talk). Deterministic and free; it misses phrasings it has no words for,
  which then read as talk. With an LLM configured for `Aethrion.Intent`
  (the `:intent` option), the tone of talk comes from the model.
  """

  @behaviour Aethrion.Interpreter

  alias Aethrion.{Chat, Intent}
  alias Aethrion.Interpreter.Request

  @impl true
  def interpret(%Request{state: state, from: from, to: to, text: text}, opts) do
    intent = Keyword.get(opts, :intent, [])

    state
    |> Chat.read_all(from, to, text)
    |> Enum.reduce_while({:ok, []}, fn reading, {:ok, acc} ->
      case reading(state, from, to, text, reading, intent) do
        {:ok, reading} -> {:cont, {:ok, acc ++ [reading]}}
        error -> {:halt, error}
      end
    end)
  end

  defp reading(state, from, to, text, :talk, intent), do: talk(state, from, to, text, intent)

  defp reading(state, from, _to, _text, {:talk, to, said}, intent),
    do: talk(state, from, to, said, intent)

  defp reading(_state, _from, _to, _text, {as, event}, _intent),
    do: {:ok, %{as: as, event: event, confidence: 1.0}}

  defp talk(state, from, to, text, intent) do
    opts = [
      to: to,
      from: from,
      adapter: Keyword.get(intent, :adapter, Aethrion.LLM.FakeAdapter),
      adapter_opts: Keyword.get(intent, :adapter_opts, [])
    ]

    with {:ok, event, _meta} <- Intent.interpret(state, text, opts) do
      {:ok, %{as: :talk, event: event, confidence: 1.0}}
    end
  end
end
