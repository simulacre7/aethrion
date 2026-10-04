defmodule Aethrion.Bridge.Scene do
  @moduledoc """
  Who is with the player, as the narrating model says at the end of each
  reply, for a cast read from a card (`Aethrion.Bridge.AutoCast`): a card
  that narrates a world brings people in as the story goes, and the rules
  can only track the people they know of.

  The note asks the model for one last line (`instruction/0`):

      <aethrion-scene>
      Haruka | a quiet classmate from the library committee
      Kenji
      </aethrion-scene>

  It is taken out of the reply (`take/1`; `filter/1` holds it back from a
  reply being streamed) and kept in the status block's opening tag
  (`mark/2`), where the chat app does not show it and sends it back with
  the history. The next line is then read in that scene (`enter/2`):
  someone new joins the cast as a stranger, and those not named are away,
  so they do not see what the player does.
  """

  alias Aethrion.{Card, State}

  @tag "<aethrion-scene"
  @max_entries 8
  @max_people 16
  @max_name 40
  @max_profile 160
  # The player is not someone in the scene, whatever the model calls them.
  @player ["user", "{{user}}", "the user", "player", "the player", "you", "나", "플레이어", "유저"]

  @typedoc "Someone in a scene: a name, and for someone new a few words on who they are."
  @type entry :: %{name: String.t(), profile: String.t()}

  @doc "What the note asks of the model."
  @spec instruction() :: String.t()
  def instruction do
    "After everything else, end your reply with one more line: <aethrion-scene>...</aethrion-scene>, listing the named people who are with the player now and can be talked to, one per line. For someone listed under Now, the name alone, written exactly as it is listed there; for someone new, `Name | who they are, in a few words`. Leave out the player, and leave it empty when the player is alone. It is not shown to the player."
  end

  @doc """
  The reply without its scene line, and the scene: a list of entries, or
  nil when the model wrote none (the scene then stays as it was). The
  player, when the card names them (`player`), is no one in the scene.
  """
  @spec take(String.t(), String.t() | nil) :: {String.t(), [entry()] | nil}
  def take(text, player \\ nil) do
    # (To its closing tag; or, when the model left that out, to the next
    # tag of ours or the end.)
    case Regex.run(
           ~r/<aethrion-scene\b[^>]*>(.*?)(?:<\/aethrion-scene>|(?=<\/?(?:aeth|ledger))|\z)/s,
           text,
           return: :index
         ) do
      [{start, length}, {from, size}] ->
        rest =
          binary_part(text, 0, start) <>
            binary_part(text, start + length, byte_size(text) - start - length)

        named = entries(binary_part(text, from, size), ~r/[\n;]/)
        others = if player, do: Enum.reject(named, &same?(&1.name, player)), else: named

        # A model that lists only the player has not said who is there:
        # the scene stays as it was.
        {String.trim(rest), if(named != [] and others == [], do: nil, else: others)}

      nil ->
        {text, nil}
    end
  end

  @doc """
  A filter for a reply as it is streamed: `{on_delta, flush}`. `on_delta`
  passes each piece on to `emit` except the scene line, and what might be
  its beginning until more has come; `flush` passes on what was held back
  and turned out not to be one. Both are called from one process.
  """
  @spec filter((String.t() -> any())) :: {(String.t() -> any()), (-> any())}
  def filter(emit) do
    key = {__MODULE__, make_ref()}

    on_delta = fn delta ->
      case Process.get(key, "") do
        :scene ->
          :ok

        held ->
          text = held <> delta

          case :binary.match(text, @tag) do
            {at, _length} ->
              pass(emit, binary_part(text, 0, at))
              Process.put(key, :scene)

            :nomatch ->
              keep = held_back(text)
              pass(emit, binary_part(text, 0, byte_size(text) - byte_size(keep)))
              Process.put(key, keep)
          end
      end
    end

    flush = fn ->
      case Process.delete(key) do
        held when is_binary(held) -> pass(emit, held)
        _scene_or_nothing -> :ok
      end
    end

    {on_delta, flush}
  end

  defp pass(_emit, ""), do: :ok
  defp pass(emit, text), do: emit.(text)

  # The end of the text that may be the beginning of the tag.
  defp held_back(text) do
    1..(byte_size(@tag) - 1)
    |> Enum.reverse()
    |> Enum.find_value("", fn n ->
      if byte_size(text) >= n and
           binary_part(text, byte_size(text) - n, n) == binary_part(@tag, 0, n),
         do: binary_part(@tag, 0, n)
    end)
  end

  @doc "The status block with the scene in its opening tag (nil: as it is)."
  @spec mark(String.t(), [entry()] | nil) :: String.t()
  def mark(status, nil), do: status

  def mark(status, entries) do
    scene =
      Enum.map_join(entries, ";", fn
        %{name: name, profile: ""} -> name
        %{name: name, profile: profile} -> name <> "|" <> profile
      end)

    # The scene is written as it is: none of it is read as a place in the pattern.
    String.replace(status, ~r/\A<aethrion-status\b[^>]*/, &(&1 <> ~s( scene="#{scene}")),
      global: false
    )
  end

  @doc "The scene a reply's status block carries, or nil."
  @spec marked(String.t()) :: [entry()] | nil
  def marked(reply) do
    case Regex.run(~r/<aethrion-status\b[^>]*?\sscene="([^"]*)"/, reply) do
      [_all, scene] -> entries(scene, ~r/;/)
      nil -> nil
    end
  end

  # What comes back from a model or from a chat app's history is cut to
  # size, and cannot break out of the tag it is kept in.
  defp entries(text, separator) do
    text
    |> String.split(separator)
    |> Enum.map(fn line ->
      {name, profile} =
        case String.split(line, "|", parts: 2) do
          [name, profile] -> {name, profile}
          [name] -> {name, ""}
        end

      %{name: clean(name, @max_name), profile: clean(profile, @max_profile)}
    end)
    |> Enum.reject(&(&1.name == "" or key(&1.name) in @player))
    |> Enum.uniq_by(&key(&1.name))
    |> Enum.take(@max_entries)
  end

  defp clean(text, max) do
    text
    |> String.replace(~r/["<>;|\r\n]/, " ")
    |> String.replace(~r/^\s*[-*•]\s*/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, max)
    |> String.trim()
  end

  @doc """
  The world in that scene: those named are there, someone new joins as a
  stranger to the player (until the cast has #{@max_people}), and everyone
  else is away.
  """
  @spec enter(State.t(), [entry()]) :: State.t()
  def enter(%State{} = state, entries) do
    known = for c <- State.sorted_characters(state), State.stat(state, c.id, "enemy") == 0, do: c

    {here, new} =
      Enum.reduce(entries, {[], []}, fn entry, {here, new} ->
        case Enum.find(known, &same?(&1.name, entry.name)) do
          nil -> {here, new ++ [entry]}
          character -> {[character.id | here], new}
        end
      end)

    new = Enum.take(new, max(@max_people - length(known), 0))
    data = State.to_data(state)

    {characters, relationships, ids} =
      Enum.reduce(new, {[], [], MapSet.new(Map.keys(state.characters))}, fn entry,
                                                                            {cs, rs, ids} ->
        id = unique(Card.id_for(entry.name), ids)
        character = %{"id" => id, "name" => entry.name}

        character =
          if entry.profile == "",
            do: character,
            else: Map.put(character, "profile", entry.profile)

        relationship = %{"from" => id, "to" => "user", "affinity" => 0, "trust" => 0}
        {cs ++ [character], rs ++ [relationship], MapSet.put(ids, id)}
      end)

    here = MapSet.new(here)

    stats =
      Enum.reduce(known, Map.get(data, "stats", %{}), fn c, stats ->
        away = if MapSet.member?(here, c.id), do: 0, else: 1
        current = get_in(stats, [c.id, "away"]) || 0

        if current == away,
          do: stats,
          else: Map.update(stats, c.id, %{"away" => away}, &Map.put(&1, "away", away))
      end)

    _ = ids

    data
    |> Map.update("characters", characters, &(&1 ++ characters))
    |> Map.update("relationships", relationships, &(&1 ++ relationships))
    |> Map.put("stats", stats)
    |> State.parse()
    |> case do
      {:ok, entered} -> %{entered | story: state.story}
      {:error, _error} -> state
    end
  end

  defp unique(id, ids) do
    if MapSet.member?(ids, id),
      do: Enum.find_value(2..99, &if(not MapSet.member?(ids, "#{id}_#{&1}"), do: "#{id}_#{&1}")),
      else: id
  end

  # The same person under a shorter or a fuller name ("Haruka" and "Haruka
  # Minase", "무명" and "무명 (無名)"), or under the same name in the other
  # script: a card written in English and played in Korean has "최승규" in
  # its story and "Choi Seung-gyu" in its image commands.
  @doc false
  def same?(a, b) do
    {ka, kb} = {key(a), key(b)}
    {short, long} = if String.length(ka) <= String.length(kb), do: {ka, kb}, else: {kb, ka}

    short != "" and
      (short == long or String.starts_with?(long, short <> " ") or
         String.ends_with?(long, " " <> short) or sounds_alike?(ka, kb))
  end

  # A Hangul name and a Latin one that are the same consonants, as Korean
  # is romanized (give or take one, for the ways a family name is spelled).
  defp sounds_alike?(a, b) do
    case {String.match?(a, ~r/\p{Hangul}/u), String.match?(b, ~r/\p{Hangul}/u)} do
      {true, false} -> korean?(a, b)
      {false, true} -> korean?(b, a)
      _same_script -> false
    end
  end

  # A family name that begins with no consonant in Hangul is often spelled
  # with one in Latin letters: 이 as Lee, 임 as Lim, 유 as Ryu.
  defp korean?(hangul, latin) do
    {h, l} = {hangul_consonants(hangul), latin_consonants(latin)}

    alike?(h, l) or
      (String.match?(hangul, ~r/\A[\x{C544}-\x{C78F}]/u) and String.starts_with?(l, "l") and
         alike?("l" <> h, l))
  end

  defp alike?(a, b) when a == b, do: String.length(a) >= 2

  defp alike?(a, b),
    do: min(String.length(a), String.length(b)) >= 4 and String.jaro_distance(a, b) >= 0.9

  @initials ~w(k k n t t l m p p s s) ++ [""] ++ ~w(c c c k t p h)
  @finals [""] ++ ~w(k k k n n n t l k m l l l p l m p p t t q t t k t p t)

  # The consonants of Hangul syllables, in classes that Latin spellings share.
  defp hangul_consonants(name) do
    for <<c::utf8 <- name>>, c in 0xAC00..0xD7A3, into: "" do
      n = c - 0xAC00
      Enum.at(@initials, div(n, 588)) <> Enum.at(@finals, rem(n, 28))
    end
  end

  defp latin_consonants(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z]/, "")
    |> String.replace("ng", "q")
    |> String.replace(~r/ch|j|z/, "c")
    |> String.replace("sh", "s")
    # An "h" that begins a syllable is ㅎ ("Hansol", "Yeon-hee"); one that
    # ends it is only how the vowel is spelled ("Noh").
    |> String.replace(~r/h(?![aeiouwy])/, "")
    |> String.replace(~r/[aeiouwy]/, "")
    |> String.replace(~r/[gkq]/, fn
      "q" -> "q"
      _k -> "k"
    end)
    |> String.replace(~r/[dt]/, "t")
    |> String.replace(~r/[bpfv]/, "p")
    |> String.replace("r", "l")
    |> String.replace("x", "s")
    |> String.replace(~r/(.)\1+/, "\\1")
  end

  defp key(name),
    do:
      name
      |> String.downcase()
      |> String.replace(~r/[()\[\],.]/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
end
