defmodule Aethrion.Bridge.AutoCast do
  @moduledoc """
  A cast read from the chat app's own prompt, for the model name
  `aethrion-auto`: the card the player already uses stays as it is, and the
  rules get the people in it and how each feels about the player at the
  start. Nothing is imported or edited first.

  The model reads the card once (`read/4`): who the player can meet, a line
  on each, and their affinity and trust toward the player. That is kept
  (`Aethrion.Bridge.Casts`) under the card's key and under the cast's root,
  so the same chat finds the same cast again (`find/3`): by the checkpoint
  of a reply still in the chat, whatever the app has since changed in its
  prompt, or, before the first reply, by the card's first message.

  A card that narrates a world may have no one in it at first; people join
  as the story brings them in (`Aethrion.Bridge.Scene`).

  Such a cast has relationships and memories, no stats, fights, or endings:
  those are added in the editor, and played with the model name `aethrion`.
  """

  alias Aethrion.{Bridge, Card, State}

  @max_prompt 24_000
  @max_greeting 4_000
  @max_people 6
  @max_profile 600
  @max_rules 16_000

  @doc """
  What a request says about its card: the app's prompt before the chat
  proper (`prompt`), the card's first message (`greeting`, nil when the
  chat starts with the player), and `rules`, what the app adds inside or
  after the chat (a card's instructions for every reply: its status
  window is usually there) and what of a long prompt speaks of a status
  window.
  """
  @spec card([map()], [map()]) :: %{
          prompt: String.t(),
          greeting: String.t() | nil,
          rules: String.t()
        }
  def card(all, chat) do
    whole =
      all
      |> Enum.take(length(all) - length(chat))
      |> Enum.filter(&(&1["role"] == "system"))
      |> Enum.map_join("\n\n", & &1["content"])

    greeting =
      case chat do
        [%{"role" => "assistant", "content" => text} | _rest] when text != "" ->
          String.slice(text, 0, @max_greeting)

        _other ->
          nil
      end

    inside =
      chat
      |> Enum.filter(
        &(&1["role"] == "system" and not String.match?(&1["content"], ~r/\A\[Aethrion:/))
      )
      |> Enum.map(& &1["content"])

    rules =
      (inside ++ hints(String.slice(whole, @max_prompt, 400_000)))
      |> Enum.join("\n\n")
      |> String.slice(0, @max_rules)

    %{prompt: String.slice(whole, 0, @max_prompt), greeting: greeting, rules: rules}
  end

  # What the part of a long prompt the reader does not get says about a
  # status window: the text around each mention, three at most.
  defp hints(rest) do
    ~r/status window|상태창|스테이터스|\[status/iu
    |> Regex.scan(rest, return: :index)
    |> Enum.map(fn [{at, _length}] -> at end)
    |> Enum.reduce([], fn at, kept ->
      if Enum.any?(kept, &(abs(&1 - at) < 3_000)), do: kept, else: kept ++ [at]
    end)
    |> Enum.take(3)
    |> Enum.map(fn at ->
      from = max(at - 600, 0)
      rest |> binary_part(from, min(3_600, byte_size(rest) - from)) |> String.replace_invalid("")
    end)
  end

  @doc """
  The key a card's cast is kept under: its first message when it has one
  (an app may change its prompt from turn to turn; the first message stays),
  else its prompt.
  """
  @spec key(map()) :: String.t()
  def key(%{greeting: greeting}) when is_binary(greeting), do: sha("g\0" <> greeting)
  def key(%{prompt: prompt}), do: sha("p\0" <> prompt)

  @typedoc """
  What a card was read as: the `cast`, the card's status `window` (its
  opening and closing text, or nil), and the `key` it is kept under.
  """
  @type read :: %{cast: State.t(), window: Aethrion.Bridge.Ledger.spec() | nil, key: String.t()}

  @doc """
  What this chat's card was read as, or nil: by the key a reply's status
  block carries (the latest reply that has one), else by the cast a
  reply's checkpoint was made from, else by the card's own key. `casts`
  and `checkpoints` are `%{get: fun, put: fun}` (`Aethrion.Bridge.Store`).
  """
  @spec find([map()], map(), %{casts: map(), checkpoints: map()}) :: read() | nil
  def find(chat, card, %{casts: casts, checkpoints: checkpoints}) do
    replies = Enum.reverse(chat)

    by_key =
      Enum.find_value(replies, fn
        %{"card" => key} when is_binary(key) -> kept(casts.get.("card:" <> key), key)
        _message -> nil
      end)

    by_checkpoint = fn ->
      Enum.find_value(replies, fn
        %{"checkpoint" => id} when is_binary(id) ->
          case checkpoints.get.(id) do
            %{"root" => root} when is_binary(root) -> kept(casts.get.("root:" <> root), key(card))
            _none -> nil
          end

        _message ->
          nil
      end)
    end

    by_key || by_checkpoint.() || kept(casts.get.("card:" <> key(card)), key(card))
  end

  # What is kept under a key, read back: the cast with the card's window,
  # or (as an older server kept it) the cast alone.
  defp kept(%{"cast" => data} = kept, key) do
    with {:ok, state} <- State.parse(data) do
      window =
        case kept["window"] do
          %{"open" => open, "close" => close} when is_binary(open) and is_binary(close) ->
            %{open: open, close: close}

          _none ->
            nil
        end

      %{cast: state, window: window, key: key}
    else
      _error -> nil
    end
  end

  defp kept(%{"characters" => _} = data, key), do: kept(%{"cast" => data}, key)
  defp kept(_none, _key), do: nil

  @doc """
  Reads the card with the model and keeps what it was read as:
  `{:ok, read}`. A model that fails or answers something else gives
  `{:error, reason}`, and nothing is kept. Options are the adapter's.
  """
  @spec read(map(), map(), module(), keyword()) :: {:ok, read()} | {:error, term()}
  def read(card, casts, adapter, opts \\ []) do
    with {:ok, answer} <- Aethrion.LLM.chat(adapter, question(card), opts),
         {:ok, people} <- people(answer),
         data = cast_data(people, card),
         {:ok, state} <- State.parse(data) do
      key = key(card)

      window =
        people.window &&
          %{"open" => people.window.open, "close" => people.window.close}

      kept = %{"cast" => data, "window" => window}
      casts.put.("card:" <> key, kept)
      casts.put.("root:" <> Bridge.root(state), kept)
      {:ok, %{cast: state, window: people.window, key: key}}
    end
  end

  @doc false
  # The messages that ask the model who is in the card.
  def question(card) do
    [
      %{
        "role" => "system",
        "content" =>
          "You read a role-play character card for a game engine that tracks how each character feels about the player. Answer with one JSON object and nothing else."
      },
      %{
        "role" => "user",
        "content" => """
        <card>
        #{card.prompt}
        </card>
        <rules_for_every_reply>
        #{Map.get(card, :rules, "")}
        </rules_for_every_reply>
        <first_message>
        #{card.greeting || ""}
        </first_message>

        List the characters the player meets and talks to in this card, the main one first, at most #{@max_people}. The player (the user, {{user}}, or the persona the card describes as the player) is not one of them. Do not list characters only mentioned in passing. If the card is a narrator or a world with no fixed characters, list none.

        Answer as JSON:
        {"title": "the card's name", "characters": [{"name": "as the first message writes it, or when it does not name them, as the card does", "profile": "one or two sentences, in the first message's language: who they are and how they treat the player", "affinity": 0, "trust": 0}], "status_window": null}

        affinity and trust are how the character feels about the player when the story starts, 0 to 100: 0 a stranger, 30 an acquaintance, 50 a close friend, 80 a lover or someone devoted. Use what the card says; when it does not say, 0.

        status_window: if the card tells the model to print a status window with every reply (a block of numbers and facts in a fixed format: level, HP, money, trust, date, place), give {"open": "the exact text that begins the block", "close": "the exact text that ends it"}, copied from the card's format: for a block between two "[Status Window]" lines, both are "[Status Window]"; for one line such as "[ Trust: 3% | Anger: 5% | ... ]", "[" and "]"; for a block that just ends with the reply, "" as close. If the card prints no such block, or only draws one with its own scripts and tells the model not to write the numbers, null.
        """
      }
    ]
  end

  @doc false
  # The characters in the model's answer: `{:ok, %{title:, characters:}}`.
  def people(answer) do
    with [json] <- Regex.run(~r/\{.*\}/s, answer),
         {:ok, %{"characters" => characters} = data} when is_list(characters) <-
           Jason.decode(json) do
      characters =
        characters
        |> Enum.filter(&(is_map(&1) and is_binary(&1["name"]) and String.trim(&1["name"]) != ""))
        |> Enum.uniq_by(&Card.id_for(String.trim(&1["name"])))
        |> Enum.take(@max_people)

      {:ok,
       %{
         title: title(data["title"]),
         characters: characters,
         window: window(data["status_window"])
       }}
    else
      _other -> {:error, :no_characters_read}
    end
  end

  # The window's opening and closing text as the model gave them: short
  # texts, the opening one not empty.
  defp window(%{"open" => open} = window) when is_binary(open) do
    close = if is_binary(window["close"]), do: window["close"], else: ""
    {open, close} = {String.trim(open), String.trim(close)}

    if open != "" and String.length(open) <= 60 and String.length(close) <= 60,
      do: %{open: open, close: close}
  end

  defp window(_none), do: nil

  defp title(title) when is_binary(title), do: String.trim(title)
  defp title(_other), do: ""

  @doc false
  # Cast data for the characters read. A card with no fixed characters
  # starts with no one: the story brings them in (`Aethrion.Bridge.Scene`).
  def cast_data(%{characters: characters}, card) do
    {people, relationships} =
      characters
      |> Enum.with_index()
      |> Enum.map(fn {c, index} ->
        name = c["name"] |> String.trim() |> String.slice(0, 40)
        id = Card.id_for(name)

        character =
          %{"id" => id, "name" => name}
          |> put_text("profile", c["profile"], @max_profile)
          # The first one greets: the player talks to them by default.
          |> put_text("greeting", if(index == 0, do: card.greeting), @max_greeting)

        {character,
         %{
           "from" => id,
           "to" => "user",
           "affinity" => level(c["affinity"]),
           "trust" => level(c["trust"])
         }}
      end)
      |> Enum.unzip()

    %{"characters" => people, "relationships" => relationships}
  end

  defp put_text(map, key, text, max) when is_binary(text) do
    case String.trim(text) do
      "" -> map
      text -> Map.put(map, key, String.slice(text, 0, max))
    end
  end

  defp put_text(map, _key, _text, _max), do: map

  defp level(n) when is_number(n), do: n |> round() |> max(0) |> min(100)
  defp level(_other), do: 0

  defp sha(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 24)
end
