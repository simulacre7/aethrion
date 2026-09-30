defmodule Aethrion.Trace do
  @moduledoc """
  One explainable step inside a state transition.

  Every change a rule makes through `Aethrion.Transition` is recorded as a trace
  entry, so the runtime can answer "which rule changed this, in response to
  which event, from what value to what value?".

  Kinds:

  - `:character` - a character state field changed (`target` is the character id)
  - `:relationship` - a relationship field changed (`target` is `{from, to}`)
  - `:memory` - a memory was created or updated (`target` is the memory id)
  - `:output` - an output was emitted (`target` is the output type)
  - `:event` - a follow-up event was enqueued or dropped (`target` is the event type)
  - `:bond` - a relationship's derived bond changed (`target` is `{from, to}`,
    `field` is `:bond`); bonds are not stored, see `Aethrion.Rules.Bond`
  - `:note` - a rule decision without a direct state change

  `subject` is the character primarily affected, when there is one.
  """

  @type kind :: :character | :relationship | :bond | :memory | :output | :event | :note

  @type t :: %__MODULE__{
          event_id: String.t() | nil,
          rule: atom() | nil,
          kind: kind(),
          subject: String.t() | nil,
          target: term(),
          field: atom() | nil,
          before: term(),
          after: term(),
          detail: String.t() | nil
        }

  defstruct [:event_id, :rule, :kind, :subject, :target, :field, :before, :after, :detail]

  @doc """
  Returns true when the entry concerns `character_id`: as its subject, or as
  either side of a relationship change.
  """
  def concerns?(%__MODULE__{subject: id}, id) when is_binary(id), do: true

  def concerns?(%__MODULE__{kind: kind, target: {_, id}}, id) when kind in [:relationship, :bond],
    do: true

  def concerns?(%__MODULE__{}, _id), do: false

  @doc """
  One-line explanation of the entry.
  """
  def describe(%__MODULE__{} = entry) do
    prefix = "#{entry.event_id} #{entry.rule}"

    case entry do
      %{kind: :character, field: field, before: before, after: value} ->
        "#{prefix}: #{entry.target}.#{field} #{format(before)} -> #{format(value)}"

      %{kind: kind, target: {from, to}, field: field, before: before, after: value}
      when kind in [:relationship, :bond] ->
        "#{prefix}: #{from}->#{to}.#{field} #{before} -> #{value}"

      %{kind: :memory, field: field, before: before, after: value} when not is_nil(field) ->
        "#{prefix}: #{entry.target}.#{field} #{inspect(before)} -> #{inspect(value)}"

      %{detail: detail} when is_binary(detail) ->
        "#{prefix}: #{detail}"

      _ ->
        "#{prefix}: #{entry.kind} #{inspect(entry.target)}"
    end
  end

  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value), do: to_string(value)
end
