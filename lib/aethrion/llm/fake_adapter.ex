defmodule Aethrion.LLM.FakeAdapter do
  @moduledoc """
  Deterministic adapter used by tests, demos, and as the default.

  `render/2` returns the request's deterministic template text, or the Korean
  template with `locale: :ko` (see `Aethrion.Expression.Templates.Ko`).
  `interpret/2` uses a small keyword lexicon in English and Korean. Neither
  reads nor mutates runtime state.
  """

  @behaviour Aethrion.LLM.Adapter

  alias Aethrion.Expression.{Request, Templates}

  # Korean words are stems ("고마" covers 고마워, 고마웠어) and match anywhere,
  # since endings attach to them without a space.
  @apology ["sorry", "apologize", "apologise", "forgive me", "my bad"] ++
             [
               "미안",
               "죄송",
               "잘못했",
               "용서해 줘",
               "용서해줘",
               "용서해 줄래",
               "용서해줄래",
               "용서해 줄 수",
               "사과할게",
               "사과할께",
               "내 잘못"
             ]
  # Blaming the other person ("네가 잘못했잖아") and 미안한데 as a softener are
  # not apologies in themselves, and forgiving ("용서해 줄게") is not one either.
  @not_apology ~r/(?:네가|니가|너가|너)\s*잘못|미안한데/u
  @forgiving ~r/용서해\s*줄(?:게|께)/u
  @hostile [
             "hate",
             "stupid",
             "shut up",
             "annoying",
             "go away",
             "leave me alone",
             "idiot",
             "ruin",
             "useless",
             "pathetic",
             "worthless",
             "stop it"
           ] ++
             ["꺼져", "닥쳐", "바보", "멍청", "한심", "질렸", "재수 없", "재수없", "지긋지긋"] ++
             ["연락하지 마", "상종", "역겨", "저리 가", "입 다물", "이기적", "그 모양"] ++
             ["짐짝", "쓸모없", "쓸모 없", "쓰레기", "죽어", "방해만", "꼴 보기 싫", "꼴보기 싫"] ++
             ["재능 없", "재능도 없", "그만둬", "때려치", "그것밖에", "그거밖에"]
  # "그만해", but not "걱정 그만해" or "그만해도 돼".
  @stop ~r/(?<!걱정 )그만해(?!도)/u
  # Harsh only when aimed at the listener: "너 싫어", not "비 와서 싫어".
  @hostile_at_you ["싫어", "최악", "미워", "짜증", "재미없", "재미 없"]
  # Denied insults are not insults: "너 바보 아니야".
  @hostile_denied ~r/(?:바보|멍청|한심|이기적|싫|미워|최악)\S*\s*(?:아니|아냐|안\s)/u
  @you ~r/(?:^|\s)(?:너(?![무희])|넌|널|니(?=\s)|네가|니가|너가|당신)/u
  @warm [
    "thank",
    "love",
    "miss you",
    "miss talking",
    "miss our",
    "glad",
    "happy",
    "beautiful",
    "care about",
    "proud",
    "great",
    "amazing",
    "sweet",
    "missed you",
    "favorite",
    "favourite",
    "고마",
    "고맙",
    "ㄱㅅ",
    "ㄳ",
    "감사",
    "사랑",
    "보고 싶",
    "보고싶",
    "좋아",
    "좋다",
    "좋네",
    "좋았",
    "최고",
    "대단",
    "멋지",
    "멋져",
    "멋있",
    "반가",
    "수고했",
    "수고 많",
    "고생했",
    "고생 많",
    "잘 자",
    "조심히",
    "도와줄게",
    "축하",
    "힘내",
    "자랑스러",
    "행복",
    "예쁘",
    "예뻐",
    "좋은",
    "재밌",
    "재미있",
    "내 편",
    "잘 잤",
    "잘 지냈",
    "덕분에",
    "잘 될 거",
    "잘될 거",
    "푹 쉬어",
    "무리하지 마",
    "걱정돼",
    "걱정 돼",
    "대박",
    "멋졌",
    "지켜줄게",
    "지켜 줄게"
  ]
  # Disappointment is cold even next to a warm word ("대단히 실망했어"), and so
  # is brushing something off ("사랑 따위 필요 없어").
  @letdown ["disappointed", "let me down", "thanks for nothing", "no thanks"] ++
             ["실망", "서운", "따위", "필요 없어"]
  # A warm word or an apology right after a negation is cold ("not happy", "하나도 안 고마워"),
  # except in idioms that stay warm.
  # Korean negations stand on their own: "안 " after a space ("하나도 안 고마워"),
  # not inside a word ("그동안", "오랫동안"); "하나도" only before 안/못
  # (it is also a name).
  @negation_before ~r/(?:\bnot|\bnever|n't|\bno longer|(?:^|\s)(?:안|못|전혀))\s+(?:(?:really|even|that|so|very|too|전혀|별로)\s+)?$/u
  # Korean also negates after the word: "보고 싶지 않아", "좋아하는 척하지 마".
  @negated_after ~r/(?:고맙|고마|좋|보고\s*싶|사랑|반가)\S*\s*(?:지(?:는|도)?\s*않|지\s*마|척)/u
  @warm_idioms ["can't thank", "cannot thank", "couldn't be happier", "never been happier"] ++
                 ["괜찮아?", "괜찮니?", "괜찮은 거야?"]
  # Brush-offs as phrases: "busy" or "later" alone are ordinary ("see you
  # later!", "are you busy tonight?").
  @cold [
          "whatever",
          "don't care",
          "not now",
          "maybe later",
          "talk later",
          "i'm busy",
          "i am busy",
          "too busy"
        ] ++
          ["됐어", "됐거든", "나중에 얘기", "나중에 해", "바빠", "상관없", "상관하지 마", "알아서 해", "귀찮"] ++
          ["답답", "느려"]
  # "몰라" on its own, not "잘 몰라서 그러는데".
  @dont_know ~r/몰라(?!서)|나중에[\s.!?~]*$/u

  @impl true
  def render(%Request{} = request, opts \\ []) do
    case Keyword.get(opts, :locale, :en) do
      :ko -> {:ok, Templates.Ko.render(request)}
      _en -> {:ok, request.fallback_text || Templates.render(request)}
    end
  end

  @impl true
  def interpret(%Aethrion.Intent.Request{text: text}, _opts \\ []) do
    text = String.downcase(text)

    proposal =
      cond do
        negated_apology?(text) -> %{intent: :message, tone: :cold}
        apology?(text) -> %{intent: :apology}
        hostile?(text) -> %{intent: :message, tone: :hostile}
        mentions?(text, @letdown) -> %{intent: :message, tone: :cold}
        mentions?(text, @warm_idioms) -> %{intent: :message, tone: :warm}
        negated?(text, @warm) -> %{intent: :message, tone: :cold}
        mentions?(text, @warm) -> %{intent: :message, tone: :warm}
        cold?(text) -> %{intent: :message, tone: :cold}
        true -> %{intent: :message, tone: :neutral}
      end

    {:ok, proposal}
  end

  @doc """
  Backwards-compatible helper from v0.1: the stable line for a proactive reason
  with no memory context.
  """
  def proactive_message(character_id, reason) do
    Templates.render(%Request{
      kind: :proactive_message,
      reason: reason,
      speaker: %{id: character_id, name: character_id, traits: [], mood: :neutral},
      listener: %{id: "user", name: "you"}
    })
  end

  # What is left once blame and softeners are set aside must still apologize:
  # "너 잘못 대해서 미안해" and "미안한데, 내가 잘못했어" do.
  defp apology?(text) do
    not Regex.match?(@forgiving, text) and
      mentions?(String.replace(text, @not_apology, ""), @apology)
  end

  # Harsh words count unless they are negated or denied: "I don't hate you",
  # "don't go away", "너 안 싫어", "너 바보 아니야".
  defp hostile?(text) do
    insult? =
      mentions?(text, @hostile) or Regex.match?(@stop, text) or
        (mentions?(text, @hostile_at_you) and Regex.match?(@you, text))

    insult? and not negated_before?(text, @hostile ++ @hostile_at_you) and
      not Regex.match?(@hostile_denied, text) and not teasing?(text)
  end

  # A mild word with a laugh is teasing: "바보야 ㅋㅋ", "you idiot lol".
  @mild ["바보", "멍청", "idiot"]
  @laugh ~r/[ㅋㅎ]{2,}|\blol\b|\bhaha/u

  defp teasing?(text) do
    Regex.match?(@laugh, text) and mentions?(text, @mild) and
      not mentions?(text, @hostile -- @mild) and not Regex.match?(@stop, text)
  end

  defp cold?(text), do: mentions?(text, @cold) or Regex.match?(@dont_know, text)

  # A negation attached to the apology itself ("not sorry", "I won't
  # apologize", "안 미안해", "미안하지 않아"); "못 가서 미안해" or "I couldn't
  # call, sorry" are still apologies.
  defp negated_apology?(text) do
    Regex.match?(
      ~r/(?:\bnot|\bnever|n't)\s+(?:\w+\s+){0,2}(?:sorry|apologi[sz]e|forgive)/u,
      text
    ) or
      Regex.match?(~r/(?:^|\s)(?:안|전혀|하나도)\s+(?:안\s+)?(?:미안|죄송)/u, text) or
      Regex.match?(~r/(?:미안|죄송)\S*지\s*않/u, text) or
      Regex.match?(~r/미안\s*안|미안하긴|왜\s*미안|미안해할\s*거\s*없|사과할\s*생각\s*없/u, text) or
      Regex.match?(~r/잘못\S*\s*(?:이\s*)?(?:아니|아냐)/u, text)
  end

  # A negation within the few characters before a warm word, or a Korean one
  # after it.
  defp negated?(text, words) do
    Regex.match?(@negated_after, text) or negated_before?(text, words)
  end

  defp negated_before?(text, words) do
    Enum.any?(words, fn word ->
      ~r/(?<![a-z])#{Regex.escape(word)}/u
      |> Regex.scan(text, return: :index)
      |> Enum.any?(fn [{start, _length}] ->
        # The negation must directly precede the word, within its clause.
        clause = text |> binary_part(0, start) |> String.split(~r/[.,!?~]/u) |> List.last()
        Regex.match?(@negation_before, clause)
      end)
    end)
  end

  # Matches at word starts so "thanks" matches "thank" but "whatever" does not match "hate".
  defp mentions?(text, words) do
    Enum.any?(words, &Regex.match?(~r/(?<![a-z])#{Regex.escape(&1)}/u, text))
  end
end
