defmodule Aethrion.Event do
  @moduledoc """
  Event constructors and helpers.

  Events are plain maps with a `:type`. The runtime assigns every processed
  event an `:id` (`"e1"`, `"e2"`, ...) and records `:cause` when a rule derived
  the event from another one. Hosts never need to set either field.

  Built-in event types:

  | type               | who creates it          | meaning                                   |
  | ------------------ | ----------------------- | ----------------------------------------- |
  | `:gift_received`   | host                    | someone gives a character an item         |
  | `:message_sent`    | host                    | someone talks to a character with a tone  |
  | `:apology_offered` | host                    | someone apologizes to a character         |
  | `:time_tick`       | host / `Scheduler`      | simulated time passes                     |
  | `:gossip_shared`   | rules (or host)         | a character tells another about a memory  |
  | `:comfort_offered` | rules (or host)         | someone comforts a character              |
  """

  @tones [:warm, :neutral, :cold, :hostile]
  @types [
    :gift_received,
    :message_sent,
    :apology_offered,
    :time_tick,
    :gossip_shared,
    :comfort_offered
  ]

  @type t :: %{required(:type) => atom(), optional(atom()) => term()}

  @doc "Built-in event types."
  def types, do: @types

  @doc "Tones accepted by `message_sent/4`."
  def tones, do: @tones

  def gift_received(from, to, item, opts \\ []) do
    %{
      type: :gift_received,
      from: from,
      to: to,
      item: item,
      observed_by: Keyword.get(opts, :observed_by, []),
      at: Keyword.get(opts, :at, "demo:t0")
    }
  end

  def time_tick(now, opts \\ []) do
    %{type: :time_tick, now: now, hours: Keyword.get(opts, :hours, 1)}
  end

  def apology_offered(from, to, reason, opts \\ []) do
    %{
      type: :apology_offered,
      from: from,
      to: to,
      reason: reason,
      at: Keyword.get(opts, :at, "demo:t0")
    }
  end

  @doc """
  Someone sends a character a message.

  `tone` is the structured, authoritative interpretation of the message and must
  be one of `tones/0`. `text` is kept for memory and expression only; rules never
  parse it. Use `Aethrion.Intent` to propose a tone from free text.
  """
  def message_sent(from, to, text, opts \\ []) do
    %{
      type: :message_sent,
      from: from,
      to: to,
      text: text,
      tone: Keyword.get(opts, :tone, :neutral),
      at: Keyword.get(opts, :at, "demo:t0")
    }
  end

  @doc """
  Character `from` shares one of their memories with character `to`.
  """
  def gossip_shared(from, to, memory_id, opts \\ []) do
    %{
      type: :gossip_shared,
      from: from,
      to: to,
      memory_id: memory_id,
      at: Keyword.get(opts, :at, "demo:t0")
    }
  end

  @doc """
  `from` comforts character `to`.
  """
  def comfort_offered(from, to, opts \\ []) do
    %{
      type: :comfort_offered,
      from: from,
      to: to,
      at: Keyword.get(opts, :at, "demo:t0")
    }
  end

  @doc """
  Fills optional fields that hosts may omit when building event maps by hand:
  `:at` (and `:now` for ticks) default to `"unspecified"`, `:observed_by` to
  `[]`, and `:tone` to `:neutral`. Unknown types pass through unchanged.
  """
  def normalize(%{type: :time_tick} = event), do: Map.put_new(event, :now, "unspecified")

  def normalize(%{type: :gift_received} = event) do
    event |> Map.put_new(:at, "unspecified") |> Map.put_new(:observed_by, [])
  end

  def normalize(%{type: :message_sent} = event) do
    event |> Map.put_new(:at, "unspecified") |> Map.put_new(:tone, :neutral)
  end

  def normalize(%{type: type} = event) when type in @types,
    do: Map.put_new(event, :at, "unspecified")

  def normalize(event), do: event

  @doc """
  One-line human-readable description of an event.
  """
  def describe(event, names \\ &Function.identity/1)

  def describe(%{type: :gift_received} = event, names) do
    "#{names.(event.from)} gives #{names.(event.to)} a #{event.item}" <>
      observers_suffix(event, names)
  end

  def describe(%{type: :time_tick, hours: hours}, _names), do: "time passes +#{hours}h"

  def describe(%{type: :apology_offered} = event, names) do
    "#{names.(event.from)} apologizes to #{names.(event.to)}: #{event.reason}"
  end

  def describe(%{type: :message_sent} = event, names) do
    "#{names.(event.from)} -> #{names.(event.to)} (#{event.tone}): #{event.text}"
  end

  def describe(%{type: :gossip_shared} = event, names) do
    "#{names.(event.from)} confides in #{names.(event.to)}"
  end

  def describe(%{type: :comfort_offered} = event, names) do
    "#{names.(event.from)} comforts #{names.(event.to)}"
  end

  def describe(%{type: type}, _names), do: to_string(type)

  defp observers_suffix(%{observed_by: [_ | _] = observers}, names) do
    " (seen by #{Enum.map_join(observers, ", ", names)})"
  end

  defp observers_suffix(_event, _names), do: ""

  @doc """
  Converts an event into JSON-friendly data with string keys.
  """
  def to_data(%{type: type} = event) do
    event
    |> Enum.map(fn
      {:type, type} -> {"type", Atom.to_string(type)}
      {:tone, tone} -> {"tone", Atom.to_string(tone)}
      {key, value} -> {Atom.to_string(key), value}
    end)
    |> Map.new()
    |> Map.put("type", Atom.to_string(type))
  end

  @doc """
  Builds an event from JSON-style data. Only built-in event types and fields are
  accepted, so untrusted input cannot create atoms.
  """
  def from_data(%{"type" => type} = data) when is_binary(type) do
    case Enum.find(@types, &(Atom.to_string(&1) == type)) do
      nil -> {:error, {:unsupported_event, type}}
      type -> {:ok, build(type, data)}
    end
  end

  def from_data(data), do: {:error, {:invalid_event, data}}

  defp build(:gift_received, data) do
    gift_received(data["from"], data["to"], data["item"],
      observed_by: Map.get(data, "observed_by", []),
      at: Map.get(data, "at", "scenario")
    )
  end

  defp build(:time_tick, data) do
    time_tick(Map.get(data, "now", "scenario"), hours: Map.get(data, "hours", 1))
  end

  defp build(:apology_offered, data) do
    apology_offered(data["from"], data["to"], data["reason"], at: Map.get(data, "at", "scenario"))
  end

  defp build(:message_sent, data) do
    message_sent(data["from"], data["to"], data["text"],
      tone: tone_from_data(Map.get(data, "tone", "neutral")),
      at: Map.get(data, "at", "scenario")
    )
  end

  defp build(:gossip_shared, data) do
    gossip_shared(data["from"], data["to"], data["memory_id"],
      at: Map.get(data, "at", "scenario")
    )
  end

  defp build(:comfort_offered, data) do
    comfort_offered(data["from"], data["to"], at: Map.get(data, "at", "scenario"))
  end

  # Unknown tones stay strings so validation can reject them with a clear error.
  defp tone_from_data(tone) when is_binary(tone) do
    Enum.find(@tones, tone, &(Atom.to_string(&1) == tone))
  end

  defp tone_from_data(tone), do: tone
end
