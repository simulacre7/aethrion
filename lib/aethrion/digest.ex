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
  - `:only_you` - `true` leaves out what concerns other people: messages
    characters sent them, bonds toward them, and beliefs about them, so each
    player in a shared world gets their own digest (default `false`)

  Players are named by `Aethrion.State` `:people` display names.
  """

  alias Aethrion.State
  alias Aethrion.Expression.Templates.Ko

  @moods_worth_telling [:happy, :lonely, :jealous, :upset]

  @type item :: %{kind: atom(), event_id: String.t() | nil, text: String.t()}

  @doc "Digest items for `outputs`, with names from `state`."
  @spec of([map()], State.t(), keyword()) :: [item()]
  def of(outputs, %State{} = state, opts \\ []) do
    locale = opts |> Keyword.get(:locale, :en) |> Aethrion.Report.supported_locale!()

    you = Keyword.get(opts, :you, "user")

    say = %{
      locale: locale,
      you: you,
      name: &name(state, &1, you, locale),
      # Impressions deepen after they form; tell what they hold now.
      impressions: for(%{kind: :impression} = m <- state.memories, into: %{}, do: {m.id, m.data})
    }

    outputs =
      if Keyword.get(opts, :only_you, false),
        do: Enum.reject(outputs, &about_someone_else?(&1, state, you)),
        else: outputs

    # Each item keeps the output it came from, so outings group by what they
    # were, not by event id.
    events =
      outputs
      |> Enum.flat_map(fn output -> Enum.map(event_item(output, say), &{&1, output}) end)
      |> group_outings(say)

    events ++ net_bonds(outputs, say) ++ net_moods(outputs, say)
  end

  # Friends who spent time together more than once get one line, where their
  # first outing was: "Haru and Yuna spent time together 4 times."
  defp group_outings(pairs, say) do
    pair = fn scene -> Enum.sort([scene.character_id, scene.to]) end

    counts =
      pairs
      |> Enum.filter(&match?({_item, %{type: :character_interaction, kind: :together}}, &1))
      |> Enum.frequencies_by(fn {_item, scene} -> pair.(scene) end)

    {items, _seen} =
      Enum.flat_map_reduce(pairs, MapSet.new(), fn
        {item, %{type: :character_interaction, kind: :together} = scene}, seen ->
          key = pair.(scene)

          cond do
            counts[key] == 1 ->
              {[item], seen}

            MapSet.member?(seen, key) ->
              {[], seen}

            true ->
              {[%{item | text: outings_line(scene, counts[key], say)}], MapSet.put(seen, key)}
          end

        {item, _output}, seen ->
          {[item], seen}
      end)

    items
  end

  defp outings_line(scene, count, %{locale: :ko} = say) do
    "#{Ko.with_particle(say.name.(scene.character_id), :with)} " <>
      "#{Ko.with_particle(say.name.(scene.to), :topic)} #{Ko.times(count)} 함께 시간을 보냈다."
  end

  defp outings_line(scene, count, say) do
    "#{say.name.(scene.character_id)} and #{say.name.(scene.to)} spent time together #{count} times."
  end

  # Addressed to, or about, a person other than `you`.
  defp about_someone_else?(output, state, you) do
    other? = &(is_binary(&1) and &1 != you and not State.character?(state, &1))

    case output do
      %{type: :proactive_message, to: to} -> other?.(to)
      %{type: :bond_changed, from: from, to: to} -> other?.(from) or other?.(to)
      %{type: :memory_created, memory: %{data: %{"from" => from}}} -> other?.(from)
      _other -> false
    end
  end

  defp event_item(%{type: :character_interaction} = output, say) do
    [item(:scene, output, line(output, say))]
  end

  defp event_item(%{type: :proactive_message} = output, %{locale: :ko} = say) do
    from = Ko.subject(say.name.(output.character_id))

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
    data = Map.get(say.impressions, memory.id, memory.data)

    case belief(data, say.name.(memory.character_id), say) do
      nil -> []
      text -> [item(:belief, output, text)]
    end
  end

  defp event_item(_output, _say), do: []

  @doc false
  # A belief as a line, for other renderers (reports): `name` maps ids to
  # display names.
  @spec belief_text(map(), String.t(), :en | :ko, (String.t() -> String.t())) :: String.t() | nil
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
      {:ko, pattern} ->
        "#{Ko.with_particle(holder, :topic)} #{ko_remembers(pattern, actor, Ko.times(count))}"

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
        "#{Ko.with_particle(holder, :topic)} #{Ko.subject(say.name.(actor))} #{Enum.join(others, ", ")}에게 " <>
          "#{Ko.times(count)} #{Ko.adverb(tone)} 말한 걸 안다."

      _en ->
        actor = say.name.(actor)
        treats = if actor == "you", do: "treat", else: "treats"

        "#{holder} knows how #{actor} #{treats} others: #{tone} to #{and_list(others)}, #{count} times."
    end
  end

  defp belief(_data, _holder, _say), do: nil

  # "은비는 네가 세 번 사과한 걸 기억한다."
  defp ko_remembers("gift", actor, times),
    do: "#{actor}에게 선물을 #{times} 받은 걸 기억한다."

  defp ko_remembers("apology", actor, times),
    do: "#{Ko.subject(actor)} #{times} 사과한 걸 기억한다."

  defp ko_remembers("comfort", actor, times),
    do: "#{actor}에게 #{times} 위로받은 걸 기억한다."

  # How many afternoons is not the point in Korean: that they matter is.
  defp ko_remembers("together", actor, _times),
    do: "#{Ko.with_particle(actor, :with)} 함께 보낸 시간을 소중히 기억한다."

  defp ko_remembers(tone, actor, times),
    do: "#{Ko.subject(actor)} #{times} #{Ko.adverb(tone)} 말한 걸 기억한다."

  # "네가", not "너가".

  # Rendered text for expressive outputs, in the digest's language.
  # A digest tells what already happened: scenes in the past tense.
  # Lines are told again for the digest's reader: "you" is whoever `:you`
  # names, whoever the line was first written for.
  defp line(%{context: %Aethrion.Expression.Request{} = request}, %{locale: :ko} = say),
    do: Ko.render(for_reader(request, say.you, "너"), tense: :past)

  # A line a model already phrased is kept as it is.
  defp line(%{expression: %{status: :ok}} = output, %{locale: :en}), do: output.text

  defp line(%{context: %Aethrion.Expression.Request{} = request}, %{you: you})
       when you != "user",
       do: Aethrion.Expression.Templates.render(for_reader(request, you, "you"))

  defp line(output, _say), do: output.text

  defp for_reader(request, you, word), do: %{request | names: Map.put(request.names, you, word)}

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
        verb =
          cond do
            not warmer? -> "거리를 두게 되었다"
            after_bond in [:estranged, :strained] -> "조금 누그러졌다"
            true -> "마음을 열었다"
          end

        "#{Ko.with_particle(from, :topic)} #{to}에게 #{verb} (이제 #{Ko.bond_label(after_bond)})."

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

    case names do
      [one] -> "#{Ko.with_particle(one, :topic)} #{feeling}."
      names -> "#{ko_list(names)} 모두 #{feeling}."
    end
  end

  defp mood_line(["you"], mood, _say), do: "You are #{mood}."
  defp mood_line([name], mood, _say), do: "#{name} is #{mood}."
  defp mood_line(names, mood, _say), do: "#{and_list(names)} are #{mood}."

  # "Mina와 Yuna", "은비, 민수, Jack": two names joined by 와/과, more by commas.
  defp ko_list([a, b]), do: Ko.with_particle(a, :with) <> " " <> b
  defp ko_list(names), do: Enum.join(names, ", ")

  defp and_list([one]), do: one
  defp and_list([a, b]), do: "#{a} and #{b}"
  defp and_list(names), do: Enum.join(Enum.drop(names, -1), ", ") <> ", and " <> List.last(names)

  defp rank(bond), do: Enum.find_index(Aethrion.Rules.Bond.bonds(), &(&1 == bond)) || 2

  defp name(_state, you, you, :ko), do: "너"
  defp name(_state, you, you, _en), do: "you"
  defp name(state, id, _you, _locale), do: State.name(state, id)

  defp item(kind, output, text),
    do: %{kind: kind, event_id: Map.get(output, :event_id), text: capitalize(text)}

  # "you warmed to Mina" starts a sentence too.
  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(text), do: text
end
