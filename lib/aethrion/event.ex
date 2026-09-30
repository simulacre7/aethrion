defmodule Aethrion.Event do
  @moduledoc """
  Event constructors and helpers.

  `:at` (and `:now` for ticks) are free-form string labels for when something
  happened, such as `"day2 09:00"`. They default to `"unspecified"`; the
  simulated clock, not the label, is what rules use.

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
  | `:time_spent_together` | rules (or host)     | two characters spend time together        |
  """

  @tones [:warm, :neutral, :cold, :hostile]
  @unspecified "unspecified"
  @types [
    :gift_received,
    :message_sent,
    :apology_offered,
    :time_tick,
    :gossip_shared,
    :comfort_offered,
    :time_spent_together
  ]

  @type t :: %{required(:type) => atom(), optional(atom()) => term()}

  @doc "Built-in event types."
  def types, do: @types

  @doc "Tones accepted by `message_sent/4`."
  def tones, do: @tones

  @spec gift_received(String.t(), String.t(), String.t(), keyword()) :: t()
  def gift_received(from, to, item, opts \\ []) do
    %{
      type: :gift_received,
      from: from,
      to: to,
      item: item,
      observed_by: Keyword.get(opts, :observed_by, []),
      at: Keyword.get(opts, :at, @unspecified)
    }
  end

  @spec time_tick(String.t(), keyword()) :: t()
  def time_tick(now, opts \\ []) do
    %{type: :time_tick, now: now, hours: Keyword.get(opts, :hours, 1)}
  end

  @spec apology_offered(String.t(), String.t(), String.t(), keyword()) :: t()
  def apology_offered(from, to, reason, opts \\ []) do
    %{
      type: :apology_offered,
      from: from,
      to: to,
      reason: reason,
      observed_by: Keyword.get(opts, :observed_by, []),
      at: Keyword.get(opts, :at, @unspecified)
    }
  end

  @doc """
  Someone sends a character a message.

  `tone` is the structured, authoritative interpretation of the message and must
  be one of `tones/0`. `text` is kept for memory and expression only; rules never
  parse it. Use `Aethrion.Intent` to propose a tone from free text.

  Characters in `:observed_by` witness the message and remember how the sender
  treated the receiver (see `Aethrion.Rules.Reputation`).
  """
  @spec message_sent(String.t(), String.t(), String.t(), keyword()) :: t()
  def message_sent(from, to, text, opts \\ []) do
    %{
      type: :message_sent,
      from: from,
      to: to,
      text: text,
      tone: Keyword.get(opts, :tone, :neutral),
      observed_by: Keyword.get(opts, :observed_by, []),
      at: Keyword.get(opts, :at, @unspecified)
    }
  end

  @doc """
  Character `from` shares one of their memories with character `to`.
  """
  @spec gossip_shared(String.t(), String.t(), String.t(), keyword()) :: t()
  def gossip_shared(from, to, memory_id, opts \\ []) do
    %{
      type: :gossip_shared,
      from: from,
      to: to,
      memory_id: memory_id,
      at: Keyword.get(opts, :at, @unspecified)
    }
  end

  @doc """
  `from` comforts character `to`.
  """
  @spec comfort_offered(String.t(), String.t(), keyword()) :: t()
  def comfort_offered(from, to, opts \\ []) do
    %{
      type: :comfort_offered,
      from: from,
      to: to,
      at: Keyword.get(opts, :at, @unspecified)
    }
  end

  @doc """
  Characters `from` and `to` spend time together.
  """
  @spec time_spent_together(String.t(), String.t(), keyword()) :: t()
  def time_spent_together(from, to, opts \\ []) do
    %{type: :time_spent_together, from: from, to: to, at: Keyword.get(opts, :at, @unspecified)}
  end

  @doc """
  Fills optional fields that hosts may omit when building event maps by hand:
  `:at` (and `:now` for ticks) default to `"unspecified"`, `:observed_by` to
  `[]`, and `:tone` to `:neutral`. Unknown types pass through unchanged.
  """
  def normalize(%{type: :time_tick} = event), do: Map.put_new(event, :now, @unspecified)

  def normalize(%{type: :gift_received} = event) do
    event |> Map.put_new(:at, @unspecified) |> Map.put_new(:observed_by, [])
  end

  def normalize(%{type: :apology_offered} = event) do
    event |> Map.put_new(:at, @unspecified) |> Map.put_new(:observed_by, [])
  end

  def normalize(%{type: :message_sent} = event) do
    event
    |> Map.put_new(:at, @unspecified)
    |> Map.put_new(:tone, :neutral)
    |> Map.put_new(:observed_by, [])
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
    "#{names.(event.from)} apologizes to #{names.(event.to)}: #{event.reason}" <>
      observers_suffix(event, names)
  end

  def describe(%{type: :message_sent} = event, names) do
    "#{names.(event.from)} -> #{names.(event.to)} (#{event.tone}): #{event.text}" <>
      observers_suffix(event, names)
  end

  def describe(%{type: :gossip_shared} = event, names) do
    "#{names.(event.from)} confides in #{names.(event.to)}"
  end

  def describe(%{type: :comfort_offered} = event, names) do
    "#{names.(event.from)} comforts #{names.(event.to)}"
  end

  def describe(%{type: :time_spent_together} = event, names) do
    "#{names.(event.from)} spends time with #{names.(event.to)}"
  end

  def describe(%{type: type}, _names), do: to_string(type)

  defp observers_suffix(%{observed_by: [_ | _] = observers}, names) do
    " (seen by #{Enum.map_join(observers, ", ", names)})"
  end

  defp observers_suffix(_event, _names), do: ""

  @doc """
  Converts an event into JSON-friendly data with string keys.
  """
  @spec to_data(t()) :: map()
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
  Builds an event from JSON-style data. Untrusted input cannot create atoms.

  Built-in types are built with their constructors. With `pipeline:`, custom
  event types registered in that pipeline are accepted too: their fields become
  atom keys only when that atom already exists (as it does for any field a rule
  reads), and other fields are dropped. The `"id"` field is ignored.
  """
  @spec from_data(term(), keyword()) :: {:ok, t()} | {:error, Aethrion.Error.t()}
  def from_data(data, opts \\ [])

  def from_data(%{"type" => type} = data, opts) when is_binary(type) do
    case Enum.find(@types, &(Atom.to_string(&1) == type)) do
      nil -> custom_from_data(type, data, Keyword.get(opts, :pipeline))
      type -> {:ok, build(type, data)}
    end
  end

  def from_data(data, _opts) do
    {:error,
     Aethrion.Error.new(:invalid_event, "event must be an object with a string \"type\"", %{
       event: data
     })}
  end

  defp custom_from_data(type, _data, nil), do: unsupported(type)

  defp custom_from_data(type, data, pipeline) do
    # Field atoms exist once the rules that read them are loaded.
    Aethrion.Pipeline.ensure_loaded(pipeline)

    case Enum.find(Aethrion.Pipeline.event_types(pipeline), &(Atom.to_string(&1) == type)) do
      nil ->
        unsupported(type)

      type ->
        fields =
          for {key, value} <- data,
              key not in ["type", "id", "cause"],
              atom = existing_atom(key),
              into: %{},
              do: {atom, value}

        {:ok, Map.put(fields, :type, type)}
    end
  end

  defp unsupported(type) do
    {:error,
     Aethrion.Error.new(:unsupported_event, "unsupported event type: #{inspect(type)}", %{
       type: type
     })}
  end

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom(_key), do: nil

  defp build(:gift_received, data) do
    gift_received(data["from"], data["to"], data["item"],
      observed_by: Map.get(data, "observed_by", []),
      at: Map.get(data, "at", @unspecified)
    )
  end

  defp build(:time_tick, data) do
    time_tick(Map.get(data, "now", @unspecified), hours: Map.get(data, "hours", 1))
  end

  defp build(:apology_offered, data) do
    apology_offered(data["from"], data["to"], data["reason"],
      observed_by: Map.get(data, "observed_by", []),
      at: Map.get(data, "at", @unspecified)
    )
  end

  defp build(:message_sent, data) do
    message_sent(data["from"], data["to"], data["text"],
      tone: tone_from_data(Map.get(data, "tone", "neutral")),
      observed_by: Map.get(data, "observed_by", []),
      at: Map.get(data, "at", @unspecified)
    )
  end

  defp build(:gossip_shared, data) do
    gossip_shared(data["from"], data["to"], data["memory_id"],
      at: Map.get(data, "at", @unspecified)
    )
  end

  defp build(:comfort_offered, data) do
    comfort_offered(data["from"], data["to"], at: Map.get(data, "at", @unspecified))
  end

  defp build(:time_spent_together, data) do
    time_spent_together(data["from"], data["to"], at: Map.get(data, "at", @unspecified))
  end

  # Unknown tones stay strings so validation can reject them with a clear error.
  defp tone_from_data(tone) when is_binary(tone) do
    Enum.find(@tones, tone, &(Atom.to_string(&1) == tone))
  end

  defp tone_from_data(tone), do: tone
end
