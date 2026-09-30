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

  @bonds [:estranged, :strained, :neutral, :friendly, :close]
  @moods_worth_telling [:happy, :lonely, :jealous, :upset]

  @type item :: %{kind: atom(), event_id: String.t() | nil, text: String.t()}

  @doc "Digest items for `outputs`, with names from `state`."
  @spec of([map()], State.t(), keyword()) :: [item()]
  def of(outputs, %State{} = state, opts \\ []) do
    say = %{
      locale: Keyword.get(opts, :locale, :en),
      name: &name(state, &1, Keyword.get(opts, :you, "user"), Keyword.get(opts, :locale, :en))
    }

    events = Enum.flat_map(outputs, &event_item(&1, say))
    events ++ net_bonds(outputs, say) ++ net_moods(outputs, say)
  end

  defp event_item(%{type: :character_interaction} = output, say) do
    [item(:scene, output, line(output, say))]
  end

  defp event_item(%{type: :proactive_message} = output, %{locale: :ko} = say) do
    [
      item(
        :message,
        output,
        "#{Ko.with_particle(say.name.(output.character_id), :subject)} 먼저 연락했다: \"#{line(output, say)}\""
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
    text =
      case say.locale do
        :ko ->
          "#{Ko.with_particle(say.name.(memory.character_id), :topic)} 이렇게 믿게 되었다: #{memory.content}"

        _en ->
          "#{say.name.(memory.character_id)} has come to believe: #{memory.content}"
      end

    [item(:belief, output, text)]
  end

  defp event_item(_output, _say), do: []

  # Rendered text for expressive outputs, in the digest's language.
  defp line(%{context: %Aethrion.Expression.Request{} = request}, %{locale: :ko}),
    do: Ko.render(request)

  defp line(output, _say), do: output.text

  defp net_bonds(outputs, say) do
    outputs
    |> Enum.filter(&(&1.type == :bond_changed))
    |> net(&{&1.from, &1.to})
    |> Enum.map(fn {first, last} ->
      item(:bond, last, bond_line(first.from, first.to, first.before, last.after, say))
    end)
  end

  # One line per mood, in order of first appearance: "Mina and Yuna are lonely."
  defp net_moods(outputs, say) do
    changes =
      outputs
      |> Enum.filter(&(&1.type == :mood_changed))
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

    "#{Ko.with_particle(Enum.join(names, ", "), :topic)} #{feeling}."
  end

  defp mood_line([name], mood, _say), do: "#{name} is #{mood}."
  defp mood_line(names, mood, _say), do: "#{and_list(names)} are #{mood}."

  defp and_list([a, b]), do: "#{a} and #{b}"
  defp and_list(names), do: Enum.join(Enum.drop(names, -1), ", ") <> ", and " <> List.last(names)

  defp rank(bond), do: Enum.find_index(@bonds, &(&1 == bond)) || 2

  defp ko_bond(:estranged), do: "틀어진 사이"
  defp ko_bond(:strained), do: "서먹한 사이"
  defp ko_bond(:neutral), do: "그저 그런 사이"
  defp ko_bond(:friendly), do: "친근한 사이"
  defp ko_bond(:close), do: "가까운 사이"

  defp name(_state, you, you, :ko), do: "너"
  defp name(_state, you, you, _en), do: "you"
  defp name(state, id, _you, _locale), do: State.name(state, id)

  defp item(kind, output, text),
    do: %{kind: kind, event_id: Map.get(output, :event_id), text: capitalize(text)}

  # "you warmed to Mina" starts a sentence too.
  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(text), do: text
end
