defmodule Aethrion.Explain do
  @moduledoc """
  Answers "why is this value what it is?" from traces.

  Given the trace and processed events of one or more steps, `character/4`
  and `relationship/5` return every change to a single value, in order, with
  the rule that made it and the chain of events that led there:

      events = [
        Aethrion.Event.gift_received("user", "mina", "flower", observed_by: ["yuna"]),
        Aethrion.Event.time_tick("t", hours: 2)
      ]

      {:ok, _state, steps} = Aethrion.run(Aethrion.demo_state(), events)

      steps
      |> Aethrion.Explain.character("yuna", :jealousy)
      |> Aethrion.Explain.describe()
      #=> ["jealousy 0 -> 15 by observation in e1: user gives mina a flower (seen by yuna)",
      #    "jealousy 15 -> 10 by comfort in e4: haru comforts yuna <- yuna confides in haru <- time passes +2h"]
  """

  alias Aethrion.{Event, Trace}

  @type change :: %{
          event_id: String.t(),
          rule: atom(),
          field: atom(),
          before: term(),
          after: term(),
          chain: [map()]
        }

  @doc """
  Changes to a character field across a list of `Aethrion.Step`s (as returned
  by `Aethrion.Runtime.run/3`), oldest first.
  """
  def character(steps, character_id, field) when is_list(steps) and is_atom(field) do
    {trace, events} = from_steps(steps)
    character(trace, events, character_id, field)
  end

  @doc """
  Changes to a relationship field across a list of `Aethrion.Step`s, oldest first.
  """
  def relationship(steps, from, to, field) when is_list(steps) and is_atom(field) do
    {trace, events} = from_steps(steps)
    relationship(trace, events, from, to, field)
  end

  defp from_steps(steps) do
    {Enum.flat_map(steps, & &1.trace), Enum.flat_map(steps, & &1.events)}
  end

  @doc """
  Changes to a character field (such as `:jealousy` or `:mood`), oldest first,
  from a trace and the events it refers to.
  """
  def character(trace, events, character_id, field) when is_atom(field) do
    trace
    |> Enum.filter(&match?(%Trace{kind: :character, target: ^character_id, field: ^field}, &1))
    |> changes(events)
  end

  @doc """
  Changes to a relationship field (`:affinity`, `:trust`, or `:tension`), oldest first.
  """
  def relationship(trace, events, from, to, field) when is_atom(field) do
    target = {from, to}

    trace
    |> Enum.filter(&match?(%Trace{kind: :relationship, target: ^target, field: ^field}, &1))
    |> changes(events)
  end

  @doc """
  One line per change. `names` maps ids to display names.
  """
  @spec describe([change()], (String.t() -> String.t())) :: [String.t()]
  def describe(changes, names \\ &Function.identity/1) do
    Enum.map(changes, fn change ->
      chain =
        case change.chain do
          [] -> ""
          chain -> ": " <> Enum.map_join(chain, " <- ", &Event.describe(&1, names))
        end

      "#{change.field} #{format(change.before)} -> #{format(change.after)} " <>
        "by #{change.rule} in #{change.event_id}#{chain}"
    end)
  end

  defp changes(entries, events) do
    by_id = Map.new(events, &{&1.id, &1})

    Enum.map(entries, fn entry ->
      %{
        event_id: entry.event_id,
        rule: entry.rule,
        field: entry.field,
        before: entry.before,
        after: entry.after,
        chain: chain(by_id, entry.event_id, [])
      }
    end)
  end

  # The event and every event that caused it, nearest first.
  defp chain(by_id, id, acc) do
    case Map.fetch(by_id, id) do
      {:ok, event} ->
        acc = acc ++ [event]

        case Map.get(event, :cause) do
          nil -> acc
          cause -> chain(by_id, cause, acc)
        end

      :error ->
        acc
    end
  end

  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(value), do: to_string(value)
end
