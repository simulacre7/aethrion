defmodule Aethrion.Expression.Templates.Ko do
  @moduledoc """
  Korean deterministic templates.

  Used by `Aethrion.LLM.FakeAdapter` with `locale: :ko`. Like the English
  templates, they only read the `Aethrion.Expression.Request` snapshot, so
  switching language never changes the simulation:

      Aethrion.Expression.render(outputs,
        adapter: Aethrion.LLM.FakeAdapter,
        adapter_opts: [locale: :ko]
      )

  Particles (이/가, 은/는, 을/를, 이랑/랑, 과/와) are chosen from the final
  sound of each name, for Hangul and Latin-script names alike.
  """

  alias Aethrion.Expression.Request

  @doc "Renders a request in Korean."
  def render(%Request{kind: :proactive_message, reason: :jealous} = request) do
    case find(request, &gift_from_listener_to_other?(&1, request)) do
      %{"to" => to} ->
        "아까 #{with_particle(name(request, to), :and)} 있을 때 즐거워 보이더라. 혹시 나는 잊은 거 아니지?"

      nil ->
        "요즘 나한테 좀 조용하네. 혹시 나 잊은 거 아니지?"
    end
  end

  def render(%Request{kind: :proactive_message, reason: :lonely} = request) do
    between = {request.listener.id, request.speaker.id}

    cond do
      data = find(request, &warm_message?(&1, between)) ->
        "네가 했던 말이 계속 생각나. \"#{data["text"]}\" 잠깐 얘기할 수 있어?"

      data = find(request, &gift?(&1, between)) ->
        "네가 준 #{data["item"]}, 아직 가지고 있어. 잠깐 얘기할 수 있어?"

      find(request, &kind_impression?(&1, between)) ->
        "넌 늘 나한테 다정했잖아. 얘기하고 싶어. 잠깐 시간 돼?"

      true ->
        "오늘은 좀 조용하네. 잠깐 얘기할 수 있어?"
    end
  end

  def render(%Request{kind: :proactive_message, reason: :protective} = request) do
    friend =
      case Enum.find(request.memories, &(&1.kind == :observed)) do
        %{data: %{"to" => to}} -> name(request, to)
        nil -> "걔"
      end

    if :calm in request.speaker.traits,
      do: "아까 #{friend}한테 한 말은 좀 모질었어. 무슨 일 있어?",
      else: "#{friend}한테 한 말, 좀 심했어. #{with_particle(friend, :topic)} 그런 말 들을 이유 없었어."
  end

  def render(%Request{kind: :proactive_message, reason: :curious} = request) do
    case Enum.find(request.memories, &(&1.kind == :heard)) do
      %{source: source, data: %{"event" => "gift_received"} = data} ->
        heard =
          "#{name(request, source)}한테 들었어. #{name(request, data["to"])}한테 #{data["item"]} 줬다며?"

        if :playful in request.speaker.traits,
          do: heard <> " 제법인데.",
          else: heard <> " 나한테 할 말 없어?"

      %{source: source, data: %{"event" => "message_sent", "tone" => tone}}
      when tone in ["hostile", "cold"] ->
        "#{name(request, source)}한테 네가 한 말 들었어. 너답지 않던데, 무슨 일 있어?"

      %{source: source} ->
        "#{name(request, source)}한테 네 얘기 좀 들었어. 네 입장도 듣고 싶은데?"

      nil ->
        "오늘 네 얘기를 좀 들었어. 네 입장도 듣고 싶은데?"
    end
  end

  def render(%Request{kind: :proactive_message} = request) do
    "#{with_particle(request.speaker.name, :topic)} 할 말이 있는 것 같다."
  end

  def render(%Request{kind: :reply, tone: tone, speaker: %{mood: mood}} = request)
      when tone in [:cold, :hostile] do
    if find(request, &kind_impression?(&1, {request.listener.id, request.speaker.id})) do
      if tone == :hostile, do: "너답지 않은데. 무슨 일 있어?", else: "아... 그래. 괜찮은 거지?"
    else
      reply(tone, mood)
    end
  end

  def render(%Request{kind: :reply, tone: :warm, speaker: %{mood: mood}} = request) do
    case Request.harshness_to_others(request) do
      {:observed, target} -> "고마워... 그런데 네가 #{name(request, target)}한테 한 말, 나도 봤어."
      {:heard, target} -> "고마워... 그런데 네가 #{name(request, target)}한테 한 말, 나도 들었어."
      :reputation -> "...고마워. 그런데 네가 다른 사람들한테 어떻게 하는지 들었어."
      nil -> reply(:warm, mood)
    end
  end

  def render(%Request{kind: :reply, tone: tone, speaker: %{mood: mood}}), do: reply(tone, mood)

  def render(%Request{kind: :character_interaction, reason: :gossip} = request) do
    teller = request.speaker.name
    listener = request.listener.name

    case request.memories do
      [%{data: %{"event" => "gift_received"} = data} | _] ->
        giver =
          if data["from"] == "user",
            do: "네가",
            else: with_particle(name(request, data["from"]), :subject)

        "#{with_particle(teller, :topic)} #{listener}에게 #{giver} #{name(request, data["to"])}한테 준 " <>
          "#{data["item"]} 이야기를 털어놓는다."

      [%{data: %{"event" => "message_sent", "tone" => tone} = data} | _]
      when tone in ["hostile", "cold"] ->
        said =
          if data["from"] == "user",
            do: "네가",
            else: with_particle(name(request, data["from"]), :subject)

        "#{with_particle(teller, :topic)} #{listener}에게 #{said} 한 말을 전한다. \"#{data["text"]}\""

      _ ->
        "#{with_particle(teller, :topic)} #{listener}에게 속마음을 털어놓는다."
    end
  end

  def render(%Request{kind: :character_interaction, reason: :together} = request) do
    "#{with_particle(request.speaker.name, :with)} #{with_particle(request.listener.name, :topic)} 함께 조용한 오후를 보낸다."
  end

  def render(%Request{kind: :character_interaction, reason: :comfort} = request) do
    "#{with_particle(request.speaker.name, :topic)} 한동안 #{request.listener.name} 곁에 있어 준다. " <>
      "#{with_particle(request.listener.name, :subject)} 조금 가벼워진 얼굴이다."
  end

  def render(%Request{} = request) do
    "#{with_particle(request.speaker.name, :subject)} 반응한다."
  end

  defp reply(:warm, :happy), do: "덕분에 기분 좋아졌어. 고마워."
  defp reply(:warm, :jealous), do: "...고마워. 그 말이 듣고 싶었나 봐."
  defp reply(:warm, :lonely), do: "오늘 그 말이 정말 필요했어."
  defp reply(:warm, :upset), do: "아직 좀 속상하지만, 고마워."
  defp reply(:warm, _mood), do: "다정하네."
  defp reply(:neutral, :happy), do: "응! 무슨 일이야?"
  defp reply(:neutral, :jealous), do: "아, 안녕."
  defp reply(:neutral, :lonely), do: "연락 줘서 반가워."
  defp reply(:neutral, :upset), do: "...왜?"
  defp reply(:neutral, _mood), do: "듣고 있어."
  defp reply(:cold, :jealous), do: "그래, 알겠어."
  defp reply(:cold, _mood), do: "아... 그래."
  defp reply(:hostile, :upset), do: "그만해 줘."
  defp reply(:hostile, _mood), do: "왜 그런 말을 해?"
  defp reply(_tone, _mood), do: "..."

  @doc """
  Appends the Korean particle that fits `word`'s final sound. `kind` is
  `:subject` (이/가), `:topic` (은/는), `:object` (을/를), `:and` (이랑/랑),
  or `:with` (과/와).
  """
  def with_particle(word, kind) do
    {with_batchim, without} =
      case kind do
        :subject -> {"이", "가"}
        :topic -> {"은", "는"}
        :object -> {"을", "를"}
        :and -> {"이랑", "랑"}
        :with -> {"과", "와"}
      end

    word <> if(batchim?(word), do: with_batchim, else: without)
  end

  @doc false
  def batchim?(word) do
    # Compose first (macOS and some inputs use decomposed Hangul), then read the
    # last letter, skipping trailing emoji, punctuation, and variation selectors.
    word
    |> :unicode.characters_to_nfc_binary()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.find_value(false, fn codepoint ->
      cond do
        # Hangul syllables: a final consonant exists when (code - 0xAC00) % 28 != 0.
        codepoint in 0xAC00..0xD7A3 -> {:ok, rem(codepoint - 0xAC00, 28) != 0}
        # Latin names read with a final consonant sound when they end in one.
        codepoint in ?a..?z or codepoint in ?A..?Z -> {:ok, codepoint not in ~c"aeiouyAEIOUY"}
        true -> nil
      end
    end)
    |> case do
      {:ok, batchim?} -> batchim?
      false -> false
    end
  end

  defp find(request, fun), do: request.memories |> Enum.map(& &1.data) |> Enum.find(fun)

  defp gift_from_listener_to_other?(%{"event" => "gift_received"} = data, request),
    do: data["from"] == request.listener.id and data["to"] != request.speaker.id

  defp gift_from_listener_to_other?(_data, _request), do: false

  defp warm_message?(%{"event" => "message_sent", "tone" => "warm"} = data, {from, to}),
    do: data["from"] == from and data["to"] == to

  defp warm_message?(_data, _between), do: false

  defp gift?(%{"event" => "gift_received"} = data, {from, to}),
    do: data["from"] == from and data["to"] == to

  defp gift?(_data, _between), do: false

  defp kind_impression?(%{"event" => "impression"} = data, {from, to}),
    do:
      data["from"] == from and data["to"] == to and
        data["pattern"] in ["warm", "gift", "comfort", "together"]

  defp kind_impression?(_data, _between), do: false

  defp name(_request, "user"), do: "너"
  defp name(request, id), do: Map.get(request.names, id, id)
end
