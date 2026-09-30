defmodule Aethrion.Expression.Choices do
  @moduledoc false
  # What a line should say, decided once for every language: the English
  # (`Aethrion.Expression.Templates`) and Korean
  # (`Aethrion.Expression.Templates.Ko`) templates only turn these choices into
  # words. Choices read nothing but the `Aethrion.Expression.Request`.

  alias Aethrion.Expression.Request

  # Tension at which replies turn guarded, whatever the mood.
  @guarded_tension 10

  defp find_data(request, fun) do
    request.memories |> Enum.map(& &1.data) |> Enum.find(fun)
  end

  @doc false
  # Whom the listener's gift went to, and when, or `:quiet`.
  @spec jealous_choice(Request.t()) :: {:gift, String.t(), :earlier | :other_day} | :quiet
  def jealous_choice(request) do
    between = {request.listener.id, request.speaker.id}

    case find_memory(request, &gift_to_someone_else?(&1, between)) do
      %{data: %{"to" => to}} = memory ->
        case Request.hours_ago(request, memory) do
          hours when is_integer(hours) and hours > 12 -> {:gift, to, :other_day}
          _recent -> {:gift, to, :earlier}
        end

      nil ->
        :quiet
    end
  end

  @doc false
  # After a week of silence, only the silence is left to talk about. Before
  # that, fond memories come up when nothing harsh stands between them, and
  # otherwise how long it has been.
  @spec lonely_choice(Request.t()) ::
          {:quote, String.t()}
          | {:gift, String.t()}
          | :kind
          | :reunion
          | :a_while
          | :busy
          | :today
  def lonely_choice(request) do
    between = {request.listener.id, request.speaker.id}
    silence = silence(request)
    fond? = silence < 168 and not hurt?(request)
    warm = if fond?, do: find_data(request, &warm_message?(&1, between))
    gift = if fond?, do: recent_gift(request, between)

    cond do
      silence >= 168 -> :busy
      warm -> {:quote, warm["text"]}
      gift -> {:gift, gift["item"]}
      fond? and kindness(request) > 0 -> :kind
      silence >= 72 -> :reunion
      silence >= 24 -> :a_while
      true -> :today
    end
  end

  # Hours since the listener last talked to the speaker, or since the world
  # began if they never have.
  defp silence(%Request{since_contact: hours}) when is_integer(hours), do: hours
  defp silence(%Request{now: now}) when is_integer(now), do: now
  defp silence(_request), do: 0

  @doc false
  # How an apology lands: worn thin after several, a relief to someone who
  # felt left out, unneeded when nothing was wrong, and slower to heal fresh
  # tension.
  @spec apology_choice(Request.t()) ::
          :settled
          | :keeps_apologizing
          | :left_out
          | :nothing_to_forgive
          | :once_more
          | :needs_time
          | :shaken
          | :accepted
  def apology_choice(%Request{speaker: %{mood: mood}} = request) do
    listener = request.listener.id

    earlier =
      Enum.count(
        request.memories,
        &match?(%{data: %{"event" => "apology_offered", "from" => ^listener}}, &1)
      ) - 1

    harsh? = Enum.any?(request.memories, &harsh_from?(&1, listener))

    left_out? =
      Enum.any?(
        request.memories,
        &match?(%{kind: :observed, data: %{"event" => "gift_received", "from" => ^listener}}, &1)
      )

    # An apology after one that already came after the latest harsh words is
    # for something already forgiven.
    settled? = settled?(request, listener, earlier)

    cond do
      settled? -> :settled
      earlier >= 2 -> :keeps_apologizing
      left_out? and not harsh? -> :left_out
      not harsh? and tension(request) == 0 -> :nothing_to_forgive
      earlier == 1 -> :once_more
      tension(request) >= @guarded_tension -> :needs_time
      mood == :upset -> :shaken
      true -> :accepted
    end
  end

  @doc false
  # How a gift lands: warily with hurt feelings between them, as reassurance
  # to someone who felt left out by the giver since their last gift (reason
  # `:reassurance`, decided by `Aethrion.Rules.Reply`), as company to someone
  # lonely, and as a bit much when they keep coming.
  @spec gift_choice(Request.t()) :: :wary | :reassured | :spoiled | :remembered | :close | :thanks
  def gift_choice(%Request{speaker: %{mood: mood}} = request) do
    cond do
      wary_choice(:warm, request) != nil -> :wary
      request.reason == :reassurance -> :reassured
      (request.repeats || 1) >= 3 -> :spoiled
      mood == :lonely -> :remembered
      match?(%{bond: :close}, request.relationship) -> :close
      true -> :thanks
    end
  end

  @doc false
  # Which of four ways two friends spend time, turning day by day, and not
  # the same for every pair on the same day.
  @spec together_choice(Request.t()) :: 0..3
  def together_choice(%Request{now: now} = request) when is_integer(now) do
    pair = :erlang.phash2(Enum.sort([request.speaker.id, request.listener.id]), 4)
    rem(div(now, 24) + pair, 4)
  end

  def together_choice(_request), do: 0

  # Harsh words from `listener`, remembered or folded into an impression.
  defp harsh_from?(
         %{data: %{"event" => "message_sent", "from" => from, "tone" => tone}},
         listener
       ),
       do: from == listener and tone in ["cold", "hostile"]

  defp harsh_from?(
         %{data: %{"event" => "impression", "from" => from, "pattern" => pattern}},
         listener
       ),
       do: from == listener and pattern in ["cold", "hostile"]

  defp harsh_from?(_memory, _listener), do: false

  defp settled?(request, listener, 1),
    do: tension(request) < @guarded_tension and forgiven?(request, listener)

  defp settled?(_request, _listener, _earlier), do: false

  defp forgiven?(request, listener) do
    numbers = fn match? ->
      request.memories
      |> Enum.filter(match?)
      |> Enum.map(&Aethrion.Memories.event_number/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(:desc)
    end

    apologies =
      numbers.(&match?(%{data: %{"event" => "apology_offered", "from" => ^listener}}, &1))

    harsh =
      numbers.(
        &match?(
          %{data: %{"event" => "message_sent", "from" => ^listener, "tone" => t}}
          when t in ["cold", "hostile"],
          &1
        )
      )

    case {apologies, harsh} do
      {[_current, previous | _], [latest_harsh | _]} -> previous > latest_harsh
      {[_current, _previous | _], []} -> true
      _other -> false
    end
  end

  @doc false
  # A record of kindness (3 kind acts, as `Aethrion.Rules.Message` counts
  # them by default) earns the benefit of the doubt, unless there has been as
  # much hostility.
  # The rules' own verdict when the request carries it.
  @spec benefit_of_doubt?(Request.t()) :: boolean()
  def benefit_of_doubt?(%Request{goodwill: goodwill}) when is_boolean(goodwill), do: goodwill

  def benefit_of_doubt?(request),
    do: kindness(request) >= 3 and kindness(request) > hostility(request)

  @doc false
  # How harsh words land. The first gets hurt or, with a record of kindness,
  # the benefit of the doubt; repeated ones escalate (someone upset just asks
  # for it to stop), and after a fourth, or when estranged, the character
  # stops answering.
  @spec harsh_choice(:cold | :hostile, Request.t()) ::
          :silent | :done | :again | :short | :benefit | :hurt
  def harsh_choice(tone, request) do
    repeats = request.repeats || 1

    cond do
      repeats >= 4 or (repeats >= 2 and match?(%{bond: :estranged}, request.relationship)) ->
        :silent

      repeats >= 2 ->
        escalation(tone, repeats, request.speaker.mood)

      benefit_of_doubt?(request) ->
        :benefit

      true ->
        :hurt
    end
  end

  defp escalation(:hostile, repeats, _mood) when repeats >= 3, do: :done
  defp escalation(:hostile, _repeats, :upset), do: :hurt
  defp escalation(:hostile, _repeats, _mood), do: :again
  defp escalation(:cold, _repeats, _mood), do: :short

  @doc false
  # One of several ways to say the same thing, turning with how often the
  # listener has said it, so the same line does not repeat.
  @spec pick(Request.t(), String.t() | [String.t()] | nil) :: String.t() | nil
  def pick(_request, nil), do: nil
  def pick(_request, line) when is_binary(line), do: line

  def pick(request, lines) when is_list(lines) do
    Enum.at(lines, rem(turn(request), length(lines)))
  end

  # Plain messages are not remembered, so for them the hour turns the line.
  defp turn(%Request{tone: :neutral, now: now}) when is_integer(now), do: now + div(now, 24)
  # A protest turns with the day too, so one speaking up again days later
  # does not repeat themselves.
  defp turn(%Request{reason: :protective, now: now} = request) when is_integer(now),
    do: (request.repeats || 1) - 1 + div(now, 24)

  defp turn(request), do: (request.repeats || 1) - 1 + folded(request)

  # What faded into an impression counts too, so the turn keeps going over
  # weeks, not only within the few days details are remembered.
  defp folded(%Request{tone: tone} = request) when tone in [:warm, :cold, :hostile, :gift],
    do: impression_count(request, [Atom.to_string(tone)])

  defp folded(_request), do: 0

  @doc false
  # What a curious character heard about the listener, and from whom:
  # `{kind, source, data}`, or `:unknown` when no heard memory says.
  @spec curious_choice(Request.t()) ::
          {:gift | :harsh | :warm | :comfort | :apology | :other, String.t() | nil, map()}
          | :unknown
  def curious_choice(%Request{memories: memories}) do
    case Enum.find(memories, &(&1.kind == :heard)) do
      %{source: source, data: data} -> {news(data), source, data}
      nil -> :unknown
    end
  end

  defp news(%{"event" => "gift_received"}), do: :gift

  defp news(%{"event" => "message_sent", "tone" => tone}) when tone in ["hostile", "cold"],
    do: :harsh

  defp news(%{"event" => "message_sent", "tone" => "warm"}), do: :warm
  defp news(%{"event" => "comfort_offered"}), do: :comfort
  defp news(%{"event" => "apology_offered"}), do: :apology
  defp news(_data), do: :other

  @doc false
  # Which reply fits kind or plain words, first match wins: hurt feelings
  # (`wary_choice/2`), a long absence (when nothing darker is going on), the
  # bond when the mood has nothing to say, then the mood.
  @spec reply_choice(atom(), Request.t()) ::
          {:bond, atom()} | :guarded | {:reunion, :missed | :thanks | :hello} | {:mood, atom()}
  def reply_choice(tone, %Request{speaker: %{mood: mood}} = request) do
    bond = match?(%{bond: _}, request.relationship) && request.relationship.bond

    cond do
      wary = wary_choice(tone, request) ->
        wary

      reunion = reunion(tone, mood, bond, request) ->
        {:reunion, reunion}

      tone in [:warm, :neutral] and mood in [:neutral, :happy] and
          bond in [:close, :strained, :estranged] ->
        {:bond, bond}

      true ->
        {:mood, mood}
    end
  end

  defp reunion(tone, mood, bond, request)
       when tone in [:warm, :neutral] and mood in [:neutral, :happy, :lonely] do
    cond do
      not Request.reunion?(request) -> nil
      bond in [:strained, :estranged] -> nil
      mood == :lonely -> :missed
      tone == :warm -> :thanks
      true -> :hello
    end
  end

  defp reunion(_tone, _mood, _bond, _request), do: nil

  @doc false
  # Hurt feelings speak before the mood: a strained or estranged bond, or
  # fresh tension from harsh words.
  @spec wary_choice(atom(), Request.t()) :: {:bond, :strained | :estranged} | :guarded | nil
  def wary_choice(tone, %Request{relationship: %{bond: bond}})
      when tone in [:warm, :neutral] and bond in [:strained, :estranged],
      do: {:bond, bond}

  def wary_choice(tone, request) when tone in [:warm, :neutral] do
    if tension(request) >= @guarded_tension or recently_hurt?(request), do: :guarded
  end

  def wary_choice(_tone, _request), do: nil

  defp find_memory(request, fun), do: Enum.find(request.memories, &fun.(&1.data))

  # Hostile words from the listener in the last day, with no apology since.
  defp recently_hurt?(request) do
    listener = request.listener.id

    latest = fn event ->
      request.memories
      |> Enum.filter(
        &(match?(%{kind: :experienced, data: %{"event" => ^event, "from" => ^listener}}, &1) and
            (event != "message_sent" or &1.data["tone"] == "hostile"))
      )
      |> Enum.map(&Request.hours_ago(request, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)
    end

    case {latest.("message_sent"), latest.("apology_offered")} do
      {nil, _apology} -> false
      {hurt, nil} -> hurt < 24
      {hurt, apology} -> hurt < 24 and apology > hurt
    end
  end

  defp tension(%Request{relationship: %{tension: tension}}) when is_integer(tension), do: tension
  defp tension(_request), do: 0

  # A gift from the last few days; older ones may well be gone.
  defp recent_gift(request, between) do
    case find_memory(request, &gift?(&1, between)) do
      nil ->
        nil

      memory ->
        case Request.hours_ago(request, memory) do
          hours when is_integer(hours) and hours > 72 -> nil
          _recent -> memory.data
        end
    end
  end

  # Kind acts and hostile messages from the listener, from the speaker's
  # impressions in the request.
  defp kindness(request), do: impression_count(request, ["warm", "gift", "comfort", "together"])

  defp hostility(request) do
    listener = request.listener.id

    remembered =
      Enum.count(
        request.memories,
        &match?(
          %{
            kind: :experienced,
            data: %{"event" => "message_sent", "tone" => "hostile", "from" => ^listener}
          },
          &1
        )
      )

    impression_count(request, ["hostile"]) + remembered
  end

  defp impression_count(request, patterns) do
    between = {request.listener.id, request.speaker.id}

    request.memories
    |> Enum.map(& &1.data)
    |> Enum.filter(&impression?(&1, between, patterns))
    |> Enum.map(&Map.get(&1, "count", 1))
    |> Enum.sum()
  end

  # Something harsh stands between them: tension, harshness the speaker knows
  # of toward others, or a record of hostility toward the speaker.
  defp hurt?(request) do
    tension(request) >= @guarded_tension or Request.harshness_to_others(request) != nil or
      hostility(request) > 0
  end

  # The listener gave a gift to someone other than the speaker.
  defp gift_to_someone_else?(%{"event" => "gift_received"} = data, {listener, speaker}),
    do: data["from"] == listener and data["to"] != speaker

  defp gift_to_someone_else?(_data, _between), do: false

  defp warm_message?(%{"event" => "message_sent", "tone" => "warm"} = data, {from, to}),
    do: data["from"] == from and data["to"] == to

  defp warm_message?(_data, _between), do: false

  defp gift?(%{"event" => "gift_received"} = data, {from, to}),
    do: data["from"] == from and data["to"] == to

  defp gift?(_data, _between), do: false

  defp impression?(%{"event" => "impression"} = data, {from, to}, patterns),
    do: data["from"] == from and data["to"] == to and data["pattern"] in patterns

  defp impression?(_data, _between, _patterns), do: false
end
