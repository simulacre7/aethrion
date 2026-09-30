defmodule Aethrion.LLM.FakeAdapter do
  @moduledoc """
  Deterministic adapter used by tests, demos, and as the default.

  `render/2` returns the request's deterministic template text, or the Korean
  template with `locale: :ko` (see `Aethrion.Expression.Templates.Ko`).
  `interpret/2` uses a small keyword lexicon. Neither reads nor mutates
  runtime state.
  """

  @behaviour Aethrion.LLM.Adapter

  alias Aethrion.Expression.{Request, Templates}

  @apology ["sorry", "apologize", "apologise", "forgive me", "my bad"]
  @hostile ["hate", "stupid", "shut up", "annoying", "go away", "leave me alone", "idiot"]
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
    "sweet"
  ]
  @cold ["whatever", "busy", "later", "don't care", "not now"]

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
