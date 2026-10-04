defmodule Aethrion.Interpreter.LLM do
  @moduledoc """
  Reads what a chat line does with a language model: any
  `Aethrion.LLM.Adapter` with `complete/3` (Anthropic, an OpenAI-compatible
  server such as Ollama, LM Studio, or llama.cpp, or a local CLI such as
  Claude Code). The model is shown what is possible in the world
  (`Aethrion.Interpreter.schema/3`: who is there and on which side, the
  tones, the activities) and answers with JSON choices, which
  `Aethrion.Interpreter.from_answers/2` turns into events. It only chooses;
  the rules decide what happens.

  Options: `:adapter` (required) and `:adapter_opts`.
  """

  @behaviour Aethrion.Interpreter

  alias Aethrion.Expression.Prompt
  alias Aethrion.Interpreter
  alias Aethrion.Interpreter.Request

  @system """
  You read what one line a player typed in a chat game does in the game's world. \
  Answer with one JSON object and nothing else: {"readings": [...]}. \
  A line does one thing, or talks and then acts ("리아, 고마워! 늑대왕을 벤다" is talk to ria, then an attack); list them in that order.

  Each reading has:
  - "does": one of attack, defend, heal, flee, activity, gift, talk, apology
  - "target": an id from the list (who is struck, shielded, healed, fled from, given to, or spoken to); omit it when it is the character the player is chatting with, or for a guard of oneself
  - "tone": for talk, one of warm, neutral, cold, hostile
  - "activity": for activity, one of the story's activities
  - "item": for gift, the thing handed over, as the player wrote it ("아이스크림", "물감")
  - "helper": for heal, the id of a companion the player asks to heal (omit when the player heals with their own potion)
  - "confidence": 0 to 1

  Rules of reading:
  - attack, defend, heal, flee only while a fight is on; otherwise such words are talk.
  - In a fight, a line that does nothing in the fight (cheering, thanks, insults, orders to others) is talk.
  - activity only when the player suggests doing one of the story's activities ("오늘은 같이 그림 그리자"); talking about it is talk.
  - gift when the player hands something over as a present ("너 주려고 쿠키 사 왔어"). Paying a price, buying, selling, or handing over what was asked for in a trade is no gift: such a line is talk, or none.
  - apology when the player apologizes.
  - Thanks, praise, comfort, and invitations are warm; plain questions and remarks are neutral; brush-offs are cold; insults and contempt are hostile.
  """

  @none """

  - "does" may also be none: the line does none of these to anyone in the list. The player moves, looks around, waits, or fights, takes, buys, or uses something that is not in the list. A line that is only that is {"readings": [{"does": "none", "confidence": 1}]}.
  """

  @impl true
  def interpret(%Request{} = request, opts) do
    adapter = Keyword.fetch!(opts, :adapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    # With `:allow_none`, the model may say the line does none of these.
    none? = Keyword.get(opts, :allow_none, false)
    system = if none?, do: @system <> @none, else: @system

    with {:ok, text} <- adapter.complete(system, prompt(request), adapter_opts),
         {:ok, %{"readings" => readings}} when is_list(readings) <- decode(text),
         readings = if(none?, do: Enum.reject(readings, &(&1["does"] == "none")), else: readings),
         true <- none? or readings != [] do
      readings
      |> Enum.map(&Interpreter.from_answers(request, defaults(&1)))
      |> Enum.reduce_while({:ok, []}, fn
        {:ok, readings}, {:ok, acc} -> {:cont, {:ok, acc ++ readings}}
        error, _acc -> {:halt, error}
      end)
    else
      false -> {:error, {:invalid_response, %{"readings" => []}}}
      {:ok, other} -> {:error, {:invalid_response, other}}
      error -> error
    end
  end

  defp decode(text) do
    case Prompt.decode_json_object(text) do
      {:ok, map} -> {:ok, map}
      _error -> {:error, {:not_json, String.slice(text, 0, 200)}}
    end
  end

  defp defaults(answers), do: Map.put_new(answers, "confidence", 0.9)

  @doc false
  def prompt(%Request{schema: schema, to: to, text: text}) do
    people =
      Enum.map_join(schema.targets, "\n", fn t ->
        "- #{t.id} (#{t.name}): #{side(t.side)}#{if t.down, do: ", knocked out", else: ""}"
      end)

    """
    A fight is on: #{if schema.fight, do: "yes", else: "no"}.
    The player is "user". They are chatting with #{to}.
    Who is there:
    #{people}
    Companions who can heal: #{Enum.join(schema.healers, ", ") |> blank("none")}
    The story's activities: #{Enum.join(schema.activities, ", ") |> blank("none")}

    The line: #{Jason.encode!(text)}
    """
  end

  defp side(:enemy), do: "enemy"
  defp side(:party), do: "the player's companion"
  defp side(:other), do: "character"

  defp blank("", word), do: word
  defp blank(text, _word), do: text
end
