defmodule Aethrion.Step do
  @moduledoc """
  The full result of dispatching one host event.

  - `state` - the state after the event and all follow-ups
  - `event` - the host event, with its assigned `:id`
  - `events` - every processed event in order: the host event first, then
    follow-ups with `:cause` pointing at the event that produced them
  - `outputs` - structured outputs, in order
  - `log` - human-readable lines, in order
  - `trace` - `Aethrion.Trace` entries explaining every change
  """

  @type t :: %__MODULE__{
          state: Aethrion.State.t(),
          event: map(),
          events: [map()],
          outputs: [map()],
          log: [String.t()],
          trace: [Aethrion.Trace.t()]
        }

  defstruct [:state, :event, events: [], outputs: [], log: [], trace: []]
end
