defmodule Aethrion.Validator do
  @moduledoc false

  alias Aethrion.{Error, State}

  def validate_dispatch(%State{} = state, %{type: :gift_received} = event) do
    with :ok <- require_string(event, :from),
         :ok <- require_character(state, event.to, :to),
         :ok <- require_string(event, :item),
         :ok <- require_observers(state, Map.get(event, :observed_by, [])) do
      :ok
    end
  end

  def validate_dispatch(%State{}, %{type: :time_tick} = event) do
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

  def validate_dispatch(%State{} = state, %{type: :apology_offered} = event) do
    with :ok <- require_string(event, :from),
         :ok <- require_character(state, event.to, :to),
         :ok <- require_string(event, :reason) do
      :ok
    end
  end

  def validate_dispatch(%State{}, %{type: type}) do
    {:error, error(:unsupported_event, "unsupported event type: #{inspect(type)}", %{type: type})}
  end

  def validate_dispatch(%State{}, event) do
    {:error, error(:invalid_event, "event must include a supported :type", %{event: event})}
  end

  def validate_dispatch(_state, _event) do
    {:error, error(:invalid_state, "state must be an Aethrion.State struct")}
  end

  defp require_string(event, field) do
    value = Map.get(event, field)

    if is_binary(value) and value != "" do
      :ok
    else
      {:error, error(:invalid_event, "#{field} must be a non-empty string", %{field: field})}
    end
  end

  defp require_character(state, character_id, field) do
    if is_binary(character_id) and Map.has_key?(state.characters, character_id) do
      :ok
    else
      {:error,
       error(:unknown_character, "unknown character: #{inspect(character_id)}", %{
         field: field,
         character_id: character_id
       })}
    end
  end

  defp require_observers(state, observers) when is_list(observers) do
    Enum.reduce_while(observers, :ok, fn observer, :ok ->
      case require_character(state, observer, :observed_by) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
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
