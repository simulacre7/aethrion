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
  # A roll from 0 to 5 that depends only on who acts on whom and where the
  # fight stands (their hp), so a replayed fight goes the same way, and
  # saying something in between does not change the dice.
  def roll(event, %State{} = state) do
    to = Map.get(event, :to)

    :erlang.phash2(
      {event.type, event.from, to, State.stat(state, event.from, "hp"),
       State.stat(state, to, "hp")},
      6
    )
  end

  @doc false
  def guard_key(id), do: "combat:guard:#{id}"

  @doc false
  def held_key(id), do: "combat:held:#{id}"

  @doc """
  Whether a fight story is over: its ending was decided by one of its
  `decide_when` conditions (`Aethrion.Story`), after which no one fights.
  """
  @spec over?(State.t()) :: boolean()
  def over?(%State{story: story} = state),
    do: Map.get(story, :decide_when, []) != [] and Aethrion.Rules.Ending.reached?(state)

  ## Reading what a player typed

  # Verbs, not just words: "막걸리병으로 내려친다" strikes, "도망치지 않고
  # 벤다" does not flee, "I strike past its guard" attacks. Attacks are read
  # first, since a blow often mentions a shield or a guard.
  @attack ~r/(벤다|베어|베고|벤 |찌른|찌르|찔러|(?<!도망)(?:친다|치고|쳐서)|때린|때려|휘두른|휘둘|공격|내려친|후려친|일격|날린|날려|쏜다|쏘아|쏴|베기|돌진|달려든)|\b(attack|attacks|strike|strikes|hit|hits|slash|stab|swing|swings|bash|smash|shoot|cut|charge|charges|punch|kick|thrust|lunge)\b/u
  @defend ~r/(막는|막아|막았|막자|막고|방어 ?자세|방어한|방어를 한|방패를 (들|세|올)|웅크)|\b(defend|guard up|raise (my|the) guard|block|parry|brace)\b/u
  @heal ~r/(치료|회복|포션|물약|붕대|상처를 (감|싸))|\b(heal|potion|bandage|cure|patch)\b/u
  @flee ~r/(도망친다|도망쳐|도망가|도망간다|도망치자|후퇴|달아난다|달아나|피신)|\b(flee|escape|retreat|run away)\b/u

  @doc """
  The combat event a player's words mean. An attack on `target` when they
  strike; a guard; a heal (themselves, or an ally named as `target`; never an
  enemy); an escape from `target`; and a guard when nothing is clear.

      action(state, "user", "wolf", "I swing my sword!")       # attack
      action(state, "user", "wolf", "방패를 들어 막는다")       # defend
      action(state, "user", "wolf", "포션을 마신다")            # heal, themselves
  """
  @spec action(State.t(), String.t(), String.t() | nil, String.t()) :: Event.t()
  def action(%State{} = state, from, target, text) when is_binary(text) do
    words = String.downcase(text)
    target = target || foe(state)

    cond do
      Regex.match?(@attack, words) and target != nil ->
        Event.attack(from, target,
          skill: skill(text),
          observed_by: party(state) -- [from, target]
        )

      Regex.match?(@heal, words) ->
        Event.heal(from, heal_target(state, from, target), item: item(words))

      Regex.match?(@defend, words) ->
        Event.defend(from)

      Regex.match?(@flee, words) and target != nil ->
        Event.flee(from, target)

      true ->
        Event.defend(from)
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

  # An ally (a party member) can be healed; anyone else gets the potion
  # drunk by the one holding it.
  defp heal_target(state, from, target) do
    if target != nil and State.stat(state, target, "party") > 0, do: target, else: from
  end

  defp item(words) do
    cond do
      String.contains?(words, ["potion", "포션", "물약"]) -> "potion"
      String.contains?(words, ["bandage", "붕대"]) -> "bandage"
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
      "#{output.amount}의 피해를 입혔다#{guarded(output, :ko)}.#{hp}"
  end

  defp told(:ko, :defeated, %{character_id: by}, name, _hp), do: "#{Ko.subject(name.(by))} 쓰러졌다."

  defp told(:ko, :guarded, %{character_id: by}, name, _hp),
    do: "#{Ko.with_particle(name.(by), :topic)} 방어 자세를 취했다."

  defp told(:ko, :healed, %{character_id: by, to: by} = output, name, hp),
    do: "#{Ko.with_particle(name.(by), :topic)} 상처를 #{output.amount}만큼 치료했다.#{hp}"

  defp told(:ko, :healed, %{character_id: by} = output, name, hp),
    do: "#{Ko.subject(name.(by))} #{name.(output.to)}의 상처를 #{output.amount}만큼 치료했다.#{hp}"

  defp told(:ko, :holds_back, %{character_id: by}, name, _hp),
    do: "#{Ko.with_particle(name.(by), :topic)} 팔짱을 낀 채 지켜볼 뿐이다."

  defp told(:ko, :fled, %{character_id: by, to: to}, name, _hp),
    do: "#{Ko.with_particle(name.(by), :topic)} #{name.(to)}에게서 무사히 도망쳤다."

  defp told(:ko, :caught, %{character_id: by, to: to}, name, _hp),
    do: "#{Ko.with_particle(name.(by), :topic)} 도망치려 했지만 #{Ko.subject(name.(to))} 막아섰다."

  defp hp_suffix(%{max_hp: max, hp: hp, subject: subject}, name, _locale) when is_integer(max),
    do: " (#{name.(subject)} #{hp}/#{max})"

  defp hp_suffix(_output, _name, _locale), do: ""

  defp guarded(%{guarded: true}, :en), do: ", through a raised guard"
  defp guarded(%{guarded: true}, :ko), do: "(방어로 절반)"
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
