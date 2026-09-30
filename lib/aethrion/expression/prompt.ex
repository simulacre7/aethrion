defmodule Aethrion.Expression.Prompt do
  @moduledoc """
  Provider-neutral prompts built from read-only request snapshots.

  Prompts ask the model to *phrase* a decision the runtime already made. They
  pass the deterministic draft line, the speaker's profile and mood, and the
  selected memories, and they forbid inventing facts or new events. Whatever
  the model returns is still only text: it cannot change state.
  """

  alias Aethrion.Expression.Request
  alias Aethrion.Intent

  @render_rules """
  You write one short line of dialogue or narration for a character in a persistent social simulation.
  The simulation has already decided what happens. Your job is only to phrase it.

  Rules:
  - Keep the meaning of the draft line. Do not add events, promises, gifts, or facts that are not in the context.
  - Only reference memories listed in the context. Memory contents use ids; call people by the names listed under People.
  - Memory kinds: experienced happened to the speaker; observed the speaker saw; heard someone told the speaker (secondhand, may be partial); impression is a lasting pattern from many faded memories, and a reputation impression is what the speaker knows about how someone treats others.
  - Stay in character: follow the profile, traits, and current mood.
  - Speak directly to the listener when the kind is proactive_message or reply.
  - For character_interaction, write one sentence of third-person narration.
  - At most two sentences. No quotation marks, no stage directions, no emoji.
  - Reply with the line only.
  """

  @intent_rules """
  You classify a message a user sent to a character in a social simulation.
  Reply with a single JSON object and nothing else.

  Schema: {"intent": "message" | "apology", "tone": "warm" | "neutral" | "cold" | "hostile"}

  - "apology" when the user is apologizing to the character.
  - Otherwise "message" with the tone the character would reasonably perceive.
  """

  @doc "Chat messages (`[%{role, content}]`) for rendering a request."
  def render_messages(%Request{} = request) do
    [
      %{role: "system", content: String.trim(@render_rules)},
      %{role: "user", content: render_context(request)}
    ]
  end

  @doc "System prompt and user content for rendering, for providers with a separate system field."
  def render_parts(%Request{} = request) do
    {String.trim(@render_rules), render_context(request)}
  end

  @doc "Chat messages for interpreting free text into a structured intent."
  def intent_messages(%Intent.Request{} = request) do
    [
      %{role: "system", content: String.trim(@intent_rules)},
      %{role: "user", content: intent_context(request)}
    ]
  end

  @doc "System prompt and user content for intent interpretation."
  def intent_parts(%Intent.Request{} = request) do
    {String.trim(@intent_rules), intent_context(request)}
  end

  @doc false
  def render_context(%Request{} = request) do
    [
      "Kind: #{request.kind}",
      "Reason: #{request.reason}",
      "Speaker: #{describe_actor(request.speaker)}",
      "Listener: #{describe_actor(request.listener)}",
      relationship_line(request.relationship),
      incoming_line(request),
      people_line(request),
      "Memories:",
      memory_lines(request),
      "Draft line: #{request.fallback_text}"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc false
  def intent_context(%Intent.Request{} = request) do
    """
    Character: #{request.listener.name} (#{request.listener.profile})
    Message from #{request.from}: #{request.text}
    """
    |> String.trim()
  end

  @doc """
  Extracts the first JSON object from a model reply, tolerating code fences
  and surrounding prose.
  """
  def decode_json_object(text) when is_binary(text) do
    with [json] <- Regex.run(~r/\{.*\}/s, text),
         {:ok, %{} = decoded} <- Jason.decode(json) do
      {:ok, decoded}
    else
      _ -> {:error, {:invalid_json, text}}
    end
  end

  @doc """
  Cleans a rendered line: trims whitespace and wrapping quotes.
  """
  def clean_line(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("“")
    |> String.trim("”")
    |> String.trim()
  end

  defp describe_actor(%{name: name} = actor) do
    details =
      [
        actor[:profile] && String.trim_trailing(actor.profile, "."),
        traits(actor[:traits]),
        actor[:mood] && "mood: #{actor.mood}"
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case details do
      [] -> name
      details -> "#{name} (#{Enum.join(details, "; ")})"
    end
  end

  defp traits([_ | _] = traits), do: "traits: " <> Enum.map_join(traits, ", ", &to_string/1)
  defp traits(_traits), do: nil

  defp relationship_line(%{affinity: affinity, trust: trust, tension: tension} = relationship) do
    bond = if relationship[:bond], do: "#{relationship.bond}; ", else: ""

    "Speaker toward listener: #{bond}affinity #{affinity}, trust #{trust}, tension #{tension} (scale -100..100)"
  end

  defp relationship_line(_relationship), do: nil

  defp incoming_line(%Request{message: message, tone: tone} = request) when is_binary(message) do
    away =
      case request.since_contact do
        nil -> " (their first conversation)"
        hours when hours >= 24 -> " (after #{hours} hours without talking)"
        _hours -> ""
      end

    "Listener just said (#{tone})#{away}: #{message}"
  end

  defp incoming_line(_request), do: nil

  defp people_line(%Request{names: names}) when map_size(names) > 0 do
    "People: " <>
      (names |> Enum.sort() |> Enum.map_join(", ", fn {id, name} -> "#{id} = #{name}" end))
  end

  defp people_line(_request), do: nil

  defp memory_lines(%Request{memories: []}), do: "- (none)"

  defp memory_lines(%Request{memories: memories}) do
    Enum.map(memories, fn memory ->
      source = if memory.source, do: ", heard from #{memory.source}", else: ""
      "- #{memory.content} (#{memory.kind}#{source}, importance #{memory.importance})"
    end)
  end
end
