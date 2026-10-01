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
  # A roll from 0 to 5 that depends only on the event and the world, so a
  # replayed fight goes the same way.
  def roll(event, %State{} = state),
    do: :erlang.phash2({state.seq, event.type, event.from, Map.get(event, :to)}, 6)

  @doc false
  def guard_key(id), do: "combat:guard:#{id}"

  ## Reading what a player typed

  @defend ~w(defend guard block parry shield 막 방어 방패 막아 막는)
  @heal ~w(heal potion bandage cure 치료 회복 포션 물약 붕대)
  @flee ~w(flee run escape retreat 도망 후퇴 달아 피신)

  @doc """
  The combat event a player's words mean: a heal (on themselves unless
  `target` is given), a guard, an escape from `target`, or else an attack on
  `target`.

      action(state, "user", "goblin", "I swing my sword!")  # attack
      action(state, "user", "goblin", "방패를 들어 막는다")  # defend
  """
  @spec action(State.t(), String.t(), String.t() | nil, String.t()) :: Event.t()
  def action(%State{}, from, target, text) when is_binary(text) do
    words = String.downcase(text)

    cond do
      # A potion one drinks heals oneself; otherwise the target, if any.
      mentions?(words, @heal) ->
        drinks? = String.contains?(words, ["drink", "마시", "마신"])
        Event.heal(from, if(drinks?, do: from, else: target || from), item: item(words))

      mentions?(words, @defend) ->
        Event.defend(from)

      mentions?(words, @flee) and target != nil ->
        Event.flee(from, target)

      true ->
        Event.attack(from, target, skill: skill(text))
    end
  end

  defp mentions?(text, words), do: Enum.any?(words, &String.contains?(text, &1))

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
