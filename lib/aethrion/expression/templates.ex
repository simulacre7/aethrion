defmodule Aethrion.Expression.Templates do
  @moduledoc """
  Deterministic text templates.

  Rules use these to give every expressive output a stable fallback line, so
  the simulation is complete and testable without any model. Templates only
  read the `Aethrion.Expression.Request` snapshot.
  """

  alias Aethrion.Expression.Request

  # Tension at which replies turn guarded, whatever the mood.
  @guarded_tension 10

  @doc "Renders the fallback text for a request."
  def render(%Request{kind: :proactive_message, reason: :jealous} = request) do
    case jealous_choice(request) do
      {:gift, to, :earlier} ->
        "You looked happy with #{name(request, to)} earlier. I wondered if you forgot about me."

      {:gift, to, :other_day} ->
        "You looked happy with #{name(request, to)} the other day. I wondered if you forgot about me."

      :quiet ->
        "You've been quiet with me lately. I wondered if you forgot about me."
    end
  end

  def render(%Request{kind: :proactive_message, reason: :lonely} = request) do
    case lonely_choice(request) do
      {:quote, text} ->
        "I keep thinking about what you said: \"#{text}\" Do you have a minute to talk?"

      {:gift, item} ->
        "I still have the #{item} you gave me. Do you have a minute to talk?"

      :kind ->
        "You've always been kind to me. I miss talking with you. Do you have a minute?"

      :reunion ->
        "We haven't talked in a few days. Do you have a minute?"

      :a_while ->
        "It's been a while since we talked. Do you have a minute?"

      :today ->
        "It's been quiet today. Do you have a minute to talk?"
    end
  end

  def render(%Request{kind: :proactive_message, reason: :protective} = request) do
    calm? = :calm in request.speaker.traits

    case Enum.find(request.memories, &(&1.kind == :observed)) do
      %{data: %{"to" => to}} ->
        friend = name(request, to)

        if calm?,
          do: "What you said to #{friend} was unkind. Is everything okay?",
          else: "That was harsh, what you said to #{friend}. #{friend} didn't deserve that."

      nil ->
        if calm?,
          do: "What you said was unkind. Is everything okay?",
          else: "That was harsh, what you said. Nobody deserves that."
    end
  end

  def render(%Request{kind: :proactive_message, reason: :curious} = request) do
    case Enum.find(request.memories, &(&1.kind == :heard)) do
      %{source: source, data: %{"event" => "gift_received"} = data} ->
        gift = "you gave #{name(request, data["to"])} a #{data["item"]}"

        if :playful in request.speaker.traits do
          "#{name(request, source)} told me #{gift}. Smooth."
        else
          "#{name(request, source)} mentioned #{gift}. Is there something I should know?"
        end

      %{source: source, data: %{"event" => "message_sent", "tone" => tone} = data}
      when tone in ["hostile", "cold"] ->
        said = if data["to"] == source, do: "", else: " to #{name(request, data["to"])}"

        "#{name(request, source)} told me what you said#{said}. " <>
          "That didn't sound like you. Is everything okay?"

      %{source: source} ->
        "#{name(request, source)} told me something about you. Want to tell me your side?"

      nil ->
        "I heard something about you today. Want to tell me your side?"
    end
  end

  def render(%Request{kind: :proactive_message} = request) do
    "#{request.speaker.name} has something to say about #{request.reason}."
  end

  def render(%Request{kind: :reply, tone: :apology} = request) do
    case apology_choice(request) do
      :keeps_apologizing -> "You keep saying sorry. I just need it to stop happening."
      :left_out -> "Thanks. I just wanted to feel remembered too."
      :nothing_to_forgive -> "You don't have to apologize. We're okay."
      :once_more -> "Okay... Just please don't make a habit of it."
      :needs_time -> "Thank you for saying that. I need a little time."
      :shaken -> "I'm still a bit shaken, but thank you."
      :accepted -> "Thank you for saying that. It means a lot."
    end
  end

  # A long record of kindness earns the benefit of the doubt, unless there has
  # been as much hostility.
  def render(%Request{kind: :reply, tone: tone, speaker: %{mood: mood}} = request)
      when tone in [:cold, :hostile] do
    if benefit_of_doubt?(request) do
      if tone == :hostile,
        do: "That's not like you. Is something wrong?",
        else: "Oh... okay. Is everything alright?"
    else
      reply(tone, mood)
    end
  end

  def render(%Request{kind: :reply, tone: :warm, speaker: %{mood: mood}} = request) do
    case Request.harshness_to_others(request) do
      {:observed, target} ->
        "Thanks... but I saw what you said to #{name(request, target)}."

      {:heard, target} ->
        "Thanks... but I heard what you said to #{name(request, target)}."

      :reputation ->
        "...Thanks. I've heard how you treat people, though."

      nil ->
        wary_reply(:warm, request) || reunion_reply(:warm, mood, request) ||
          bond_reply(:warm, mood, request) || reply(:warm, mood)
    end
  end

  def render(%Request{kind: :reply, tone: tone, speaker: %{mood: mood}} = request) do
    wary_reply(tone, request) || reunion_reply(tone, mood, request) ||
      bond_reply(tone, mood, request) || reply(tone, mood)
  end

  def render(%Request{kind: :character_interaction, reason: :gossip} = request) do
    teller = request.speaker.name
    listener = request.listener.name

    case request.memories do
      [%{data: %{"event" => "gift_received"} = data} | _] ->
        "#{teller} tells #{listener} about the #{data["item"]} " <>
          "#{name(request, data["from"])} gave #{name(request, data["to"])}."

      [%{data: %{"event" => "message_sent", "tone" => tone} = data} | _]
      when tone in ["hostile", "cold"] ->
        # Said to the teller themselves, or to someone else.
        to =
          if data["to"] == request.speaker.id, do: "", else: " to #{name(request, data["to"])}"

        "#{teller} tells #{listener} what #{name(request, data["from"])} said#{to}: \"#{data["text"]}\""

      _ ->
        "#{teller} confides in #{listener}."
    end
  end

  def render(%Request{kind: :character_interaction, reason: :together} = request) do
    "#{request.speaker.name} and #{request.listener.name} spend a quiet afternoon together."
  end

  def render(%Request{kind: :character_interaction, reason: :comfort} = request) do
    "#{request.speaker.name} stays with #{request.listener.name} for a while. " <>
      "#{request.listener.name} feels a little lighter."
  end

  def render(%Request{} = request) do
    "#{request.speaker.name} reacts."
  end

  # Back after a long absence.
  # Only when nothing darker is going on: a jealous or upset mood, or a
  # strained or estranged bond, speaks first.
  defp reunion_reply(tone, mood, request)
       when tone in [:warm, :neutral] and mood in [:neutral, :happy, :lonely] do
    cond do
      not Request.reunion?(request) -> nil
      match?(%{bond: bond} when bond in [:strained, :estranged], request.relationship) -> nil
      mood == :lonely -> "You're back... I missed you."
      tone == :warm -> "You're back! It's been a while. Thank you."
      true -> "Hey, it's been a while!"
    end
  end

  defp reunion_reply(_tone, _mood, _request), do: nil

  defp wary_reply(tone, request) do
    case wary_choice(tone, request) do
      {:bond, bond} -> bond_line(tone, bond)
      :guarded when tone == :warm -> "Thanks... I'm still a little hurt, though."
      :guarded -> "...Hey."
      nil -> nil
    end
  end

  # When the mood has nothing to say, the bond does.
  defp bond_reply(tone, mood, %Request{relationship: %{bond: bond}})
       when mood in [:neutral, :happy] do
    bond_line(tone, bond)
  end

  defp bond_reply(_tone, _mood, _request), do: nil

  defp bond_line(:warm, :close), do: "You always know how to make my day."
  defp bond_line(:warm, :strained), do: "...Thanks, I guess."
  defp bond_line(:warm, :estranged), do: "Why are you being nice to me now?"
  defp bond_line(:neutral, :close), do: "Hey, you! What's up?"
  defp bond_line(:neutral, :strained), do: "...What do you want?"
  defp bond_line(:neutral, :estranged), do: "I don't really want to talk."
  defp bond_line(_tone, _bond), do: nil

  defp reply(:warm, :happy), do: "That made my day. Thank you."
  defp reply(:warm, :jealous), do: "...Thanks. I guess I needed to hear that."
  defp reply(:warm, :lonely), do: "I really needed to hear that today."
  defp reply(:warm, :upset), do: "I'm still a little shaken, but thank you."
  defp reply(:warm, _mood), do: "That's sweet of you."
  defp reply(:neutral, :happy), do: "Hey! What's up?"
  defp reply(:neutral, :jealous), do: "Oh. Hi."
  defp reply(:neutral, :lonely), do: "Hey... it's good to hear from you."
  defp reply(:neutral, :upset), do: "...What is it?"
  defp reply(:neutral, _mood), do: "I'm listening."
  defp reply(:cold, :jealous), do: "Right. I get it."
  defp reply(:cold, _mood), do: "Oh. Okay."
  defp reply(:hostile, :upset), do: "Please stop."
  defp reply(:hostile, _mood), do: "Why would you say that?"
  defp reply(_tone, _mood), do: "..."

  defp find_memory(request, fun) do
    request.memories |> Enum.map(& &1.data) |> Enum.find(fun)
  end

  ## Choices shared with the Korean templates

  @doc false
  # Whom the listener's gift went to, and when, or `:quiet`.
  def jealous_choice(request) do
    between = {request.listener.id, request.speaker.id}

    case find_full(request, &gift_to_someone_else?(&1, between)) do
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
  # Fond memories only come up when nothing harsh stands between them.
  def lonely_choice(request) do
    between = {request.listener.id, request.speaker.id}
    fond? = not hurt?(request)
    warm = if fond?, do: find_memory(request, &warm_message?(&1, between))
    gift = if fond?, do: recent_gift(request, between)

    cond do
      warm -> {:quote, warm["text"]}
      gift -> {:gift, gift["item"]}
      fond? and kindness(request) > 0 -> :kind
      Request.reunion?(request) -> :reunion
      is_integer(request.since_contact) and request.since_contact >= 24 -> :a_while
      true -> :today
    end
  end

  @doc false
  # How an apology lands: worn thin after several, a relief to someone who
  # felt left out, unneeded when nothing was wrong, and slower to heal fresh
  # tension.
  def apology_choice(%Request{speaker: %{mood: mood}} = request) do
    listener = request.listener.id

    earlier =
      Enum.count(
        request.memories,
        &match?(%{data: %{"event" => "apology_offered", "from" => ^listener}}, &1)
      ) - 1

    harsh? =
      Enum.any?(
        request.memories,
        &match?(
          %{data: %{"event" => "message_sent", "from" => ^listener, "tone" => t}}
          when t in ["cold", "hostile"],
          &1
        )
      )

    left_out? =
      Enum.any?(
        request.memories,
        &match?(%{kind: :observed, data: %{"event" => "gift_received", "from" => ^listener}}, &1)
      )

    cond do
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
  # A record of kindness earns the benefit of the doubt, unless there has
  # been as much hostility.
  def benefit_of_doubt?(request), do: kindness(request) > hostility(request)

  @doc false
  # Hurt feelings speak before the mood: a strained or estranged bond, or
  # fresh tension from harsh words.
  def wary_choice(tone, %Request{relationship: %{bond: bond}})
      when tone in [:warm, :neutral] and bond in [:strained, :estranged],
      do: {:bond, bond}

  def wary_choice(tone, request) when tone in [:warm, :neutral] do
    if tension(request) >= @guarded_tension, do: :guarded
  end

  def wary_choice(_tone, _request), do: nil

  defp find_full(request, fun), do: Enum.find(request.memories, &fun.(&1.data))

  defp tension(%Request{relationship: %{tension: tension}}) when is_integer(tension), do: tension
  defp tension(_request), do: 0

  # A gift from the last few days; older ones may well be gone.
  defp recent_gift(request, between) do
    case find_full(request, &gift?(&1, between)) do
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

  defp name(request, id), do: Map.get(request.names, id, id)
end
