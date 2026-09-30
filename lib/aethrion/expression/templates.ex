defmodule Aethrion.Expression.Templates do
  @moduledoc """
  Deterministic text templates.

  Rules use these to give every expressive output a stable fallback line, so
  the simulation is complete and testable without any model. Templates only
  read the `Aethrion.Expression.Request` snapshot.
  """

  alias Aethrion.Expression.{Choices, Request}

  @doc "Renders the fallback text for a request."
  @spec render(Request.t()) :: String.t()
  def render(%Request{kind: :proactive_message, reason: :jealous} = request) do
    case Choices.jealous_choice(request) do
      {:gift, to, :earlier} ->
        "You looked happy with #{name(request, to)} earlier. I wondered if you forgot about me."

      {:gift, to, :other_day} ->
        "You looked happy with #{name(request, to)} the other day. I wondered if you forgot about me."

      :quiet ->
        "You've been quiet with me lately. I wondered if you forgot about me."
    end
  end

  def render(%Request{kind: :proactive_message, reason: :lonely} = request) do
    case Choices.lonely_choice(request) do
      {:quote, text} ->
        "I keep thinking about what you said: \"#{full_stop(text)}\" Do you have a minute to talk?"

      {:gift, item} ->
        "I still have the #{item} you gave me. Do you have a minute to talk?"

      :kind ->
        "You've always been kind to me. I miss talking with you. Do you have a minute?"

      :reunion ->
        "We haven't talked in a few days. Do you have a minute?"

      :a_while ->
        "It's been a while since we talked. Do you have a minute?"

      :busy ->
        "I guess you've been busy. I'll be here whenever you want to talk."

      :today ->
        "It's been quiet today. Do you have a minute to talk?"
    end
  end

  def render(%Request{kind: :proactive_message, reason: :protective} = request) do
    calm? = :calm in request.speaker.traits

    case Enum.find(request.memories, &(&1.kind == :observed)) do
      %{data: %{"to" => to}} ->
        friend = name(request, to)

        lines =
          if calm?,
            do: [
              "What you said to #{friend} was unkind. Is everything okay?",
              "That was a hard thing to say to #{friend}. Are you alright?",
              "I saw how you spoke to #{friend}. Is something going on with you?"
            ],
            else: [
              "That was harsh, what you said to #{friend}. #{friend} didn't deserve that.",
              "Why would you talk to #{friend} like that? That wasn't fair.",
              "I saw how you spoke to #{friend}. That wasn't okay."
            ]

        Choices.pick(request, lines)

      nil ->
        if calm?,
          do: "What you said was unkind. Is everything okay?",
          else: "That was harsh, what you said. Nobody deserves that."
    end
  end

  def render(%Request{kind: :proactive_message, reason: :curious} = request) do
    case Choices.curious_choice(request) do
      {news, source, data} -> curious_line(news, name(request, source), data, source, request)
      :unknown -> "I heard something about you today. Want to tell me your side?"
    end
  end

  def render(%Request{kind: :proactive_message} = request) do
    "#{request.speaker.name} has something to say about #{request.reason}."
  end

  def render(%Request{kind: :reply, tone: :gift, message: item} = request) do
    case Choices.gift_choice(request) do
      :wary ->
        "...Thanks. I don't know what to say."

      :reassured ->
        "For me? ...I thought you'd forgotten about me."

      :spoiled ->
        "Another one? You're spoiling me."

      :remembered ->
        "You thought of me? That means a lot."

      :close ->
        Choices.pick(request, [
          "You didn't have to! I love it.",
          "You spoil me. Thank you, really."
        ])

      :thanks when is_binary(item) ->
        "Thank you for the #{item}!"

      :thanks ->
        "Thank you, I love it!"
    end
  end

  def render(%Request{kind: :reply, tone: :apology} = request) do
    case Choices.apology_choice(request) do
      :settled -> "It's okay, really. We're good now."
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
    case Choices.harsh_choice(tone, request) do
      :silent -> "..."
      :done -> "I'm not doing this with you anymore."
      :again -> "Again? What is going on with you?"
      :short -> "You've been short with me lately."
      :benefit when tone == :hostile -> "That's not like you. Is something wrong?"
      :benefit -> "Oh... okay. Is everything alright?"
      :hurt -> reply(tone, mood)
    end
  end

  def render(%Request{kind: :reply, tone: :warm} = request) do
    case Request.harshness_to_others(request) do
      {:observed, target} ->
        "Thanks... but I saw what you said to #{name(request, target)}."

      {:heard, target} ->
        "Thanks... but I heard what you said to #{name(request, target)}."

      :reputation ->
        "...Thanks. I've heard how you treat people, though."

      nil ->
        reply_line(:warm, request)
    end
  end

  def render(%Request{kind: :reply, tone: tone} = request), do: reply_line(tone, request)

  def render(%Request{kind: :character_interaction, reason: :gossip} = request) do
    teller = request.speaker.name
    listener = request.listener.name

    case request.memories do
      [%{data: %{"event" => "gift_received", "to" => to} = data} | _]
      when to == request.speaker.id ->
        "#{teller} tells #{listener} about getting #{with_article(data["item"])} from #{name(request, data["from"])}."

      [%{data: %{"event" => "gift_received"} = data} | _] ->
        "#{teller} tells #{listener} about the #{data["item"]} " <>
          "#{name(request, data["from"])} gave #{name(request, data["to"])}."

      [%{data: %{"event" => "message_sent", "tone" => tone} = data} | _]
      when tone in ["hostile", "cold"] ->
        # Said to the teller themselves, or to someone else.
        to =
          if data["to"] == request.speaker.id, do: "", else: " to #{name(request, data["to"])}"

        "#{teller} tells #{listener} what #{name(request, data["from"])} said#{to}: \"#{data["text"]}\""

      # Harsh words matched above; what is left of messages is kind.
      [%{data: %{"event" => event} = data} | _]
      when event in ["apology_offered", "comfort_offered", "message_sent"] ->
        from = name(request, data["from"])
        to = if data["to"] == request.speaker.id, do: teller, else: name(request, data["to"])

        case event do
          "apology_offered" ->
            "#{teller} tells #{listener} that #{from} apologized to #{to}."

          "comfort_offered" ->
            "#{teller} tells #{listener} how #{from} comforted #{to}."

          "message_sent" ->
            "#{teller} tells #{listener} how kind #{from} #{if from == "you", do: "were", else: "was"} to #{to}."
        end

      _ ->
        "#{teller} confides in #{listener}."
    end
  end

  def render(%Request{kind: :character_interaction, reason: :together} = request) do
    {a, b} = {request.speaker.name, request.listener.name}

    case Choices.together_choice(request) do
      0 -> "#{a} and #{b} spend a quiet afternoon together."
      1 -> "#{a} and #{b} go for a long walk and talk about nothing in particular."
      2 -> "#{a} and #{b} share dinner and stay up talking."
      3 -> "#{a} and #{b} sit together for a while, not needing to say much."
    end
  end

  def render(%Request{kind: :character_interaction, reason: :comfort} = request) do
    "#{request.speaker.name} stays with #{request.listener.name} for a while. " <>
      "#{request.listener.name} feels a little lighter."
  end

  def render(%Request{} = request) do
    "#{request.speaker.name} reacts."
  end

  # "Them" when the teller told about themselves.
  defp curious_line(:gift, teller, data, source, request) do
    {told, mentioned} =
      if data["to"] == source,
        do:
          {"told me about getting #{with_article(data["item"])} from you",
           "mentioned getting #{with_article(data["item"])} from you"},
        else:
          {"told me you gave #{name(request, data["to"])} #{with_article(data["item"])}",
           "mentioned you gave #{name(request, data["to"])} #{with_article(data["item"])}"}

    cond do
      :playful in request.speaker.traits -> "#{teller} #{told}. Smooth."
      :calm in request.speaker.traits -> "#{teller} #{mentioned}. I bet that made their day."
      true -> "#{teller} #{mentioned}. Is there something I should know?"
    end
  end

  defp curious_line(:harsh, teller, data, source, request) do
    said = if data["to"] == source, do: "", else: " to #{name(request, data["to"])}"
    "#{teller} told me what you said#{said}. That didn't sound like you. Is everything okay?"
  end

  defp curious_line(:warm, teller, data, source, request),
    do:
      "#{teller} told me how kind you were to #{them(request, data, source)}. That was sweet of you."

  defp curious_line(:comfort, teller, data, source, request),
    do:
      "#{teller} told me you were there for #{them(request, data, source)}. That was kind of you."

  defp curious_line(:apology, teller, data, source, request) do
    to = if data["to"] == source, do: "", else: " to #{name(request, data["to"])}"
    "#{teller} told me you apologized#{to}. That was good of you."
  end

  defp curious_line(:other, teller, _data, _source, _request),
    do: "#{teller} told me something about you. Want to tell me your side?"

  defp them(request, data, source),
    do: if(data["to"] == source, do: "them", else: name(request, data["to"]))

  defp reply_line(tone, request) do
    case Choices.reply_choice(tone, request) do
      {:bond, bond} -> Choices.pick(request, bond_line(tone, bond))
      :guarded when tone == :warm -> "Thanks... I'm still a little hurt, though."
      :guarded -> "...Hey."
      {:reunion, :missed} -> "You're back... I missed you."
      {:reunion, :thanks} -> "You're back! It's been a while. Thank you."
      {:reunion, :hello} -> "Hey, it's been a while!"
      {:mood, mood} -> Choices.pick(request, reply(tone, mood))
    end
  end

  defp bond_line(:warm, :close),
    do: [
      "You always know how to make my day.",
      "You're the best, you know that?",
      "Hearing from you is my favorite part of the day."
    ]

  defp bond_line(:warm, :strained), do: "...Thanks, I guess."
  defp bond_line(:warm, :estranged), do: "Why are you being nice to me now?"

  defp bond_line(:neutral, :close),
    do: [
      "Hey, you! What's up?",
      "There you are! What's new?",
      "Hi! I was just thinking about you."
    ]

  defp bond_line(:neutral, :strained), do: "...What do you want?"
  defp bond_line(:neutral, :estranged), do: "I don't really want to talk."
  defp bond_line(_tone, _bond), do: nil

  defp reply(:warm, :happy),
    do: [
      "That made my day. Thank you.",
      "Aw, thank you! I'm smiling.",
      "You're making a good day even better."
    ]

  defp reply(:warm, :jealous), do: "...Thanks. I guess I needed to hear that."

  defp reply(:warm, :lonely),
    do: [
      "I really needed to hear that today.",
      "Thank you. I was feeling a bit alone.",
      "It helps to hear from you."
    ]

  defp reply(:warm, :upset), do: "I'm still a little shaken, but thank you."

  defp reply(:warm, _mood),
    do: ["That's sweet of you.", "Thank you, really.", "You're kind. Thanks."]

  defp reply(:neutral, :happy), do: "Hey! What's up?"
  defp reply(:neutral, :jealous), do: "Oh. Hi."
  defp reply(:neutral, :lonely), do: "Hey... it's good to hear from you."
  defp reply(:neutral, :upset), do: "...What is it?"

  defp reply(:neutral, _mood),
    do: ["I'm listening.", "Yeah? What's up?", "Okay.", "Mm-hm. Go on."]

  defp reply(:cold, :jealous), do: "Right. I get it."
  defp reply(:cold, _mood), do: "Oh. Okay."
  defp reply(:hostile, :upset), do: "Please stop."
  defp reply(:hostile, _mood), do: "Why would you say that?"
  defp reply(_tone, _mood), do: "..."

  defp name(request, id), do: Map.get(request.names, id, id)

  # A quoted line ends a sentence: "hey" becomes "hey."
  defp full_stop(text) do
    if String.match?(text, ~r/[.!?…~)]$/u), do: text, else: text <> "."
  end

  @doc false
  # "a flower", "an apple", "an hour", "a unicorn", "cookies": the article an
  # item needs, if any. Items not written in Latin letters are left alone.
  @spec with_article(String.t()) :: String.t()
  def with_article(item) do
    word = String.downcase(item)

    cond do
      not String.match?(item, ~r/^[A-Za-z]/) -> item
      plural?(word) -> item
      String.match?(word, ~r/^(hour|honest|honou?r|heir)/) -> "an " <> item
      String.match?(word, ~r/^(uni|use|usu|eu|one|once)/) -> "a " <> item
      String.match?(word, ~r/^[aeiou]/) -> "an " <> item
      true -> "a " <> item
    end
  end

  # "cookies", "flowers", "glasses" but not "glass", "bus", "cactus", "iris".
  defp plural?(word) do
    String.ends_with?(word, "s") and
      not String.match?(word, ~r/(ss|us|is|ys|os)$/)
  end
end
