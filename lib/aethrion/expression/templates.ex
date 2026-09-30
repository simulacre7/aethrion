defmodule Aethrion.Expression.Templates do
  @moduledoc """
  Deterministic text templates.

  Rules use these to give every expressive output a stable fallback line, so
  the simulation is complete and testable without any model. Templates only
  read the `Aethrion.Expression.Request` snapshot.
  """

  alias Aethrion.Expression.Request

  @doc "Renders the fallback text for a request."
  def render(%Request{kind: :proactive_message, reason: :jealous} = request) do
    between = {request.listener.id, request.speaker.id}

    case find_memory(request, &gift_to_someone_else?(&1, between)) do
      %{"to" => to} ->
        "You looked happy with #{name(request, to)} earlier. I wondered if you forgot about me."

      nil ->
        "You've been quiet with me lately. I wondered if you forgot about me."
    end
  end

  def render(%Request{kind: :proactive_message, reason: :lonely} = request) do
    between = {request.listener.id, request.speaker.id}

    cond do
      data = find_memory(request, &warm_message?(&1, between)) ->
        "I keep thinking about what you said: \"#{data["text"]}\" Do you have a minute to talk?"

      data = find_memory(request, &gift?(&1, between)) ->
        "I still have the #{data["item"]} you gave me. Do you have a minute to talk?"

      find_memory(request, &impression?(&1, between, ["warm", "gift", "comfort"])) ->
        "You've always been kind to me. I miss talking with you. Do you have a minute?"

      true ->
        "It's been quiet today. Do you have a minute to talk?"
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

  def render(%Request{kind: :reply, tone: tone, speaker: %{mood: mood}}) do
    reply(tone, mood)
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
        "#{teller} tells #{listener} what #{name(request, data["from"])} said: \"#{data["text"]}\""

      _ ->
        "#{teller} confides in #{listener}."
    end
  end

  def render(%Request{kind: :character_interaction, reason: :comfort} = request) do
    "#{request.speaker.name} stays with #{request.listener.name} for a while. " <>
      "#{request.listener.name} feels a little lighter."
  end

  def render(%Request{} = request) do
    "#{request.speaker.name} reacts."
  end

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
