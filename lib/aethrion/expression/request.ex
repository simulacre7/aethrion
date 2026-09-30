defmodule Aethrion.Expression.Request do
  @moduledoc """
  Read-only snapshot handed to an expression adapter.

  A request contains everything an adapter may use to phrase an output and
  nothing it could use to change the world: plain data copied out of the state
  at the moment the output was produced. Adapters return text; they never
  receive `Aethrion.State`.

  - `kind` - `:proactive_message`, `:reply`, or `:character_interaction`
  - `reason` - why the output exists (`:jealous`, `:lonely`, `:curious`,
    `:protective`, `:reply`, `:reassurance` (a reply to a gift from someone
    the speaker felt left out by), `:gossip`, `:comfort`, `:together`)
  - `speaker` / `listener` - `%{id, name, profile, traits, mood}` (listener
    fields other than id and name may be nil for external actors such as `user`)
  - `relationship` - speaker -> listener `%{affinity, trust, tension, bond}`
  - `memories` - the speaker's selected memories as plain maps
  - `names` - display names for every id referenced by the memories
  - `tone` - the incoming tone for replies
  - `message` - for replies, the incoming text (the item for a gift, the
    reason for an apology)
  - `since_contact` - for replies and proactive messages, simulated hours
    since the listener last talked to the speaker, or `nil` if they never
    have; `reunion?/1` says whether that is a long absence
  - `repeats` - for replies, how many messages in this tone (or gifts, or
    apologies) from the listener the speaker still remembers, this one
    included (at least 1), so a reply can vary or escalate; for protective
    messages, how many characters (this one included) have spoken up about
    the same incident
  - `goodwill` - for replies to cold or hostile words, whether the rules gave
    the listener the benefit of the doubt (`Aethrion.Rules.Message`), or
    `nil` when not known
  - `now` - the simulated clock (hours) when the output was produced;
    `hours_ago/2` says how long ago a memory was formed
  - `sequence` - how many events the world had processed then, so lines can
    vary between several messages within one hour
  - `fallback_text` - the deterministic template text
  """

  @type t :: %__MODULE__{
          kind: atom(),
          reason: atom(),
          speaker: map(),
          listener: map(),
          relationship: map() | nil,
          memories: [map()],
          names: %{optional(String.t()) => String.t()},
          tone: atom() | nil,
          message: String.t() | nil,
          since_contact: non_neg_integer() | nil,
          repeats: pos_integer() | nil,
          goodwill: boolean() | nil,
          now: non_neg_integer() | nil,
          sequence: non_neg_integer() | nil,
          fallback_text: String.t() | nil
        }

  defstruct [
    :kind,
    :reason,
    :speaker,
    :listener,
    :relationship,
    memories: [],
    names: %{},
    tone: nil,
    message: nil,
    since_contact: nil,
    repeats: nil,
    goodwill: nil,
    now: nil,
    sequence: nil,
    fallback_text: nil
  ]

  @reunion_hours 72

  @doc "True when the listener is back after #{@reunion_hours} or more simulated hours."
  @spec reunion?(t()) :: boolean()
  def reunion?(%__MODULE__{since_contact: hours}),
    do: is_integer(hours) and hours >= @reunion_hours

  @doc """
  Simulated hours since `memory` (one of the request's memories) was formed,
  or `nil` when the request or the memory does not say.
  """
  @spec hours_ago(t(), map()) :: non_neg_integer() | nil
  def hours_ago(%__MODULE__{now: now}, %{created_tick: tick})
      when is_integer(now) and is_integer(tick),
      do: max(now - tick, 0)

  def hours_ago(%__MODULE__{}, _memory), do: nil

  @doc """
  What the speaker knows about the listener being hostile to someone else,
  from the request's memories: `{:observed, target}` or `{:heard, target}`
  for a specific message, `:reputation` for a reputation impression (unless
  the speaker also holds a firsthand impression of the listener), or `nil`.
  A specific memory wins over the impression, and a remembered apology from
  the listener to that person made after it cancels it.
  """
  @spec harshness_to_others(t()) :: {:observed | :heard, String.t()} | :reputation | nil
  def harshness_to_others(
        %__MODULE__{speaker: %{id: speaker}, listener: %{id: listener}} = request
      ) do
    # When the listener last apologized to each person, as {tick, event}.
    apologies =
      for %{data: %{"event" => "apology_offered", "from" => ^listener, "to" => to}} = memory <-
            request.memories,
          reduce: %{} do
        acc -> Map.update(acc, to, moment(memory), &max(&1, moment(memory)))
      end

    specific =
      Enum.find_value(request.memories, fn
        %{kind: kind, data: %{"event" => "message_sent", "tone" => "hostile"} = data} = memory
        when kind in [:observed, :heard] ->
          if data["from"] == listener and data["to"] != speaker and
               not apologized_since?(apologies, data["to"], memory),
             do: {kind, data["to"]}

        _memory ->
          nil
      end)

    firsthand? =
      Enum.any?(
        request.memories,
        &match?(
          %{data: %{"event" => "impression", "from" => ^listener, "to" => ^speaker}},
          &1
        )
      )

    # A reputation for hostility, unless the speaker knows of an apology to
    # everyone it was about.
    reputation? =
      Enum.any?(request.memories, fn
        %{data: %{"event" => "reputation", "pattern" => "hostile", "from" => ^listener} = data} ->
          not Enum.all?(Map.get(data, "about", []), &Map.has_key?(apologies, &1))

        _memory ->
          false
      end)

    cond do
      specific -> specific
      reputation? and not firsthand? -> :reputation
      true -> nil
    end
  end

  defp apologized_since?(apologies, target, memory) do
    case Map.fetch(apologies, target) do
      {:ok, apology} -> apology >= moment(memory)
      :error -> false
    end
  end

  # When a remembered event happened: its tick, then its event number.
  # Event ids count up (e1, e2, ...) and every memory of one event shares its
  # topic, so the event number orders what happened even when one of the
  # memories was only heard later. Topics without one fall back to the tick.
  defp moment(memory) do
    case Aethrion.Memories.event_number(memory) do
      nil -> {:tick, Map.get(memory, :created_tick, 0)}
      number -> {:event, number}
    end
  end
end
