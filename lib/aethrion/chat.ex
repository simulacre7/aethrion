defmodule Aethrion.Chat do
  @moduledoc """
  What one line a person typed in a chat does, so a chat needs no commands.

      read(state, "user", "ria", "늑대왕의 목을 노려 벤다")   # {:combat, attack}
      read(state, "user", "seoyun", "오늘은 같이 그림 그리자") # {:activity, activity}
      read(state, "user", "seoyun", "이거 선물이야, 물감 샀어") # {:gift, gift}
      read(state, "user", "seoyun", "네 그림 정말 좋다")       # :talk

  In order:

  - **a fight**: while an enemy is standing and the story is not over, words
    that do something in a fight (`Aethrion.Combat.action/4`) are that
    action;
  - **an activity**: words that suggest one of the story's activities to
    the character spoken to ("그림 그리자", "오늘은 쉬자", one of its
    `phrases`), not words that merely mention it ("네 그림 좋다");
  - **a gift**: words that hand something over ("꽃 사 왔어", "이거 선물이야",
    "I got you some tea");
  - **talk**: everything else, a message (or an apology) whose tone
    `Aethrion.Intent` reads.

  It reads only the state and the text, so the same line in the same world
  always does the same thing.
  """

  alias Aethrion.{Combat, Event, State}

  @type reading ::
          {:combat, Event.t()} | {:activity, Event.t()} | {:gift, Event.t()} | :talk

  # Suggesting or telling someone to do it: "그리자", "공부할까", "쉬어",
  # "하러 가자", "해 봐", "let's paint".
  @suggests ~r/(자|할래|갈래|볼래|할까|해\s?볼까|하러|해라|해\s?봐|하렴|하는 게 어때|어때)(?=$|[\s.!?~,])|\blet'?s\b|\bshall we\b|\bhow about\b/u

  @gives ~r/(선물(?:이야|이에요|이다|로|을|를|\s?받아|\s?줄게|\s*[!~.]|$)|사\s?왔|사\s?옴|가져왔|챙겨\s?왔|[을를]\s?줄게)|\b(got you an?|got you some|bought you|a gift for you|a present for you)\b/u

  @doc "What `text`, said by `from` to `to`, does in `state`."
  @spec read(State.t(), String.t(), String.t(), String.t()) :: reading()
  def read(%State{} = state, from, to, text) when is_binary(text) do
    words = String.downcase(text)

    cond do
      event = fight(state, from, text) -> {:combat, event}
      activity = activity(state, words) -> {:activity, Event.activity(to, activity)}
      item = gift(words) -> {:gift, Event.gift_received(from, to, item)}
      true -> :talk
    end
  end

  @doc """
  Like `read/4`, for a line that may both say something and do something
  in a fight ("카엘, 고마워! 늑대왕을 벤다"): the sentences that act are the
  move, the others are talk, to whoever they call by name ("카엘, ...") or
  `to`. Talk comes first, as it was said. Outside a fight, one reading.
  """
  @spec read_all(State.t(), String.t(), String.t(), String.t()) ::
          [reading() | {:talk, String.t(), String.t()}]
  def read_all(%State{} = state, from, to, text) when is_binary(text) do
    case read(state, from, to, text) do
      {:combat, _event} = combat ->
        {acting, talking} =
          text |> sentences() |> Enum.split_with(&(fight(state, from, &1) != nil))

        move =
          case acting do
            [] -> combat
            sentences -> {:combat, fight(state, from, Enum.join(sentences, " "))}
          end

        case Enum.join(talking, " ") do
          "" -> [move]
          said -> [{:talk, addressee(state, said, to), said}, move]
        end

      reading ->
        [reading]
    end
  end

  defp sentences(text),
    do: text |> String.split(~r/(?<=[.!?~])\s+|\n+/u, trim: true) |> Enum.map(&String.trim/1)

  # "카엘, 고마워" or "카엘아 고마워" talks to Kael, if he can listen.
  defp addressee(state, said, to) do
    called =
      Enum.find(State.sorted_characters(state), fn c ->
        Regex.match?(~r/^#{Regex.escape(c.name)}(?:아|야|씨)?(?:,|\s)/u, said) and
          not State.down?(state, c.id)
      end)

    if called, do: called.id, else: to
  end

  defp fight(state, from, text) do
    if Combat.foe(state) != nil and not Combat.over?(state),
      do: Combat.action(state, from, nil, text)
  end

  defp activity(%State{story: story}, words) do
    activities = story |> Map.get(:activities, %{}) |> Map.keys() |> Enum.sort()
    phrases = Map.get(story, :phrases, %{})

    Enum.find(activities, fn name ->
      Enum.any?(Map.get(phrases, name, []), &String.contains?(words, String.downcase(&1))) or
        (String.contains?(words, String.downcase(name)) and Regex.match?(@suggests, words))
    end)
  end

  # What is handed over: a word marked as the object ("물감을 줄게"), else
  # the first word before the giving that names a thing ("물감 새로 사
  # 왔어" is paint, "너 주려고 꽃 사 왔어" a flower), else "선물".
  @not_things ~w(너 너한테 너에게 너 내가 나 제가 오늘 어제 새로 좀 하나 많이 진짜 그냥 잠깐 방금 이거 이것 이건 그거 이걸 요거 짠 자 여기 선물 선물이야 선물로)

  defp gift(words) do
    if Regex.match?(@gives, words), do: korean_item(words) || english_item(words) || "선물"
  end

  defp korean_item(words) do
    case Regex.run(~r/^(.*?)(?:선물|사\s?왔|사\s?옴|가져왔|챙겨\s?왔|[을를]?\s?줄게)/u, words) do
      [_all, before] ->
        candidates =
          before
          |> String.split(~r/[\s,.!?~]+/u, trim: true)
          |> Enum.reject(&(&1 in @not_things or String.ends_with?(&1, ["려고", "한테", "에게", "위해"])))

        marked = Enum.find(candidates, &String.ends_with?(&1, ["을", "를"]))

        case marked || List.first(candidates) do
          nil -> nil
          word -> word |> String.replace(~r/(을|를|이야|야|이랑|하고)$/u, "") |> nonempty()
        end

      nil ->
        nil
    end
  end

  defp english_item(words) do
    case Regex.run(~r/\b(?:got you|bought you)\s+(?:a |an |some |the )?(\w+)/u, words) do
      [_all, item] -> item
      nil -> nil
    end
  end

  defp nonempty(""), do: nil
  defp nonempty(word), do: word
end
