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
  @max_window_rules 24
  @max_rule 240

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
  opening and closing text and its arithmetic, or nil), the `key` it is
  kept under, and the name the card gives the `player`, if any.
  """
  @type read :: %{
          cast: State.t(),
          window: Aethrion.Bridge.Ledger.spec() | nil,
          key: String.t(),
          player: String.t() | nil
        }

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
    case State.parse(data) do
      {:ok, state} ->
        player = if is_binary(kept["player"]), do: kept["player"]
        %{cast: state, window: kept_window(kept["window"]), key: key, player: player}

      {:error, _error} ->
        nil
    end
  end

  defp kept(%{"characters" => _} = data, key), do: kept(%{"cast" => data}, key)
  defp kept(_none, _key), do: nil

  defp kept_window(%{"open" => open, "close" => close} = window)
       when is_binary(open) and is_binary(close),
       do: %{open: open, close: close, rules: kept_rules(window["rules"])}

  defp kept_window(_none), do: nil

  defp kept_rules(rules) when is_list(rules), do: Enum.filter(rules, &is_binary/1)
  defp kept_rules(_none), do: []

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

      # A rule is kept when the card says it: a formula made up from
      # somewhere else would bend every window after it.
      stated = Enum.join([card.prompt, Map.get(card, :rules, ""), card.greeting || ""], "\n")
      people = update_in(people.window, &grounded(&1, stated))

      window =
        people.window &&
          %{
            "open" => people.window.open,
            "close" => people.window.close,
            "rules" => people.window.rules
          }

      kept = %{"cast" => data, "window" => window, "player" => people.player}
      casts.put.("card:" <> key, kept)
      casts.put.("root:" <> Bridge.root(state), kept)
      {:ok, %{cast: state, window: people.window, key: key, player: people.player}}
    end
  end

  # The window with the rules the card bears out. The card's own examples
  # of its window decide first: a rule they contradict is dropped, one they
  # agree with is kept. Where they cannot say, the sentence the reader
  # gave for the rule decides (`stated?/3`).
  defp grounded(nil, _text), do: nil

  defp grounded(window, text) do
    examples = Aethrion.Bridge.Ledger.windows(text, window)

    rules =
      for {rule, from} <- window.rules,
          verdicts = Enum.map(examples, &Aethrion.Bridge.Ledger.agrees?(&1, rule, window)),
          false not in verdicts,
          true in verdicts or stated?(rule, from, text),
          do: rule

    %{window | rules: rules}
  end

  @doc false
  # Whether the card states a rule: the sentence the reader gives for it
  # is the card's (most of it is there word for word, whatever its spacing
  # and case, though the reader may have left some of it out), and each
  # number the rule uses (0 and 1 aside) stands in it with the words
  # around it as the card has them.
  def stated?(rule, from, text) do
    {quote, card} = {plain(from), plain(text)}

    numbers =
      ~r/\d+(?:\.\d+)?/
      |> Regex.scan(rule)
      |> List.flatten()
      |> Enum.reject(&(&1 in ["0", "1"]))
      |> Enum.uniq()

    String.length(quote) >= 6 and quoted?(quote, card) and
      Enum.all?(numbers, &in_place?(&1, quote, card))
  end

  @piece 16

  # Most of the quote, taken a piece at a time, is in the card.
  defp quoted?(quote, card) do
    letters = String.graphemes(quote)

    pieces =
      if length(letters) <= @piece,
        do: [quote],
        else: letters |> Enum.chunk_every(@piece, 8, :discard) |> Enum.map(&Enum.join/1)

    found = Enum.count(pieces, &String.contains?(card, &1))
    found * 10 >= length(pieces) * 7
  end

  # The number stands somewhere in the quote with the few letters on each
  # side of it as the card has them.
  defp in_place?(number, quote, card) do
    pattern = Regex.compile!("(?<![\\d.])" <> Regex.escape(number) <> "(?!\\.?\\d)")

    pattern
    |> Regex.scan(quote, return: :index)
    |> Enum.any?(fn [{at, length}] ->
      from = max(at - 12, 0)
      around = binary_part(quote, from, min(at + length + 12, byte_size(quote)) - from)
      # Cut to whole letters: the reach is counted in bytes.
      around = around |> String.replace_invalid("") |> String.trim()
      String.contains?(card, around)
    end)
  end

  defp plain(text),
    do: text |> String.downcase() |> String.replace(~r/[\s*_`]+/u, " ") |> String.trim()

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
        {"title": "the card's name", "characters": [{"name": "as the first message writes it, or when it does not name them, as the card does", "profile": "one or two sentences, in the first message's language: who they are and how they treat the player", "affinity": 0, "trust": 0}], "player": null, "status_window": null}

        player: the name of the player's own character, when the card or the first message gives one (a persona's name, written where the card had {{user}}), else null.

        affinity and trust are how the character feels about the player when the story starts, 0 to 100: 0 a stranger, 30 an acquaintance, 50 a close friend, 80 a lover or someone devoted. Use what the card says; when it does not say, 0.

        status_window: if the card tells the model to print a status window with every reply (a block of numbers and facts in a fixed format: level, HP, money, trust, date, place), give {"open": "the text that begins the block", "close": "the text that ends it", "rules": []}. Copy open and close from the card's format, and only characters that are the same in every reply, never a blank the model fills in: for a block between two "[Status Window]" lines, both are "[Status Window]"; for one line such as "[ Trust: 3% | Anger: 5% | ... ]", "[ Trust:" and "]"; for a block that begins with a heading such as "[Day N/30 · Time]", "[Day" as open; for a block of lines such as "◈Time: ..." that ends with the reply, "◈Time" as open and "" as close. If the card prints no such block, or only draws one with its own scripts and tells the model not to write the numbers, null.

        rules: the arithmetic the card states for the window's numbers, [] when the card states none. Go through the card's sentences that give a number for the window (a formula, a gain per point or per level, a range, a limit on change), and for each write {"from": "that sentence, copied word for word", "rule": "what it says, as one line in the small language below"}. A rule is used only when its sentence is found in the card and has the rule's numbers in it. Use the window's field names exactly as its format writes them; `Field.max` is the second number of a pair such as `HP: 30 / 48`, and `Field.before` is what the field was before the turn. There are only two kinds of line (the examples are not from this card):
        1. `Target = expression`, something that always holds: a maximum that follows a stat, "Stamina.max = Body * 4"; a range a number stays within, "Favor = clamp(Favor, 0, 100)"; a limit on how far a number moves in one turn, "Favor = clamp(Favor, Favor.before - 3, Favor.before + 3)".
        2. `when condition: change; change`, something that happens, each change being `Field = expression`, `Field += expression`, or `Field -= expression`; a card whose window has a level and experience toward the next one has its level-up line, in the window's own field names: "when EXP >= EXP.max: Level += 1; EXP -= EXP.max". The condition is a comparison, or `Field rises` for what each point gained gives: "when Level rises: Points += if(Level % 10 == 0, 6, 2)".
        An expression has numbers, field names, + - * / ^ %, comparisons (>= <= > < == !=), and, or, and the functions floor, ceil, round, min, max, clamp(x, low, high), if(condition, a, b). No other words, and every line begins with a field name or with `when`.
        Write only what the card itself states in numbers, for fields of its window, with the card's own numbers: never a guess, never one of the examples above, and nothing about text fields. Where the card gives no number ("the requirement grows with each level", a reputation with no range), there is no rule to write.
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
      player = player(data["player"])

      characters =
        characters
        |> Enum.filter(&(is_map(&1) and is_binary(&1["name"]) and String.trim(&1["name"]) != ""))
        # The player is not one of the people the player meets.
        |> Enum.reject(&(player != nil and Aethrion.Bridge.Scene.same?(&1["name"], player)))
        |> Enum.uniq_by(&Card.id_for(String.trim(&1["name"])))
        |> Enum.take(@max_people)

      {:ok,
       %{
         title: title(data["title"]),
         characters: characters,
         player: player,
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
      do: %{open: open, close: close, rules: rules(window["rules"])}
  end

  defp window(_none), do: nil

  # The card's arithmetic as the model wrote it down: a few short lines
  # (`Aethrion.Bridge.Ledger.Rules` reads them against the window), each
  # with the sentence of the card it was taken from.
  defp rules(rules) when is_list(rules) do
    rules
    |> Enum.flat_map(fn
      %{"rule" => rule, "from" => from} when is_binary(rule) and is_binary(from) ->
        for line <- lines(rule), do: {line, from}

      _other ->
        []
    end)
    |> Enum.filter(fn {rule, _from} -> rule != "" and String.length(rule) <= @max_rule end)
    |> Enum.uniq_by(fn {rule, _from} -> rule end)
    |> Enum.take(@max_window_rules)
  end

  defp rules(_none), do: []

  # A rule line as the reader wrote it may hold several: "A.max = B * 10;
  # C.max = D * 10", or one that always holds before "when ...". What
  # follows a `when` is its changes, to the end.
  defp lines(rule) do
    {lines, happening} =
      rule
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce({[], nil}, fn
        part, {lines, nil} ->
          if String.match?(part, ~r/\Awhen\b/i),
            do: {lines, part},
            else: {lines ++ [part], nil}

        part, {lines, happening} ->
          {lines, happening <> "; " <> part}
      end)

    lines ++ List.wrap(happening)
  end

  # The player's name as the card gives it, when it is a name.
  defp player(name) when is_binary(name) do
    name = name |> String.trim() |> String.slice(0, 40)
    if name != "" and not String.match?(name, ~r/\A\{\{|\Auser\z|\Aplayer\z/i), do: name
  end

  defp player(_none), do: nil

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
