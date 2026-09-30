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
end
