defmodule Aethrion.Output do
  @moduledoc """
  Structured runtime outputs. Applications decide how to perform side effects.

  Every output emitted by the runtime also carries `:event_id` (the event that
  caused it) and `:rule` (the rule that produced it).

  Expressive outputs (`:proactive_message`, `:reply`, `:character_interaction`)
  all name the speaking character `:character_id` and the other party `:to`,
  and carry deterministic fallback `:text` plus a `:context` snapshot
  (`Aethrion.Expression.Request`). An LLM adapter can re-render the text from
  that snapshot alone, without access to the live state.
  """

  @expressive [:proactive_message, :reply, :character_interaction]

  @doc "Output types that carry text an expression adapter may render."
  def expressive_types, do: @expressive

  @doc "Returns true for outputs that carry renderable text."
  @spec expressive?(map()) :: boolean()
  def expressive?(%{type: type}), do: type in @expressive
  def expressive?(_output), do: false

  @doc "A relationship field changed by `delta` (the applied amount, after clamping)."
  @spec relationship_changed(String.t(), String.t(), map()) :: map()
  def relationship_changed(from, to, delta) do
    %{type: :relationship_changed, from: from, to: to, delta: delta}
  end

  @doc "A memory was stored."
  @spec memory_created(Aethrion.Memory.t()) :: map()
  def memory_created(memory) do
    %{type: :memory_created, memory: memory}
  end

  @doc "A character's derived mood changed from `before` to `after`."
  @spec mood_changed(String.t(), atom(), atom()) :: map()
  def mood_changed(character_id, before_mood, after_mood) do
    %{type: :mood_changed, character_id: character_id, before: before_mood, after: after_mood}
  end

  @doc """
  The bond from `from` toward `to` changed (see `Aethrion.Rules.Bond`), for
  example from `:friendly` to `:close`.
  """
  @spec bond_changed(String.t(), String.t(), atom(), atom()) :: map()
  def bond_changed(from, to, before_bond, after_bond) do
    %{type: :bond_changed, from: from, to: to, before: before_bond, after: after_bond}
  end

  @doc """
  A character reached out on their own. `reason` is `:jealous`, `:lonely`,
  `:curious`, or `:protective`.
  """
  @spec proactive_message(String.t(), String.t(), atom(), String.t(), keyword()) :: map()
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

  @doc "A character answered someone who talked to them."
  @spec reply(String.t(), String.t(), atom(), String.t(), keyword()) :: map()
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
  Two characters interacted without the user: `character_id` started it and
  `to` took part. `kind` is `:gossip`, `:comfort`, or `:together`. `text` is
  narration a host can show as a scene.
  """
  @spec character_interaction(atom(), String.t(), String.t(), String.t(), keyword()) :: map()
  def character_interaction(kind, character_id, to, text, opts \\ []) do
    %{
      type: :character_interaction,
      kind: kind,
      character_id: character_id,
      to: to,
      text: text,
      memory_refs: Keyword.get(opts, :memory_refs, []),
      context: Keyword.get(opts, :context)
    }
  end
end
