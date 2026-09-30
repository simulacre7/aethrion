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

  alias Aethrion.Expression.{Request, Templates}

  # Latin words that end in a pronounced e (애니메, 우쿨렐레), unlike Jane or Nicole.
  @spoken_e ~w(anime sesame penne persephone karaoke ukulele adobe finale chile tamale pele)

  @doc """
  Renders a request in Korean. With `tense: :past`, scenes between
  characters are told as having happened ("함께 저녁을 먹고 늦게까지
  이야기했다."), as a digest tells them.
  """
  @spec render(Request.t(), keyword()) :: String.t()
  def render(%Request{} = request, opts) do
    text = render(request)

    case {Keyword.get(opts, :tense), request.kind} do
      {:past, :character_interaction} -> past(text)
      _present -> text
    end
  end

  # Present-tense narration endings and their past forms. The quoted part of a
  # line (someone's words) is left alone.
  @past [
    {"털어놓는다.", "털어놓았다."},
    {"전한다.", "전했다."},
    {"자랑한다.", "자랑했다."},
    {"보낸다.", "보냈다."},
    {"나눈다.", "나눴다."},
    {"이야기한다.", "이야기했다."},
    {"앉아 있다.", "앉아 있었다."},
    {"있어 준다.", "있어 주었다."},
    {"가벼워진다.", "가벼워졌다."},
    {"반응한다.", "반응했다."}
  ]

  defp past(text) do
    {narration, quoted} =
      case Regex.run(~r/^(.*?\.)( ".*")$/su, text) do
        [_all, narration, quoted] -> {narration, quoted}
        nil -> {text, ""}
      end

    Enum.reduce(@past, narration, fn {now, then}, acc -> String.replace(acc, now, then) end) <>
      quoted
  end

  @doc """
  A count in native Korean with 번: `times(3)` is "세 번". Past ten, digits.
  """
  @spec times(non_neg_integer()) :: String.t()
  def times(count) when count in 1..10,
    do: Enum.at(~w(한 두 세 네 다섯 여섯 일곱 여덟 아홉 열), count - 1) <> " 번"

  def times(count), do: "#{count}번"

  @doc "Renders a request in Korean."
  def render(%Request{kind: :proactive_message, reason: :jealous} = request) do
    case Templates.jealous_choice(request) do
      {:gift, to, when_seen} ->
        moment = if when_seen == :earlier, do: "아까", else: "지난번에"

        "#{moment} #{with_particle(name(request, to), :and)} 있을 때 즐거워 보이더라. 혹시 나는 잊은 거 아니지?"

      :quiet ->
        "요즘 나한테 좀 조용하네. 혹시 나 잊은 거 아니지?"
    end
  end

  def render(%Request{kind: :proactive_message, reason: :lonely} = request) do
    case Templates.lonely_choice(request) do
      {:quote, text} -> "네가 했던 말이 계속 생각나. \"#{text}\" 잠깐 얘기할 수 있어?"
      {:gift, item} -> "네가 준 #{item}, 아직 가지고 있어. 잠깐 얘기할 수 있어?"
      :kind -> "넌 늘 나한테 다정했잖아. 너랑 얘기하던 게 그리워. 잠깐 시간 돼?"
      :reunion -> "며칠째 얘기를 못 했네. 잠깐 시간 돼?"
      :a_while -> "한동안 얘기를 못 했네. 잠깐 시간 돼?"
      :busy -> "요즘 많이 바쁜가 보네. 얘기하고 싶을 때 언제든 연락해."
      :today -> "오늘은 좀 조용하네. 잠깐 얘기할 수 있어?"
    end
  end

  def render(%Request{kind: :proactive_message, reason: :protective} = request) do
    calm? = :calm in request.speaker.traits

    case Enum.find(request.memories, &(&1.kind == :observed)) do
      %{data: %{"to" => to}} ->
        friend = name(request, to)

        lines =
          if calm?,
            do: ["#{friend}한테 한 말은 좀 모질었어. 무슨 일 있어?", "#{friend}한테 그런 말은 좀 아니었어. 괜찮은 거야?"],
            else: [
              "#{friend}한테 한 말, 좀 심했어. 걔는 그런 말 들을 이유 없었어.",
              "#{friend}한테 왜 그렇게 말했어? 그건 좀 너무했어.",
              "#{friend}한테 말하는 거 봤어. 그러면 안 돼."
            ]

        Templates.pick(request, lines)

      nil ->
        if calm?,
          do: "아까 한 말은 좀 모질었어. 무슨 일 있어?",
          else: "아까 한 말, 좀 심했어. 누구도 그런 말 들을 이유는 없어."
    end
  end

  def render(%Request{kind: :proactive_message, reason: :curious} = request) do
    case Enum.find(request.memories, &(&1.kind == :heard)) do
      %{source: source, data: %{"event" => "gift_received"} = data} ->
        to = if data["to"] == source, do: "걔", else: name(request, data["to"])
        heard = "#{name(request, source)}한테 들었어. #{to}한테 #{data["item"]} 줬다며?"

        if :playful in request.speaker.traits,
          do: heard <> " 제법인데.",
          else: heard <> " 나한테 할 말 없어?"

      %{source: source, data: %{"event" => "message_sent", "tone" => tone} = data}
      when tone in ["hostile", "cold"] ->
        to = if data["to"] == source, do: "걔", else: name(request, data["to"])

        "#{name(request, source)}한테 들었어. 네가 #{to}한테 그런 말 했다며? " <>
          "너답지 않던데, 무슨 일 있어?"

      %{source: source} ->
        "#{name(request, source)}한테 네 얘기 좀 들었어. 네 입장도 듣고 싶은데?"

      nil ->
        "오늘 네 얘기를 좀 들었어. 네 입장도 듣고 싶은데?"
    end
  end

  def render(%Request{kind: :proactive_message} = request) do
    "#{with_particle(request.speaker.name, :topic)} 할 말이 있는 것 같다."
  end

  def render(%Request{kind: :reply, tone: :gift, message: item} = request) do
    case Templates.gift_choice(request) do
      :wary -> "...고마워. 뭐라고 해야 할지 모르겠네."
      :reassured -> "나한테 주는 거야? ...나 잊은 줄 알았어."
      :spoiled -> "또 줘? 이러다 버릇 나빠지겠다."
      :remembered -> "내 생각 해 준 거야? 정말 고마워."
      :close -> "이런 거 안 해도 되는데! 너무 좋다."
      :thanks when is_binary(item) -> "#{with_particle(item, :subject)} 마음에 들어. 고마워!"
      :thanks -> "마음에 들어. 고마워!"
    end
  end

  def render(%Request{kind: :reply, tone: :apology} = request) do
    case Templates.apology_choice(request) do
      :keeps_apologizing -> "계속 미안하다고만 하네. 그냥 그런 일이 없었으면 좋겠어."
      :left_out -> "고마워. 나도 좀 챙겨 줬으면 해서 그랬어."
      :nothing_to_forgive -> "사과할 거 없어. 우리 괜찮아."
      :once_more -> "알았어... 그래도 자꾸 그러진 말아 줘."
      :needs_time -> "말해 줘서 고마워. 조금만 시간을 줘."
      :shaken -> "아직 좀 놀랐지만, 고마워."
      :accepted -> "그렇게 말해 줘서 고마워. 마음이 좀 풀렸어."
    end
  end

  def render(%Request{kind: :reply, tone: tone, speaker: %{mood: mood}} = request)
      when tone in [:cold, :hostile] do
    case Templates.harsh_choice(tone, request) do
      :silent -> "..."
      :done -> "더는 너랑 이런 얘기 안 할래."
      :again -> "또? 대체 왜 그러는 거야?"
      :short -> "요즘 나한테 좀 차갑네."
      :benefit when tone == :hostile -> "너답지 않은데. 무슨 일 있어?"
      :benefit -> "아... 그래. 괜찮은 거지?"
      :hurt -> reply(tone, mood)
    end
  end

  def render(%Request{kind: :reply, tone: :warm, speaker: %{mood: mood}} = request) do
    case Request.harshness_to_others(request) do
      {:observed, target} ->
        "고마워... 그런데 네가 #{name(request, target)}한테 한 말, 나도 봤어."

      {:heard, target} ->
        "고마워... 그런데 네가 #{name(request, target)}한테 한 말, 나도 들었어."

      :reputation ->
        "...고마워. 그런데 네가 다른 사람들한테 어떻게 하는지 들었어."

      nil ->
        wary_reply(:warm, request) || reunion_reply(:warm, mood, request) ||
          bond_reply(:warm, mood, request) || Templates.pick(request, reply(:warm, mood))
    end
  end

  def render(%Request{kind: :reply, tone: tone, speaker: %{mood: mood}} = request) do
    wary_reply(tone, request) || reunion_reply(tone, mood, request) ||
      bond_reply(tone, mood, request) || Templates.pick(request, reply(tone, mood))
  end

  def render(%Request{kind: :character_interaction, reason: :gossip} = request) do
    teller = request.speaker.name
    listener = request.listener.name

    case request.memories do
      [%{data: %{"event" => "gift_received", "to" => to} = data} | _]
      when to == request.speaker.id ->
        giver =
          if data["from"] == "user",
            do: "네가",
            else: with_particle(name(request, data["from"]), :subject)

        "#{with_particle(teller, :topic)} #{listener}에게 #{giver} 준 " <>
          "#{with_particle(data["item"], :object)} 자랑한다."

      [%{data: %{"event" => "gift_received"} = data} | _] ->
        giver =
          if data["from"] == "user",
            do: "네가",
            else: with_particle(name(request, data["from"]), :subject)

        "#{with_particle(teller, :topic)} #{listener}에게 #{giver} #{name(request, data["to"])}한테 준 " <>
          "#{data["item"]} 얘기를 전한다."

      [%{data: %{"event" => "message_sent", "tone" => tone} = data} | _]
      when tone in ["hostile", "cold"] ->
        said =
          if data["from"] == "user",
            do: "네가",
            else: with_particle(name(request, data["from"]), :subject)

        # Said to the teller themselves ("자기한테"), or to someone else.
        to =
          if data["to"] == request.speaker.id,
            do: "자기한테",
            else: "#{name(request, data["to"])}한테"

        "#{with_particle(teller, :topic)} #{listener}에게 #{said} #{to} 한 말을 전한다. \"#{data["text"]}\""

      _ ->
        "#{with_particle(teller, :topic)} #{listener}에게 속마음을 털어놓는다."
    end
  end

  def render(%Request{kind: :character_interaction, reason: :together} = request) do
    pair =
      "#{with_particle(request.speaker.name, :with)} #{with_particle(request.listener.name, :topic)}"

    case Templates.together_choice(request) do
      0 -> "#{pair} 함께 조용한 오후를 보낸다."
      1 -> "#{pair} 한참을 걸으며 이런저런 이야기를 나눈다."
      2 -> "#{pair} 같이 저녁을 먹고 늦게까지 이야기한다."
      3 -> "#{pair} 별말 없이 한동안 함께 앉아 있다."
    end
  end

  def render(%Request{kind: :character_interaction, reason: :comfort} = request) do
    "#{with_particle(request.speaker.name, :topic)} 한동안 #{request.listener.name} 곁에 있어 준다. " <>
      "#{request.listener.name}의 표정이 한결 가벼워진다."
  end

  def render(%Request{} = request) do
    "#{with_particle(request.speaker.name, :subject)} 반응한다."
  end

  # Only when nothing darker is going on: a jealous or upset mood, or a
  # strained or estranged bond, speaks first.
  defp reunion_reply(tone, mood, request)
       when tone in [:warm, :neutral] and mood in [:neutral, :happy, :lonely] do
    cond do
      not Request.reunion?(request) -> nil
      match?(%{bond: bond} when bond in [:strained, :estranged], request.relationship) -> nil
      mood == :lonely -> "연락 왔네... 보고 싶었어."
      tone == :warm -> "오랜만이야! 고마워."
      true -> "오랜만이네!"
    end
  end

  defp reunion_reply(_tone, _mood, _request), do: nil

  defp wary_reply(tone, request) do
    case Templates.wary_choice(tone, request) do
      {:bond, bond} -> bond_line(tone, bond)
      :guarded when tone == :warm -> "고마워... 그래도 아직 좀 서운해."
      :guarded -> "...응, 왜."
      nil -> nil
    end
  end

  defp bond_reply(tone, mood, %Request{relationship: %{bond: bond}} = request)
       when mood in [:neutral, :happy],
       do: Templates.pick(request, bond_line(tone, bond))

  defp bond_reply(_tone, _mood, _request), do: nil

  defp bond_line(:warm, :close),
    do: ["역시 너밖에 없어. 고마워.", "너 진짜 최고야, 알지?", "네 연락이 하루 중에 제일 반가워."]

  defp bond_line(:warm, :strained), do: "...그래, 고마워."
  defp bond_line(:warm, :estranged), do: "이제 와서 왜 잘해 주는 건데?"
  defp bond_line(:neutral, :close), do: ["왔어? 무슨 일이야?", "왔구나! 별일 없어?", "안녕! 마침 네 생각 하고 있었어."]
  defp bond_line(:neutral, :strained), do: "...무슨 일인데?"
  defp bond_line(:neutral, :estranged), do: "별로 얘기하고 싶지 않아."
  defp bond_line(_tone, _bond), do: nil

  defp reply(:warm, :happy), do: ["덕분에 기분 좋아졌어. 고마워.", "고마워! 웃음이 나네.", "좋은 하루가 더 좋아졌어."]
  defp reply(:warm, :jealous), do: "...고마워. 그 말이 듣고 싶었나 봐."
  defp reply(:warm, :lonely), do: ["오늘 그 말이 정말 필요했어.", "고마워. 좀 외로웠거든.", "네 연락 받으니까 좀 낫다."]
  defp reply(:warm, :upset), do: "아직 좀 속상하지만, 고마워."
  defp reply(:warm, _mood), do: ["다정하네.", "고마워, 진심으로.", "넌 참 다정하다. 고마워."]
  defp reply(:neutral, :happy), do: "응! 무슨 일이야?"
  defp reply(:neutral, :jealous), do: "아, 안녕."
  defp reply(:neutral, :lonely), do: "연락 줘서 반가워."
  defp reply(:neutral, :upset), do: "...왜?"
  defp reply(:neutral, _mood), do: ["응, 무슨 일이야?", "응, 왜?", "나야 뭐 그럭저럭. 너는?"]
  defp reply(:cold, :jealous), do: "그래, 알겠어."
  defp reply(:cold, _mood), do: "아... 그래."
  defp reply(:hostile, :upset), do: "그만해 줘."
  defp reply(:hostile, _mood), do: "왜 그런 말을 해?"
  defp reply(_tone, _mood), do: "..."

  # How a Latin word's end is usually read in Korean. Vowels and -r, -w, -h
  # have no final consonant (flower 플라워, show 쇼, Smith 스미스), nor do
  # endings Korean reads with an added vowel: -s, -x, -f, -v, -z, -d (Alex
  # 알렉스, scarf 스카프, postcard 포스트카드), and -t, -k, -p after another
  # consonant (desk 데스크, gift 기프트). Other consonants do (book 북, Sol 솔),
  # as do -ck and a silent e after n or m.
  defp latin_batchim?(word) do
    letters =
      word
      |> String.downcase()
      |> String.replace(~r/[^a-z]/, "")
      |> String.reverse()
      |> String.to_charlist()

    case letters do
      # -ck (Jack 잭), and -ne or -me with a silent e after a vowel or in -nne
      # (Jane 제인, Jerome 제롬, Anne 앤), except words that say the e.
      [?k, ?c | _] -> true
      # -le reads as ㄹ: Nicole 니콜, candle 캔들, apple 애플.
      [?e, ?l | _] -> String.downcase(word) not in @spoken_e
      [?e, before, third | _] when before in ~c"nm" -> silent_e?(word, before, third)
      [last | _] when last in ~c"aeiouyrwhsxfvzd" -> false
      [last, before | _] when last in ~c"tkp" -> before in ~c"aeiouy"
      [_last | _] -> true
      [] -> false
    end
  end

  defp silent_e?(word, before, third) do
    (third in ~c"aeiouy" or (before == ?n and third == ?n)) and
      String.downcase(word) not in @spoken_e
  end

  @doc """
  One-line Korean description of an event, like `Aethrion.Event.describe/2`.
  `names` maps ids to display names. Custom event types fall back to the
  English description.
  """
  @spec describe_event(map(), (String.t() -> String.t())) :: String.t()
  def describe_event(event, names) do
    name = fn id -> names.(id) end
    subject = fn id -> subject(name.(id)) end

    case event do
      %{type: :gift_received} ->
        "#{subject.(event.from)} #{name.(event.to)}에게 #{with_particle(event.item, :object)} 준다" <>
          seen_by(event, name)

      %{type: :message_sent} ->
        "#{name.(event.from)} → #{name.(event.to)} (#{ko_tone(event.tone)}): #{event.text}" <>
          seen_by(event, name)

      %{type: :apology_offered} ->
        "#{subject.(event.from)} #{name.(event.to)}에게 사과한다: #{event.reason}" <>
          seen_by(event, name)

      %{type: :time_tick, hours: hours} ->
        "#{hours}시간이 흐른다"

      %{type: :gossip_shared} ->
        "#{with_particle(name.(event.from), :topic)} #{name.(event.to)}에게 속마음을 털어놓는다"

      %{type: :comfort_offered} ->
        "#{subject.(event.from)} #{with_particle(name.(event.to), :object)} 위로한다"

      %{type: :time_spent_together} ->
        "#{with_particle(name.(event.from), :with)} #{with_particle(name.(event.to), :topic)} 함께 시간을 보낸다"

      _other ->
        Aethrion.Event.describe(event, names)
    end
  end

  @doc """
  One-line Korean description of a memory, from its structured data, for
  Korean reports. `names` maps ids to display names. Memories without
  recognizable data keep their content.
  """
  @spec describe_memory(Aethrion.Memory.t(), (String.t() -> String.t())) :: String.t()
  def describe_memory(%Aethrion.Memory{} = memory, names) do
    text =
      case memory.data do
        %{"event" => event} = data when event in ["impression", "reputation"] ->
          Aethrion.Digest.belief_text(data, names.(memory.character_id), :ko, names)

        data ->
          describe_data(data, names)
      end

    case {text, memory} do
      {nil, _memory} ->
        memory.content

      {text, %{kind: :heard, source: source}} when is_binary(source) ->
        "#{names.(source)}한테 들음: #{text}"

      {text, _memory} ->
        text
    end
  end

  defp describe_data(
         %{"event" => "gift_received", "from" => from, "to" => to, "item" => item},
         names
       ),
       do: "#{subject(names.(from))} #{names.(to)}에게 #{with_particle(item, :object)} 줬다."

  defp describe_data(
         %{"event" => "message_sent", "from" => from, "to" => to, "tone" => tone} = data,
         names
       ) do
    how =
      case tone do
        "warm" -> "다정하게"
        "cold" -> "차갑게"
        "hostile" -> "모질게"
        _other -> ""
      end

    "#{subject(names.(from))} #{names.(to)}에게 #{how} 말했다: \"#{data["text"]}\""
  end

  defp describe_data(%{"event" => "apology_offered", "from" => from, "to" => to} = data, names),
    do: "#{subject(names.(from))} #{names.(to)}에게 사과했다: #{data["reason"]}"

  defp describe_data(%{"event" => "comfort_offered", "from" => from, "to" => to}, names),
    do: "#{subject(names.(from))} #{with_particle(names.(to), :object)} 위로해 줬다."

  defp describe_data(%{"event" => "time_spent_together", "from" => from, "to" => to}, names),
    do: "#{with_particle(names.(from), :with)} #{with_particle(names.(to), :subject)} 함께 시간을 보냈다."

  defp describe_data(_data, _names), do: nil

  defp seen_by(%{observed_by: [_ | _] = observers}, name),
    do: " (#{Enum.map_join(observers, ", ", name)} 목격)"

  defp seen_by(_event, _name), do: ""

  defp subject("너"), do: "네가"
  defp subject(name), do: with_particle(name, :subject)

  defp ko_tone(:warm), do: "다정하게"
  defp ko_tone(:neutral), do: "담담하게"
  defp ko_tone(:cold), do: "차갑게"
  defp ko_tone(:hostile), do: "모질게"
  defp ko_tone(other), do: to_string(other)

  @doc """
  Appends the Korean particle that fits `word`'s final sound. `kind` is
  `:subject` (이/가), `:topic` (은/는), `:object` (을/를), `:and` (이랑/랑),
  or `:with` (과/와).
  """
  @spec with_particle(String.t(), :subject | :topic | :object | :and | :with) :: String.t()
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

  defp batchim?(word) do
    # Compose first (macOS and some inputs use decomposed Hangul), then read the
    # last letter, skipping trailing emoji, punctuation, and variation selectors.
    word
    |> :unicode.characters_to_nfc_binary()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.find_value(false, fn codepoint ->
      cond do
        # Hangul syllables: a final consonant exists when (code - 0xAC00) % 28 != 0.
        codepoint in 0xAC00..0xD7A3 ->
          {:ok, rem(codepoint - 0xAC00, 28) != 0}

        codepoint in ?a..?z or codepoint in ?A..?Z ->
          {:ok, latin_batchim?(word)}

        # Digits as read in Korean: 영, 일, 삼, 육, 칠, 팔 end in a consonant.
        codepoint in ?0..?9 ->
          {:ok, codepoint in ~c"013678"}

        true ->
          nil
      end
    end)
    |> case do
      {:ok, batchim?} -> batchim?
      false -> false
    end
  end

  defp name(_request, "user"), do: "너"
  defp name(request, id), do: Map.get(request.names, id, id)
end
