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

  Such a cast has relationships and memories, no stats, fights, or endings:
  those are added in the editor, and played with the model name `aethrion`.
  """

  alias Aethrion.{Bridge, Card, State}

  @max_prompt 24_000
  @max_greeting 4_000
  @max_people 6
  @max_profile 600

  @doc """
  What a request says about its card: the app's prompt before the chat
  proper (`prompt`) and the card's first message (`greeting`, nil when the
  chat starts with the player).
  """
  @spec card([map()], [map()]) :: %{prompt: String.t(), greeting: String.t() | nil}
  def card(all, chat) do
    prompt =
      all
      |> Enum.take(length(all) - length(chat))
      |> Enum.filter(&(&1["role"] == "system"))
      |> Enum.map_join("\n\n", & &1["content"])
      |> String.slice(0, @max_prompt)

    greeting =
      case chat do
        [%{"role" => "assistant", "content" => text} | _rest] when text != "" ->
          String.slice(text, 0, @max_greeting)

        _other ->
          nil
      end

    %{prompt: prompt, greeting: greeting}
  end

  @doc """
  The key a card's cast is kept under: its first message when it has one
  (an app may change its prompt from turn to turn; the first message stays),
  else its prompt.
  """
  @spec key(%{prompt: String.t(), greeting: String.t() | nil}) :: String.t()
  def key(%{greeting: greeting}) when is_binary(greeting), do: "card:" <> sha("g\0" <> greeting)
  def key(%{prompt: prompt}), do: "card:" <> sha("p\0" <> prompt)

  @doc """
  The cast this chat already has, or nil: the one a reply's checkpoint was
  made from (the latest reply that has one), else the one kept for the
  card. `casts` and `checkpoints` are `%{get: fun, put: fun}`
  (`Aethrion.Bridge.Store`).
  """
  @spec find([map()], map(), %{casts: map(), checkpoints: map()}) :: State.t() | nil
  def find(chat, card, %{casts: casts, checkpoints: checkpoints}) do
    by_checkpoint =
      chat
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{"checkpoint" => id} when is_binary(id) ->
          case checkpoints.get.(id) do
            %{"root" => root} when is_binary(root) -> parsed(casts.get.("root:" <> root))
            _none -> nil
          end

        _message ->
          nil
      end)

    by_checkpoint || parsed(casts.get.(key(card)))
  end

  @doc """
  Reads the card with the model and keeps the cast: `{:ok, state}`. A model
  that fails or answers something else gives `{:error, reason}`, and
  nothing is kept. Options: `:locale` (`:ko` or `:en`, the language of the
  fallback name), and the adapter's own.
  """
  @spec read(map(), map(), module(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def read(card, casts, adapter, opts \\ []) do
    {locale, opts} = Keyword.pop(opts, :locale, :en)

    with {:ok, answer} <- Aethrion.LLM.chat(adapter, question(card), opts),
         {:ok, people} <- people(answer),
         data = cast_data(people, card, locale),
         {:ok, state} <- State.parse(data) do
      casts.put.(key(card), data)
      casts.put.("root:" <> Bridge.root(state), data)
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
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
        <first_message>
        #{card.greeting || ""}
        </first_message>

        List the characters the player meets and talks to in this card, the main one first, at most #{@max_people}. The player (the user, {{user}}, or the persona the card describes as the player) is not one of them. Do not list characters only mentioned in passing. If the card is a narrator or a world with no fixed characters, list none.

        Answer as JSON:
        {"title": "the card's name", "characters": [{"name": "as the card writes it", "profile": "one or two sentences: who they are and how they treat the player", "affinity": 0, "trust": 0}]}

        affinity and trust are how the character feels about the player when the story starts, 0 to 100: 0 a stranger, 30 an acquaintance, 50 a close friend, 80 a lover or someone devoted. Use what the card says; when it does not say, 0.
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

      {:ok, %{title: title(data["title"]), characters: characters}}
    else
      _other -> {:error, :no_characters_read}
    end
  end

  defp title(title) when is_binary(title), do: String.trim(title)
  defp title(_other), do: ""

  @doc false
  # Cast data for the characters read. A card with no fixed characters gets
  # one, named after the card: the one the player talks to.
  def cast_data(%{title: title, characters: []}, card, locale) do
    name =
      cond do
        title != "" -> String.slice(title, 0, 40)
        locale == :ko -> "이야기"
        true -> "Story"
      end

    cast_data(%{title: title, characters: [%{"name" => name}]}, card, locale)
  end

  def cast_data(%{characters: characters}, card, _locale) do
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

  defp parsed(nil), do: nil

  defp parsed(data) do
    case State.parse(data) do
      {:ok, state} -> state
      {:error, _error} -> nil
    end
  end

  defp sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
