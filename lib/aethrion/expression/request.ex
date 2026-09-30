defmodule Aethrion.Expression.Request do
  @moduledoc """
  Read-only snapshot handed to an expression adapter.

  A request contains everything an adapter may use to phrase an output and
  nothing it could use to change the world: plain data copied out of the state
  at the moment the output was produced. Adapters return text; they never
  receive `Aethrion.State`.

  - `kind` - `:proactive_message`, `:reply`, or `:character_interaction`
  - `reason` - why the output exists (`:jealous`, `:lonely`, `:curious`,
    `:reply`, `:gossip`, `:comfort`)
  - `speaker` / `listener` - `%{id, name, profile, traits, mood}` (listener
    fields other than id and name may be nil for external actors such as `user`)
  - `relationship` - speaker -> listener `%{affinity, trust, tension}`
  - `memories` - the speaker's selected memories as plain maps
  - `names` - display names for every id referenced by the memories
  - `tone` - the incoming tone for replies
  - `message` - the incoming text for replies
  - `fallback_text` - the deterministic template text
  """

  @type t :: %__MODULE__{
          kind: atom(),
          reason: atom(),
          speaker: map(),
          listener: map(),
          relationship: map(),
          memories: [map()],
          names: %{optional(String.t()) => String.t()},
          tone: atom() | nil,
          message: String.t() | nil,
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
    fallback_text: nil
  ]

  @doc """
  What the speaker knows about the listener being hostile to someone else,
  from the request's memories: `{:observed, target}` or `{:heard, target}`
  for a specific message, `:reputation` for a reputation impression, or `nil`.
  A specific memory wins over the impression.
  """
  @spec harshness_to_others(t()) :: {:observed | :heard, String.t()} | :reputation | nil
  def harshness_to_others(
        %__MODULE__{speaker: %{id: speaker}, listener: %{id: listener}} = request
      ) do
    specific =
      Enum.find_value(request.memories, fn
        %{kind: kind, data: %{"event" => "message_sent", "tone" => "hostile"} = data}
        when kind in [:observed, :heard] ->
          if data["from"] == listener and data["to"] != speaker, do: {kind, data["to"]}

        _memory ->
          nil
      end)

    specific ||
      if Enum.any?(
           request.memories,
           &match?(
             %{data: %{"event" => "reputation", "pattern" => "hostile", "from" => ^listener}},
             &1
           )
         ),
         do: :reputation
  end
end
