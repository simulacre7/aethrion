defmodule Aethrion.Combat do
  @moduledoc """
  Fights for AI chat and games, decided by the numbers like everything else:
  the same moves always end the same way, and every hp change is traced.

  Fighters are actors with an `"hp"` stat, players and characters alike:

  ```json
  "stats": {
    "user":   {"hp": 30, "max_hp": 30, "attack": 6, "defense": 2, "speed": 3},
    "mina":   {"hp": 20, "max_hp": 20, "attack": 3, "defense": 1, "heal": 8},
    "goblin": {"hp": 18, "max_hp": 18, "attack": 5, "defense": 1, "speed": 2}
  }
  ```

  Events: `Aethrion.Event.attack/3`, `defend/2`, `heal/3`, `flee/3` (or
  `{"type": "attack", "from": "user", "to": "goblin"}` in JSON). Outputs are
  `:combat` maps: `kind` (`:hit`, `:critical`, `:defeated`, `:guarded`,
  `:healed`, `:fled`, `:caught`, `:holds_back`), `character_id` (who acted),
  `to`,
  `subject` (whose hp is reported), `amount`, `hp`, `max_hp`, and an English
  `text`; `describe/3` tells it in Korean. A model can narrate the scene from
  these numbers; the numbers stay the rules'. See `Aethrion.Rules.Combat` for
  the formulas and how fighting changes relationships.

  In a chat, `action/4` turns what a player typed ("I swing my sword at
  the goblin", "방패로 막는다", "포션을 마신다") into one of those events;
  the HTTP API does this at `POST /worlds/{key}/act`.
  """

  alias Aethrion.{Event, State}
  alias Aethrion.Expression.Templates.Ko

  @doc false
  # A roll from 0 to 5 that depends only on who acts on whom, where the
  # fight stands (their hp), and the actor's turn count, so a replayed
  # fight goes the same way, saying something in between does not change
  # the dice, and the same standoff does not repeat the same blow.
  def roll(event, %State{} = state) do
    to = Map.get(event, :to)

    :erlang.phash2(
      {event.type, event.from, to, State.stat(state, event.from, "hp"),
       State.stat(state, to, "hp"), State.stat(state, event.from, "turns")},
      6
    )
  end

  @doc false
  def guard_key(id), do: "combat:guard:#{id}"

  @doc false
  def held_key(id), do: "combat:held:#{id}"

  @doc """
  Whether the story is over: its ending was decided (`Aethrion.Story`),
  after which no one fights.
  """
  @spec over?(State.t()) :: boolean()
  def over?(%State{} = state), do: Aethrion.Rules.Ending.reached?(state)

  ## Reading what a player typed

  # Verbs, not just words: "막걸리병으로 내려친다" strikes, "늑대왕에게
  # 소리친다" does not, "I strike past its guard" attacks. Attacks are read
  # before guards, since a blow often mentions a shield; potions before
  # attacks, since a potion can be thrown.
  @attack ~r/(벤다|베어|베고|벤 |벰|찌른|찌르|찔러|(?<!도망|소리|외)(?:친다|치고|쳐서)|(?<!도망)쳐(?=$|[\s!.~?])|때린|때려|휘두른|휘둘|공격|반격|내려친|후려친|일격|날린|날려|쏜다|쏘아|쏴|베기|돌진|달려든|처치|따버|던진|던져|물어뜯|마법|주문을|파이어볼|화염구)|\b(attack|attacks|strike|strikes|hit|hits|slash|stab|swing|swings|bash|smash|shoot|cut|charge|charges|punch|kick|thrust|lunge|throw|fireball|spell|magic)\b/u
  @defend ~r/(막는|막아|막았|막자|막고|막으|방어|방패를 (들|세|올)|방패를 든|웅크|감싸|지킨|지켜|버틴|버텨|숨을 고르|숨을 고른|숨을 돌|기다린|버티|맞선)|\b(defend|guard|block|parry|brace|protect|cover|wait|stand)\b/u
  @heal ~r/(치료|회복|포션|물약|붕대|상처를 (감|싸))|\b(heal|potion|bandage|cure|patch)\b/u
  @items ~r/(포션|물약|붕대)|\b(potion|bandage)\b/u
  @flee ~r/(도망|후퇴|달아나|달아난|피신|튀자|튀어|튄다|빠져나)|\b(flee|escape|retreat|run away|run)\b/u
  # Asking someone else: "리아, 나 좀 치료해줘", "heal me, Ria".
  @asks ~r/(해\s?줘|해\s?주세요|해\s?줄래|부탁)|\b(heal me|patch me up|help me)\b/u
  # What is ruled out: "늑대왕 말고 카엘을", "공격하지 말고 기다린다",
  # "도망치지 않고 벤다", "절대 후퇴하지 않는다", "I won't run away".
  @ruled_out ~r/\S+\s*(?:말고|않고)|\S+지\s*(?:않|말)\S*|\b(?:not|never|won't|don't|can't)\s+(?:\w+\s+)?\w+(?:\s+away)?/u

  @doc """
  The combat event a player's words mean, or `nil` when they do not say
  (a chat can ask again rather than lose the player's turn).

  A blow, a throw, or a spell attacks whoever the words name (an enemy
  first), else `target`, else the first enemy standing (`foe/1`). A guard
  ("막는다", "리아를 감싼다", "기다린다") defends. A heal tends whoever the
  words name (a companion first) or a companion given as `target`, else
  the player; a potion someone drinks is their own, and asking a
  companion who heals ("리아, 치료해줘") has them heal the player. Fleeing
  runs from an enemy. "X 말고" and "X하지 말고" rule X out.

      action(state, "user", "wolf", "I swing my sword!")       # attack
      action(state, "user", nil, "방패를 들어 막는다")          # defend
      action(state, "user", nil, "포션을 마신다")               # heal, themselves
      action(state, "user", nil, "리아, 나 좀 치료해줘")        # Ria heals the player
  """
  @spec action(State.t(), String.t(), String.t() | nil, String.t()) :: Event.t() | nil
  def action(%State{} = state, from, target, text) when is_binary(text) do
    words = text |> String.downcase() |> then(&Regex.replace(@ruled_out, &1, " "))
    # With enemies in the world, a blow or an escape is aimed at one of them
    # unless the host names someone else as the target.
    only? = foe(state) != nil
    foe = named(state, words, "enemy", only: only?) || target || foe(state)

    case reading(state, words, from, foe) do
      :asked ->
        Event.heal(healer(state, words, from), from)

      :heal ->
        heal(state, from, target, words)

      :attack ->
        Event.attack(from, foe, skill: skill(text), observed_by: party(state) -- [from, foe])

      :defend ->
        Event.defend(from, to: shielded(state, words, from))

      :flee ->
        Event.flee(from, foe)

      nil ->
        nil
    end
  end

  defp reading(state, words, from, foe) do
    cond do
      Regex.match?(@heal, words) and Regex.match?(@asks, words) and healer(state, words, from) ->
        :asked

      Regex.match?(@items, words) ->
        :heal

      Regex.match?(@attack, words) and foe != nil ->
        :attack

      Regex.match?(@heal, words) ->
        :heal

      Regex.match?(@defend, words) ->
        :defend

      Regex.match?(@flee, words) and foe != nil ->
        :flee

      true ->
        nil
    end
  end

  # A companion the words name ("리아를 감싼다") is shielded.
  defp shielded(state, words, from) do
    case named(state, words, "party", only: true) do
      ^from -> nil
      id -> id
    end
  end

  defp heal(state, from, target, words) do
    to =
      cond do
        drinks?(words) -> from
        named = named(state, words, "party") -> named
        target != nil and State.stat(state, target, "party") > 0 -> target
        true -> from
      end

    Event.heal(from, to, item: item(state, from, words))
  end

  # A companion named in a request who can heal.
  defp healer(state, words, from) do
    case named(state, words, "heal") do
      nil -> nil
      ^from -> nil
      id -> if State.stat(state, id, "heal") > 0, do: id
    end
  end

  @doc """
  The first enemy still standing (an actor with an `"enemy"` stat and hp
  left), or nil: who a player means when they just say "I attack".
  """
  @spec foe(State.t()) :: String.t() | nil
  def foe(%State{stats: stats} = state) do
    stats
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find(&(State.stat(state, &1, "enemy") > 0 and State.stat(state, &1, "hp") > 0))
  end

  @doc """
  The companions: characters with a `"party"` stat, who see what the player
  does in a fight.
  """
  @spec party(State.t()) :: [String.t()]
  def party(%State{stats: stats} = state) do
    for id <- Enum.sort(Map.keys(stats)),
        State.character?(state, id),
        State.stat(state, id, "party") > 0,
        do: id
  end

  # Who the words name ("늑대왕을 벤다", "heal Ria"), by name or id, as a
  # word ("aerial" does not name Ria; "리아를" does). With several named,
  # one with the `prefer` stat (an enemy to strike, a companion to heal)
  # wins, then the longest name. `only: true` takes only those with it.
  defp named(state, words, prefer, opts \\ []) do
    state
    |> State.sorted_characters()
    |> Enum.flat_map(fn c -> [{String.downcase(c.name), c.id}, {String.downcase(c.id), c.id}] end)
    |> Enum.filter(fn {name, id} ->
      name != "" and says?(words, name) and
        (not Keyword.get(opts, :only, false) or State.stat(state, id, prefer) > 0)
    end)
    |> Enum.max_by(
      fn {name, id} -> {State.stat(state, id, prefer) > 0, String.length(name)} end,
      fn -> {nil, nil} end
    )
    |> elem(1)
  end

  # Not inside another word: nothing letter-like before it, and for a
  # Latin name nothing Latin after it (Korean particles may follow).
  defp says?(words, name) do
    after_name = if name =~ ~r/[a-z0-9]$/u, do: "(?![a-z0-9])", else: ""

    Regex.match?(
      Regex.compile!("(?<![\\p{L}\\p{N}])" <> Regex.escape(name) <> after_name, "u"),
      words
    )
  end

  # Drinking a potion is for oneself, whoever was being talked to.
  defp drinks?(words), do: Regex.match?(~r/(마신|마셔|들이켜|들이킨)|\b(drink|drinks|quaff|gulp)\b/u, words)

  # A potion or a bandage when they say so; someone with no healing of
  # their own reaches for a potion if they have one.
  defp item(state, from, words) do
    cond do
      String.contains?(words, ["potion", "포션", "물약"]) -> "potion"
      String.contains?(words, ["bandage", "붕대"]) -> "bandage"
      State.stat(state, from, "heal") == 0 and State.stat(state, from, "potions") > 0 -> "potion"
      true -> nil
    end
  end

  # What they used, for narration: the player's own words, kept short.
  defp skill(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    if String.length(text) <= 60, do: text, else: nil
  end

  ## Telling it

  @doc """
  A combat output in words, in `:en` or `:ko`, with names from `state` (the
  user is "you" / "너").
  """
  @spec describe(map(), State.t(), :en | :ko) :: String.t()
  def describe(output, %State{} = state, locale) do
    name = &name(state, &1, locale)
    output = with_traits(output, state)
    told(locale, output.kind, output, name, hp_suffix(output, name, locale))
  end

  defp told(:en, kind, output, name, hp) when kind in [:hit, :critical] do
    by = output.character_id
    critical = if kind == :critical, do: "Critical! ", else: ""

    critical <>
      capitalize(
        "#{name.(by)} #{verb(by, "hit")} #{name.(output.to)} for #{output.amount}#{guarded(output, :en)}.#{hp}"
      )
  end

  defp told(:en, :defeated, %{character_id: by}, name, _hp),
    do: capitalize("#{name.(by)} #{if by == "user", do: "fall", else: "falls"}.")

  defp told(:en, :guarded, %{character_id: by, to: to}, name, _hp) when is_binary(to),
    do: capitalize("#{name.(by)} #{verb(by, "shield")} #{name.(to)}.")

  defp told(:en, :guarded, %{character_id: by}, name, _hp),
    do: capitalize("#{name.(by)} #{verb(by, "raise")} a guard.")

  defp told(:en, :healed, %{character_id: by, to: by} = output, name, hp),
    do:
      capitalize(
        "#{name.(by)} #{verb(by, "heal")} #{if by == "user", do: "yourself", else: "themselves"} for #{output.amount}.#{hp}"
      )

  defp told(:en, :healed, %{character_id: by} = output, name, hp),
    do:
      capitalize(
        "#{name.(by)} #{verb(by, "heal")} #{name.(output.to)} for #{output.amount}.#{hp}"
      )

  defp told(:en, :holds_back, %{character_id: by}, name, _hp),
    do: capitalize("#{name.(by)} #{verb(by, "hold")} back and #{verb(by, "watch", "watches")}.")

  defp told(:en, :fled, %{character_id: by, to: to}, name, _hp),
    do: capitalize("#{name.(by)} #{verb(by, "get")} away from #{name.(to)}.")

  defp told(:en, :caught, %{character_id: by, to: to}, name, _hp) do
    them = if by == "user", do: "you", else: "them"

    capitalize(
      "#{name.(by)} #{verb(by, "try", "tries")} to flee, but #{name.(to)} #{verb(to, "cut")} #{them} off."
    )
  end

  defp told(:ko, kind, output, name, hp) when kind in [:hit, :critical] do
    critical = if kind == :critical, do: "치명타! ", else: ""

    "#{critical}#{Ko.subject(name.(output.character_id))} #{name.(output.to)}에게 " <>
      "#{output.amount}의 피해를 입혔다.#{guarded(output, :ko)}#{hp}"
  end

  defp told(:ko, :defeated, %{character_id: by}, name, _hp), do: "#{Ko.subject(name.(by))} 쓰러졌다."

  defp told(:ko, :guarded, %{character_id: by, to: to}, name, _hp) when is_binary(to),
    do:
      "#{Ko.with_particle(name.(by), :topic)} #{Ko.with_particle(name.(to), :object)} 감싸며 방패를 들었다."

  defp told(:ko, :guarded, %{character_id: by}, name, _hp),
    do: "#{Ko.with_particle(name.(by), :topic)} 방어 자세를 취했다."

  defp told(:ko, :healed, %{character_id: by, to: by} = output, name, hp),
    do: "#{Ko.with_particle(name.(by), :topic)} 체력을 #{output.amount} 회복했다.#{hp}"

  defp told(:ko, :healed, %{character_id: by, to: to} = output, name, hp) do
    whose = if to == "user", do: "네", else: "#{name.(to)}의"
    "#{Ko.subject(name.(by))} #{whose} 상처를 #{output.amount}만큼 치료했다.#{hp}"
  end

  defp told(:ko, :holds_back, %{character_id: by} = output, name, _hp) do
    if :sensitive in Map.get(output, :traits, []),
      do: "#{Ko.with_particle(name.(by), :topic)} 머뭇거리다 한 발 물러섰다.",
      else: "#{Ko.with_particle(name.(by), :topic)} 팔짱을 낀 채 지켜보기만 했다."
  end

  defp told(:ko, :fled, %{character_id: by, to: to}, name, _hp),
    do: "#{Ko.with_particle(name.(by), :topic)} #{name.(to)}에게서 무사히 도망쳤다."

  defp told(:ko, :caught, %{character_id: by, to: to}, name, _hp),
    do: "#{Ko.with_particle(name.(by), :topic)} 도망치려 했지만 #{Ko.subject(name.(to))} 막아섰다."

  defp with_traits(%{kind: :holds_back, character_id: id} = output, state) do
    case State.character(state, id) do
      nil -> output
      character -> Map.put(output, :traits, character.traits)
    end
  end

  defp with_traits(output, _state), do: output

  defp hp_suffix(%{max_hp: max, hp: hp, subject: subject}, name, _locale) when is_integer(max),
    do: " (#{name.(subject)} #{hp}/#{max})"

  defp hp_suffix(_output, _name, _locale), do: ""

  defp guarded(%{guarded: true}, :en), do: ", through a raised guard"
  defp guarded(%{guarded: true}, :ko), do: " 방어 덕에 절반만 들어갔다."
  defp guarded(_output, _locale), do: ""

  defp name(_state, "user", :en), do: "you"
  defp name(_state, "user", :ko), do: "너"
  defp name(state, id, _locale), do: State.name(state, id)

  defp verb(actor, base, third \\ nil)
  defp verb("user", base, _third), do: base
  defp verb(_actor, base, nil), do: base <> "s"
  defp verb(_actor, _base, third), do: third

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
