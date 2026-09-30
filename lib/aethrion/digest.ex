defmodule Aethrion.Digest do
  @moduledoc """
  What changed socially over a stretch of outputs, as short lines a host can
  show: "while you were away".

      iex> events = [
      ...>   Aethrion.Event.gift_received("user", "mina", "flower", observed_by: ["yuna"]),
      ...>   Aethrion.Event.time_tick("t", hours: 2)
      ...> ]
      iex> {:ok, state, steps} = Aethrion.run(Aethrion.demo_state(), events)
      iex> steps
      ...> |> Enum.flat_map(& &1.outputs)
      ...> |> Aethrion.Digest.of(state)
      ...> |> Enum.map(& &1.text)
      [
        ~s(Yuna reached out to you: "You looked happy with Mina earlier. I wondered if you forgot about me."),
        "Yuna tells Haru about the flower you gave Mina.",
        ~s(Haru reached out to you: "Yuna told me you gave Mina a flower. Smooth."),
        "Haru stays with Yuna for a while. Yuna feels a little lighter."
      ]

  Scenes between characters, messages characters sent on their own, and newly
  formed beliefs (impressions) are listed in order. Bonds and moods are net
  changes: a bond that went up and back down, or a mood that came and went,
  is left out.

  Each item is `%{kind, event_id, text}`, `kind` being `:scene`, `:message`,
  `:belief`, `:bond`, or `:mood`. The digest is deterministic and reads only
  outputs and names; with `locale: :ko` the lines are Korean.

  Options:

  - `:locale` - `:en` (default) or `:ko`
  - `:you` - the person addressed as "you" (default `"user"`)
  """

  alias Aethrion.State
  alias Aethrion.Expression.Templates.Ko

  @moods_worth_telling [:happy, :lonely, :jealous, :upset]

  @type item :: %{kind: atom(), event_id: String.t() | nil, text: String.t()}

  @doc "Digest items for `outputs`, with names from `state`."
  @spec of([map()], State.t(), keyword()) :: [item()]
  def of(outputs, %State{} = state, opts \\ []) do
    locale = opts |> Keyword.get(:locale, :en) |> Aethrion.Report.supported_locale!()

    say = %{
      locale: locale,
      name: &name(state, &1, Keyword.get(opts, :you, "user"), locale)
    }

    events = Enum.flat_map(outputs, &event_item(&1, say))
    events ++ net_bonds(outputs, say) ++ net_moods(outputs, say)
  end

  defp event_item(%{type: :character_interaction} = output, say) do
    [item(:scene, output, line(output, say))]
  end

  defp event_item(%{type: :proactive_message} = output, %{locale: :ko} = say) do
    from = subject(say.name.(output.character_id), say)

    [
      item(
        :message,
        output,
        "#{from} #{say.name.(output.to)}에게 먼저 연락했다: \"#{line(output, say)}\""
      )
    ]
  end

  defp event_item(%{type: :proactive_message} = output, say) do
    to = say.name.(output.to)

    [
      item(
        :message,
        output,
        "#{say.name.(output.character_id)} reached out to #{to}: \"#{output.text}\""
      )
    ]
  end

  defp event_item(%{type: :memory_created, memory: %{kind: :impression} = memory} = output, say) do
    case belief(memory.data, say.name.(memory.character_id), say) do
      nil -> []
      text -> [item(:belief, output, text)]
    end
  end

  defp event_item(_output, _say), do: []

  @doc false
  # A belief as a line, for other renderers (reports): `name` maps ids to
  # display names.
  def belief_text(data, holder, locale, name) do
    case belief(data, holder, %{locale: locale, name: name}) do
      nil -> nil
      text -> capitalize(text)
    end
  end

  # What a new impression means, from its data rather than its internal text.
  defp belief(
         %{"event" => "impression", "pattern" => pattern, "from" => actor, "count" => count},
         holder,
         say
       ) do
    actor = say.name.(actor)

    case {say.locale, pattern} do
      {:ko, "gift"} ->
        "#{Ko.with_particle(holder, :topic)} #{actor}에게 받은 선물 #{count}개를 기억한다."

      {:ko, "apology"} ->
        "#{Ko.with_particle(holder, :topic)} #{actor}의 사과 #{count}번을 기억한다."

      {:ko, "comfort"} ->
        "#{Ko.with_particle(holder, :topic)} #{actor}에게 위로받은 일 #{count}번을 기억한다."

      {:ko, "together"} ->
        "#{Ko.with_particle(holder, :topic)} #{Ko.with_particle(actor, :with)} 함께한 시간 #{count}번을 기억한다."

      {:ko, tone} ->
        "#{Ko.with_particle(holder, :topic)} #{actor}의 #{ko_tone(tone)} 말 #{count}번을 기억한다."

      {_en, "gift"} ->
        "#{holder} remembers #{count} gifts from #{actor}."

      {_en, "apology"} ->
        "#{holder} remembers #{count} apologies from #{actor}."

      {_en, "comfort"} ->
        "#{holder} remembers being comforted by #{actor} #{count} times."

      {_en, "together"} ->
        "#{holder} remembers #{count} afternoons with #{actor}."

      {_en, tone} ->
        "#{holder} remembers #{actor} being #{tone} #{count} times."
    end
  end

  defp belief(
         %{
           "event" => "reputation",
           "pattern" => tone,
           "from" => actor,
           "about" => about,
           "count" => count
         },
         holder,
         say
       ) do
    others = Enum.map(about, say.name)

    case say.locale do
      :ko ->
        "#{Ko.with_particle(holder, :topic)} #{subject(say.name.(actor), say)} #{Enum.join(others, ", ")}에게 " <>
          "#{ko_tone(tone)} 말을 한 걸 안다 (#{count}번)."

      _en ->
        actor = say.name.(actor)
        treats = if actor == "you", do: "treat", else: "treats"

        "#{holder} knows how #{actor} #{treats} others: #{tone} to #{and_list(others)}, #{count} times."
    end
  end

  defp belief(_data, _holder, _say), do: nil

  defp ko_tone("warm"), do: "다정한"
  defp ko_tone("cold"), do: "차가운"
  defp ko_tone("hostile"), do: "모진"
  defp ko_tone(other), do: other

  # "네가", not "너가".
  defp subject("너", _say), do: "네가"
  defp subject(name, _say), do: Ko.with_particle(name, :subject)

  # Rendered text for expressive outputs, in the digest's language.
  defp line(%{context: %Aethrion.Expression.Request{} = request}, %{locale: :ko}),
    do: Ko.render(request)

  defp line(output, _say), do: output.text

  defp net_bonds(outputs, say) do
    outputs
    |> Enum.filter(&(Map.get(&1, :type) == :bond_changed))
    |> net(&{&1.from, &1.to})
    |> Enum.map(fn {first, last} ->
      item(:bond, last, bond_line(first.from, first.to, first.before, last.after, say))
    end)
  end

  # One line per mood, in order of first appearance: "Mina and Yuna are lonely."
  defp net_moods(outputs, say) do
    changes =
      outputs
      |> Enum.filter(&(Map.get(&1, :type) == :mood_changed))
      |> net(& &1.character_id)
      |> Enum.map(fn {_first, last} -> last end)
      |> Enum.filter(&(&1.after in @moods_worth_telling))

    for mood <- changes |> Enum.map(& &1.after) |> Enum.uniq() do
      same = Enum.filter(changes, &(&1.after == mood))
      names = Enum.map(same, &say.name.(&1.character_id))
      item(:mood, List.last(same), mood_line(names, mood, say))
    end
  end

  # First and last change per key, in order of first appearance, dropping
  # keys that ended where they started.
  defp net(changes, key) do
    changes
    |> Enum.group_by(key)
    |> Enum.map(fn {_key, list} -> {hd(list), List.last(list)} end)
    |> Enum.reject(fn {first, last} -> first.before == last.after end)
    |> Enum.sort_by(fn {first, _last} -> Enum.find_index(changes, &(&1 == first)) end)
  end

  defp bond_line(from, to, before, after_bond, say) do
    warmer? = rank(after_bond) > rank(before)
    {from, to} = {say.name.(from), say.name.(to)}

    case say.locale do
      :ko ->
        verb = if warmer?, do: "마음을 열었다", else: "거리를 두게 되었다"
        "#{Ko.with_particle(from, :topic)} #{to}에게 #{verb} (이제 #{ko_bond(after_bond)})."

      _en ->
        verb = if warmer?, do: "warmed to", else: "cooled toward"
        "#{from} #{verb} #{to} (now #{after_bond})."
    end
  end

  defp mood_line(names, mood, %{locale: :ko}) do
    feeling =
      case mood do
        :happy -> "기분이 좋아졌다"
        :lonely -> "외로워졌다"
        :jealous -> "질투하기 시작했다"
        :upset -> "속상해졌다"
      end

    "#{Ko.with_particle(ko_list(names), :topic)} #{feeling}."
  end

  defp mood_line(["you"], mood, _say), do: "You are #{mood}."
  defp mood_line([name], mood, _say), do: "#{name} is #{mood}."
  defp mood_line(names, mood, _say), do: "#{and_list(names)} are #{mood}."

  # "Mina, Yuna와 Haru": the particle follows the second-to-last name.
  defp ko_list([one]), do: one

  defp ko_list(names) do
    Ko.with_particle(Enum.join(Enum.drop(names, -1), ", "), :with) <> " " <> List.last(names)
  end

  defp and_list([one]), do: one
  defp and_list([a, b]), do: "#{a} and #{b}"
  defp and_list(names), do: Enum.join(Enum.drop(names, -1), ", ") <> ", and " <> List.last(names)

  defp rank(bond), do: Enum.find_index(Aethrion.Rules.Bond.bonds(), &(&1 == bond)) || 2

  defp ko_bond(:estranged), do: "틀어진 사이"
  defp ko_bond(:strained), do: "서먹한 사이"
  defp ko_bond(:neutral), do: "그저 그런 사이"
  defp ko_bond(:friendly), do: "친근한 사이"
  defp ko_bond(:close), do: "가까운 사이"
  defp ko_bond(other), do: to_string(other)

  defp name(_state, you, you, :ko), do: "너"
  defp name(_state, you, you, _en), do: "you"
  defp name(state, id, _you, _locale), do: State.name(state, id)

  defp item(kind, output, text),
    do: %{kind: kind, event_id: Map.get(output, :event_id), text: capitalize(text)}

  # "you warmed to Mina" starts a sentence too.
  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(text), do: text
end
