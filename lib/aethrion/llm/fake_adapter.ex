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
             ["미안", "죄송", "잘못했", "용서해"]
  @hostile ["hate", "stupid", "shut up", "annoying", "go away", "leave me alone", "idiot"] ++
             ["꺼져", "닥쳐", "짜증", "싫어", "바보", "멍청", "최악", "너 때문에"]
  @warm [
    "thank",
    "love",
    "miss you",
    "glad",
    "happy",
    "beautiful",
    "care about",
    "proud",
    "great",
    "amazing",
    "sweet",
    "고마",
    "감사",
    "사랑",
    "보고 싶",
    "좋아",
    "최고",
    "대단",
    "멋지",
    "자랑스러",
    "행복"
  ]
  @cold ["whatever", "busy", "later", "don't care", "not now"] ++
          ["됐어", "나중에", "바빠", "몰라", "상관없", "알아서 해"]

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
        mentions?(text, @apology) -> %{intent: :apology}
        mentions?(text, @hostile) -> %{intent: :message, tone: :hostile}
        mentions?(text, @warm) -> %{intent: :message, tone: :warm}
        mentions?(text, @cold) -> %{intent: :message, tone: :cold}
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

  # Matches at word starts so "thanks" matches "thank" but "whatever" does not match "hate".
  defp mentions?(text, words) do
    Enum.any?(words, &Regex.match?(~r/(?<![a-z])#{Regex.escape(&1)}/u, text))
  end
end
