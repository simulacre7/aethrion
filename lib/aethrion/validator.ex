defmodule Aethrion.Validator do
  @moduledoc false

  alias Aethrion.{Error, Event, Pipeline, State}

  def validate_dispatch(state, event, pipeline \\ Pipeline.default())

  def validate_dispatch(%State{} = state, %{type: type} = event, %Pipeline{} = pipeline)
      when is_atom(type) do
    if Pipeline.handles?(pipeline, type) do
      validate_event(state, event)
    else
      {:error,
       error(:unsupported_event, "unsupported event type: #{inspect(type)}", %{type: type})}
    end
  end

  def validate_dispatch(%State{}, event, _pipeline) do
    {:error, error(:invalid_event, "event must include a supported :type", %{event: event})}
  end

  def validate_dispatch(_state, _event, _pipeline) do
    {:error, error(:invalid_state, "state must be an Aethrion.State struct")}
  end

  defp validate_event(state, %{type: :gift_received} = event) do
    with :ok <- require_string(event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_string(event, :item),
         :ok <- require_observers(state, Map.get(event, :observed_by, [])) do
      :ok
    end
  end

  defp validate_event(_state, %{type: :time_tick} = event) do
    hours = Map.get(event, :hours)

    cond do
      not is_integer(hours) ->
        {:error, error(:invalid_event, "time_tick requires integer hours", %{field: :hours})}

      hours <= 0 ->
        {:error, error(:invalid_event, "time_tick hours must be positive", %{field: :hours})}

      true ->
        :ok
    end
  end

  defp validate_event(state, %{type: :apology_offered} = event) do
    with :ok <- require_string(event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_distinct(event),
         :ok <- require_string(event, :reason) do
      :ok
    end
  end

  defp validate_event(state, %{type: :message_sent} = event) do
    with :ok <- require_string(event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_distinct(event),
         :ok <- require_string(event, :text),
         :ok <- require_tone(event) do
      :ok
    end
  end

  defp validate_event(state, %{type: :comfort_offered} = event) do
    with :ok <- require_string(event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_distinct(event) do
      :ok
    end
  end

  defp validate_event(state, %{type: :gossip_shared} = event) do
    with :ok <- require_character(state, event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_distinct(event),
         :ok <- require_owned_memory(state, event) do
      :ok
    end
  end

  # Custom event types registered in a custom pipeline are validated by their rules.
  defp validate_event(_state, _event), do: :ok

  defp require_string(event, field) do
    value = Map.get(event, field)

    if is_binary(value) and value != "" do
      :ok
    else
      {:error, error(:invalid_event, "#{field} must be a non-empty string", %{field: field})}
    end
  end

  defp require_character(state, event, field) do
    character_id = Map.get(event, field)

    if State.character?(state, character_id) do
      :ok
    else
      {:error,
       error(:unknown_character, "unknown character: #{inspect(character_id)}", %{
         field: field,
         character_id: character_id
       })}
    end
  end

  defp require_distinct(%{from: same, to: same}) do
    {:error, error(:invalid_event, "from and to must be different actors", %{field: :from})}
  end

  defp require_distinct(_event), do: :ok

  defp require_tone(event) do
    tone = Map.get(event, :tone)

    if tone in Event.tones() do
      :ok
    else
      {:error,
       error(
         :invalid_event,
         "tone must be one of #{inspect(Event.tones())}, got: #{inspect(tone)}",
         %{field: :tone}
       )}
    end
  end

  defp require_owned_memory(state, event) do
    case State.memory(state, Map.get(event, :memory_id)) do
      %{character_id: owner, topic: topic} when owner == event.from and is_binary(topic) ->
        :ok

      _ ->
        {:error,
         error(
           :invalid_event,
           "memory_id must name a memory held by #{inspect(event.from)}",
           %{field: :memory_id}
         )}
    end
  end

  defp require_observers(state, observers) when is_list(observers) do
    Enum.reduce_while(observers, :ok, fn observer, :ok ->
      if State.character?(state, observer) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          error(:unknown_character, "unknown character: #{inspect(observer)}", %{
            field: :observed_by,
            character_id: observer
          })}}
      end
    end)
  end

  defp require_observers(_state, _observers) do
    {:error,
     error(:invalid_event, "observed_by must be a list of character ids", %{field: :observed_by})}
  end

  defp error(code, message, details \\ %{}) do
    %Error{code: code, message: message, details: details}
  end
end
