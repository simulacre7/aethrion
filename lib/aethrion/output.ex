defmodule Aethrion.Output do
  @moduledoc """
  Structured runtime outputs. Applications decide how to perform side effects.

  Every output emitted by the runtime also carries `:event_id` (the event that
  caused it) and `:rule` (the rule that produced it).

  Expressive outputs (`:proactive_message`, `:reply`, `:character_interaction`)
  carry deterministic fallback `:text` plus a `:context` snapshot
  (`Aethrion.Expression.Request`). An LLM adapter can re-render the text from
  that snapshot alone, without access to the live state.
  """

  @expressive [:proactive_message, :reply, :character_interaction]

  @doc "Output types that carry text an expression adapter may render."
  def expressive_types, do: @expressive

  @doc "Returns true for outputs that carry renderable text."
  def expressive?(%{type: type}), do: type in @expressive
  def expressive?(_output), do: false

  def relationship_changed(from, to, delta) do
    %{type: :relationship_changed, from: from, to: to, delta: delta}
  end

  def memory_created(memory) do
    %{type: :memory_created, memory: memory}
  end

  def mood_changed(character_id, from, to) do
    %{type: :mood_changed, character_id: character_id, from: from, to: to}
  end

  def proactive_message(character_id, to, reason, text, opts \\ []) do
    %{
      type: :proactive_message,
      character_id: character_id,
      to: to,
      reason: reason,
      text: text,
      memory_refs: Keyword.get(opts, :memory_refs, []),
      context: Keyword.get(opts, :context)
    }
  end

  def reply(character_id, to, tone, text, opts \\ []) do
    %{
      type: :reply,
      character_id: character_id,
      to: to,
      tone: tone,
      text: text,
      memory_refs: Keyword.get(opts, :memory_refs, []),
      context: Keyword.get(opts, :context)
    }
  end

  @doc """
  Two actors interacted without the user. `kind` is `:gossip` or `:comfort`.
  `text` is narration a host can show as a scene.
  """
  def character_interaction(kind, from, to, text, opts \\ []) do
    %{
      type: :character_interaction,
      kind: kind,
      from: from,
      to: to,
      text: text,
      memory_refs: Keyword.get(opts, :memory_refs, []),
      context: Keyword.get(opts, :context)
    }
  end
end
