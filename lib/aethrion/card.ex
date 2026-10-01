defmodule Aethrion.Card do
  @moduledoc """
  Character cards, the files AI chat apps (RisuAI, SillyTavern, and others)
  share characters in, read into a cast.

  A card is JSON in one of three shapes, V1 (fields at the top), V2
  (`{"spec": "chara_card_v2", "data": {...}}`), or V3 (`"chara_card_v3"`,
  https://github.com/kwaroran/character-card-spec-v3), carried as a `.json`
  file, inside a PNG (a `tEXt` chunk `ccv3` or `chara`, base64), or in a
  CHARX zip (`card.json`).

  `to_cast/2` turns one into cast data `Aethrion.State.parse/2` takes: a
  character whose profile is the card's description, personality, and
  scenario, whose voice comes from its example messages, and whose
  greeting is its first message; a relationship toward the player to
  start from; and the card's lorebook as the story's `lore`, which is shown
  to the model when its keys come up. Cards hold no game numbers, so
  relationships start neutral and there are no stats or endings: those are
  added in the cast (the editor at `/editor`).

  Scripts some apps keep in a card (RisuAI's regex and trigger scripts,
  under `extensions.risuai`) are not run; `to_cast/2` lists what it left out.
  """

  @png <<137, 80, 78, 71, 13, 10, 26, 10>>
  @max_text 20_000

  @doc "Reads a card from a file's bytes: `{:ok, data}` (the card's fields) or `{:error, reason}`."
  @spec read(binary()) :: {:ok, map()} | {:error, term()}
  def read(<<@png, rest::binary>>), do: rest |> png_text() |> decode_embedded()
  def read(<<"PK", _::binary>> = zip), do: charx(zip)

  # RisuRealm also serves a JPEG with the CHARX zip appended.
  def read(<<0xFF, 0xD8, _::binary>> = jpeg) do
    case :binary.match(jpeg, <<"PK", 3, 4>>) do
      {at, _} -> jpeg |> binary_part(at, byte_size(jpeg) - at) |> charx()
      :nomatch -> {:error, :no_card_in_jpeg}
    end
  end

  def read(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, json} -> normalize(json)
      {:error, _} -> {:error, :not_a_card}
    end
  end

  @doc "The card's fields from any card JSON (V1, V2, or V3)."
  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(%{"spec" => spec, "data" => %{} = data})
      when spec in ["chara_card_v2", "chara_card_v3"],
      do: check(data)

  def normalize(%{"name" => _} = v1), do: check(v1)
  def normalize(_json), do: {:error, :not_a_card}

  defp check(%{"name" => name} = data) when is_binary(name) and name != "", do: {:ok, data}
  defp check(_data), do: {:error, :no_name}

  # PNG chunks: V3 ("ccv3") wins over V2 ("chara") when a card has both.
  defp png_text(bytes, found \\ %{})

  defp png_text(<<length::32, type::binary-size(4), rest::binary>>, found)
       when byte_size(rest) >= length + 4 do
    <<data::binary-size(^length), _crc::32, next::binary>> = rest

    found =
      case {type, :binary.split(data, <<0>>)} do
        {"tEXt", [keyword, text]} when keyword in ["ccv3", "chara"] ->
          Map.put(found, keyword, text)

        _other ->
          found
      end

    if type == "IEND", do: found, else: png_text(next, found)
  end

  defp png_text(_bytes, found), do: found

  defp decode_embedded(found) do
    case Map.get(found, "ccv3") || Map.get(found, "chara") do
      nil ->
        {:error, :no_card_in_png}

      text ->
        with {:ok, json} <-
               Base.decode64(String.trim(text), ignore: :whitespace) |> ok_or(:bad_base64),
             {:ok, card} <- Jason.decode(json) do
          normalize(card)
        else
          {:error, %Jason.DecodeError{}} -> {:error, :bad_json}
          error -> error
        end
    end
  end

  # RisuAI keeps a card's scripts in module.risum beside card.json.
  defp charx(zip) do
    with {:ok, [{_name, json}]} <- :zip.unzip(zip, [:memory, {:file_list, [~c"card.json"]}]),
         {:ok, data} <- read(json) do
      {:ok, if(module?(zip), do: Map.put(data, "__risu_module", true), else: data)}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :no_card_json}
    end
  end

  defp module?(zip) do
    case :zip.list_dir(zip) do
      {:ok, entries} -> Enum.any?(entries, &match?({:zip_file, ~c"module.risum", _, _, _, _}, &1))
      _error -> false
    end
  end

  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or({:ok, value}, _reason), do: {:ok, value}

  @doc """
  Cast data for a card, and notes on what was left out. Options: `:id` (the
  character's id; by default from the name), `:player` (what `{{user}}`
  becomes in the card's text; default `"user"`).
  """
  @spec to_cast(map(), keyword()) :: {map(), [String.t()]}
  def to_cast(data, opts \\ []) do
    name = text(data["name"])
    id = Keyword.get(opts, :id) || id_for(name)
    fill = &fill(&1, name, Keyword.get(opts, :player, "user"))

    profile =
      [data["description"], data["personality"], data["scenario"]]
      |> Enum.map(&fill.(text(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    character =
      %{
        "id" => id,
        "name" => name,
        "profile" => cap(profile),
        "voice" => cap(voice(fill.(text(data["mes_example"]))))
      }
      |> put_text("greeting", cap(fill.(text(data["first_mes"]))))

    lore = lore(data, fill)

    cast = %{
      "characters" => [character],
      "relationships" => [%{"from" => id, "to" => "user", "affinity" => 0, "trust" => 0}]
    }

    cast = if lore == [], do: cast, else: Map.put(cast, "story", %{"lore" => lore})
    {cast, notes(data)}
  end

  @doc """
  Adds a card's cast to an existing cast: its character (replacing one with
  the same id), its relationship toward the player, and its lore.
  """
  @spec merge(map(), map()) :: map()
  def merge(cast, card_cast) do
    [character] = card_cast["characters"]
    id = character["id"]

    cast
    |> Map.update(
      "characters",
      [character],
      &(Enum.reject(&1, fn c -> c["id"] == id end) ++ [character])
    )
    |> Map.update("relationships", card_cast["relationships"], fn rels ->
      Enum.reject(rels, &(&1["from"] == id and &1["to"] == "user")) ++ card_cast["relationships"]
    end)
    |> then(fn cast ->
      case get_in(card_cast, ["story", "lore"]) do
        nil ->
          cast

        lore ->
          Map.update(
            cast,
            "story",
            %{"lore" => lore},
            &Map.update(&1, "lore", lore, fn old -> old ++ lore end)
          )
      end
    end)
  end

  # Example messages say how a character talks; kept as they are, without
  # the <START> separators.
  defp voice(""), do: ""

  defp voice(examples) do
    lines =
      examples
      |> String.replace(~r/<START>/i, "")
      |> String.split(~r/\R/u, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(12)

    "How they talk, from example messages:\n" <> Enum.join(lines, "\n")
  end

  # RisuAI writes decorators (`@@depth 0`) on a note's first lines and keeps
  # folders as notes keyed `folder:<id>`; neither is world text.
  defp lore(%{"character_book" => %{"entries" => entries}}, fill) when is_list(entries) do
    for %{"content" => content} = entry <- entries,
        is_binary(content),
        Map.get(entry, "enabled", true) != false,
        keys = Enum.filter(List.wrap(entry["keys"]), &(is_binary(&1) and String.trim(&1) != "")),
        not Enum.any?(keys, &String.starts_with?(&1, "folder:")),
        content = strip_decorators(content),
        content != "",
        not risu_macros?(content),
        keys != [] or entry["constant"] == true do
      %{"keys" => Enum.map(keys, &String.trim/1), "content" => cap(fill.(content))}
      |> then(&if(entry["constant"] == true, do: Map.put(&1, "constant", true), else: &1))
    end
    |> Enum.take(500)
  end

  defp lore(_data, _fill), do: []

  # Notes built from RisuAI's template macros ({{#if}}, {{getglobalvar}})
  # are instructions to RisuAI, not facts of the world.
  @macros ~r/\{\{\s*(#if|#when|#each|getvar|getglobalvar|setvar|addvar|\?)/
  defp risu_macros?(content), do: Regex.match?(@macros, content)

  defp strip_decorators(content) do
    content
    |> String.split(~r/\R/u)
    |> Enum.drop_while(&String.starts_with?(String.trim_leading(&1), "@@"))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp notes(data) do
    risu = get_in(data, ["extensions", "risuai"]) || %{}

    [
      {List.wrap(risu["customScripts"]) != [] or data["__risu_module"] == true,
       "RisuAI regex and trigger scripts are not run"},
      {is_binary(risu["backgroundHTML"]) and risu["backgroundHTML"] != "",
       "the background HTML is not shown"},
      {List.wrap(data["alternate_greetings"]) != [],
       "alternate greetings are not used (the first message is)"},
      {is_binary(data["system_prompt"]) and data["system_prompt"] != "",
       "the card's system prompt is not used"},
      {List.wrap(data["assets"]) not in [[], [%{"type" => "icon"}]],
       "images and other assets are not imported"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Kernel.++(macro_note(data))
  end

  defp macro_note(%{"character_book" => %{"entries" => entries}}) when is_list(entries) do
    case Enum.count(entries, &(is_binary(&1["content"]) and risu_macros?(&1["content"]))) do
      0 -> []
      1 -> ["1 lore note written for RisuAI's macros is left out"]
      n -> ["#{n} lore notes written for RisuAI's macros are left out"]
    end
  end

  defp macro_note(_data), do: []

  # {{char}} and {{user}} are the card's placeholders for the two names.
  defp fill(text, name, player) do
    text
    |> String.replace(~r/\{\{\s*char\s*\}\}|<BOT>/i, name)
    |> String.replace(~r/\{\{\s*user\s*\}\}|<USER>/i, player)
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp cap(text), do: String.slice(text, 0, @max_text)

  defp put_text(map, _key, ""), do: map
  defp put_text(map, key, value), do: Map.put(map, key, value)

  @doc false
  # An id from a name: Latin letters and digits as they are, anything else
  # (a Korean name, say) a short stable hash.
  def id_for(name) do
    # Accents come off (Lázaro is lazaro); a name that is mostly not Latin
    # letters (서윤, 범용상태창 v2) gets a hash, not a stray fragment.
    plain =
      name
      |> :unicode.characters_to_nfd_binary()
      |> String.replace(~r/\p{Mn}/u, "")

    latin = plain |> String.replace(~r/[^A-Za-z]/, "") |> String.length()
    letters = plain |> String.replace(~r/[^\p{L}]/u, "") |> String.length()

    slug =
      if latin * 2 < letters,
        do: "",
        else:
          plain
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "_")
          |> String.trim("_")
          |> String.slice(0, 24)

    if slug == "",
      do:
        "char_" <>
          (:crypto.hash(:sha256, name) |> Base.encode16(case: :lower) |> binary_part(0, 8)),
      else: slug
  end
end
