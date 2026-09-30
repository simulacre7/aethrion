defmodule Aethrion.Error do
  @moduledoc """
  Structured error returned by every public API.

  `code` says what went wrong; `details` says where and with what. Location
  keys used across the library:

  - `:index` - position of the event in a list (0-based)
  - `:branch` - scenario branch name
  - `:line` - journal line (1-based, like editors)
  - `:path` - position inside a JSON document, as a list of keys and indexes
  - `:field` - event or option field

  | code | meaning |
  | --- | --- |
  | `:invalid_state` | the state, or state data being loaded, is malformed |
  | `:invalid_event` | an event field is missing or has the wrong type or value |
  | `:unknown_character` | an id does not name a character in the world |
  | `:unavailable_character` | an inactive or blocked character cannot take part |
  | `:unsupported_event` | no rules are registered for the event type |
  | `:rule_failed` | a rule raised inside a runtime server; the event was rejected |
  | `:invalid_tuning` | a tuning override names an unknown rule or parameter, or a non-integer |
  | `:invalid_scenario` | a scenario file is malformed |
  | `:invalid_journal` | a journal file is malformed |
  | `:journal_mismatch` | replaying a journal assigned a different event id than recorded |
  | `:journal_failed` | a runtime server could not append to its journal |
  | `:journal_enabled` | `put_state/2` was called on a journaling runtime server |
  | `:invalid_snapshot` | a saved snapshot exists but cannot be loaded |
  | `:invalid_options` | required options are missing or conflict |
  | `:already_exists` | a file that must be new already exists |
  | `:not_found` | a file or saved state does not exist |
  | `:io_error` | reading or writing a file failed |
  """

  @type t :: %__MODULE__{code: atom(), message: String.t(), details: map()}

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @doc "Builds an error."
  @spec new(atom(), String.t(), map()) :: t()
  def new(code, message, details \\ %{}) when is_atom(code) and is_binary(message) do
    %__MODULE__{code: code, message: message, details: details}
  end

  @doc "Merges location or context into an error's details."
  @spec add_details(t(), map()) :: t()
  def add_details(%__MODULE__{} = error, details) when is_map(details) do
    %{error | details: Map.merge(error.details, details)}
  end
end
