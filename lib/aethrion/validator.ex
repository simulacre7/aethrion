defmodule Aethrion.Validator do
  @moduledoc false

  alias Aethrion.{Error, Event, Pipeline, State}

  def validate_dispatch(state, event, pipeline \\ Pipeline.default())

  def validate_dispatch(%State{} = state, %{type: type} = event, %Pipeline{} = pipeline)
      when is_atom(type) do
    if Pipeline.handles?(pipeline, type) do
      with :ok <- require_labels(event), do: validate_event(state, event)
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

  # Time labels are free-form strings. Other values (tuples, DateTimes) would
  # not survive persistence or journaling unchanged.
  defp require_labels(%{type: :time_tick} = event), do: require_label(event, :now)

  defp require_labels(%{type: type} = event) do
    if type in Event.types(), do: require_label(event, :at), else: :ok
  end

  defp require_label(event, field) do
    if is_binary(Map.get(event, field)),
      do: :ok,
      else: {:error, error(:invalid_event, "#{field} must be a string label", %{field: field})}
  end

  defp validate_event(state, %{type: :gift_received} = event) do
    with :ok <- require_name(event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_conscious(state, event),
         :ok <- require_distinct(event),
         :ok <- require_name(event, :item) do
      require_observers(state, Map.get(event, :observed_by, []))
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
    with :ok <- require_name(event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_conscious(state, event),
         :ok <- require_distinct(event),
         :ok <- require_string(event, :reason) do
      require_observers(state, Map.get(event, :observed_by, []))
    end
  end

  defp validate_event(state, %{type: :message_sent} = event) do
    with :ok <- require_name(event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_conscious(state, event),
         :ok <- require_distinct(event),
         :ok <- require_string(event, :text),
         :ok <- require_tone(event) do
      require_observers(state, Map.get(event, :observed_by, []))
    end
  end

  defp validate_event(state, %{type: type} = event)
       when type in [:attack, :defend, :heal, :flee] do
    if Aethrion.Combat.over?(state),
      do:
        {:error,
         error(:invalid_event, "the fight is over: the story has reached its ending", %{
           field: :type
         })},
      else: validate_combat(state, event)
  end

  defp validate_event(state, %{type: :activity} = event) do
    with :ok <- require_character(state, event, :character),
         :ok <- require_name(event, :activity) do
      cond do
        not Map.has_key?(Map.get(state.story, :activities, %{}), event.activity) ->
          {:error,
           error(:invalid_event, "the story has no activity #{inspect(event.activity)}", %{
             field: :activity
           })}

        Aethrion.Rules.Ending.reached?(state) ->
          {:error, error(:invalid_event, "the story has reached its ending", %{field: :activity})}

        true ->
          :ok
      end
    end
  end

  defp validate_event(state, %{type: :comfort_offered} = event) do
    with :ok <- require_name(event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_conscious(state, event),
         :ok <- require_distinct(event) do
      require_available(state, event.from, :from)
    end
  end

  defp validate_event(state, %{type: :time_spent_together} = event) do
    with :ok <- require_character(state, event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_conscious(state, event),
         :ok <- require_distinct(event),
         :ok <- require_available(state, event.from, :from) do
      require_available(state, event.to, :to)
    end
  end

  defp validate_event(state, %{type: :gossip_shared} = event) do
    with :ok <- require_character(state, event, :from),
         :ok <- require_character(state, event, :to),
         :ok <- require_conscious(state, event),
         :ok <- require_distinct(event),
         :ok <- require_available(state, event.from, :from),
         :ok <- require_available(state, event.to, :to) do
      require_owned_memory(state, event)
    end
  end

  # Custom event types registered in a custom pipeline are validated by their rules.
  defp validate_event(_state, _event), do: :ok

  defp validate_combat(state, %{type: :attack} = event) do
    with :ok <- require_fighter(state, event, :from),
         :ok <- require_fighter(state, event, :to),
         :ok <- require_distinct(event),
         :ok <- optional_name(event, :skill) do
      require_observers(state, Map.get(event, :observed_by, []))
    end
  end

  defp validate_combat(state, %{type: :defend} = event) do
    with :ok <- require_fighter(state, event, :from) do
      if Map.has_key?(event, :to),
        do:
          with(
            :ok <- require_fighter(state, event, :to),
            :ok <- require_distinct(event),
            do: require_ally(state, event)
          ),
        else: :ok
    end
  end

  # The fallen are not revived, a healer must be standing, and someone at
  # full health is not healed (no potion is wasted on them).
  defp validate_combat(state, %{type: :heal} = event) do
    with :ok <- require_name(event, :from),
         :ok <- require_healer(state, event.from),
         :ok <- require_fighter(state, event, :to),
         :ok <- require_hurt(state, event.to),
         :ok <- optional_name(event, :item),
         :ok <- optional_name(event, :asked_by),
         :ok <- require_means(state, event) do
      case Map.get(event, :amount) do
        nil ->
          :ok

        amount when is_integer(amount) and amount > 0 ->
          :ok

        _other ->
          {:error,
           error(:invalid_event, "amount must be a positive whole number", %{field: :amount})}
      end
    end
  end

  defp validate_combat(state, %{type: :flee} = event) do
    with :ok <- require_fighter(state, event, :from),
         :ok <- require_fighter(state, event, :to),
         :ok <- require_distinct(event) do
      require_enemy(state, event.to)
    end
  end

  # One shields someone on one's own side, not an enemy (or, for an enemy,
  # not the player's side).
  defp require_ally(state, %{from: from, to: to}) do
    if State.stat(state, from, "enemy") > 0 == State.stat(state, to, "enemy") > 0,
      do: :ok,
      else: {:error, error(:invalid_event, "#{to} is not on #{from}'s side", %{field: :to})}
  end

  # With enemies in the world, one runs from them, not from a companion.
  defp require_enemy(state, id) do
    enemies? = Enum.any?(Map.keys(state.stats), &(State.stat(state, &1, "enemy") > 0))

    if enemies? and State.stat(state, id, "enemy") == 0,
      do: {:error, error(:invalid_event, "#{id} is not an enemy to flee from", %{field: :to})},
      else: :ok
  end

  # A character knocked out in a fight (0 hp) neither talks nor listens.
  # (A player who fell can still talk to the others afterwards.)
  defp require_conscious(state, event) do
    case Enum.find(
           [event.from, event.to],
           &(State.character?(state, &1) and State.stat?(state, &1, "hp") and
               State.stat(state, &1, "hp") <= 0)
         ) do
      nil -> :ok
      id -> {:error, error(:unavailable_character, "#{id} is down", %{character_id: id})}
    end
  end

  defp require_string(event, field) do
    value = Map.get(event, field)

    if is_binary(value) and value != "" do
      :ok
    else
      {:error, error(:invalid_event, "#{field} must be a non-empty string", %{field: field})}
    end
  end

  # Ids and items are names, not text: no line breaks or other control
  # characters, which could also pass for structure in a model's prompt.
  defp require_name(event, field) do
    with :ok <- require_string(event, field) do
      if String.match?(Map.get(event, field), ~r/\p{Cc}/u),
        do:
          {:error,
           error(:invalid_event, "#{field} must not contain control characters", %{field: field})},
        else: :ok
    end
  end

  # Fighters are actors with an hp stat; most actions need them standing.
  defp require_fighter(state, event, field, opts \\ []) do
    with :ok <- require_name(event, field) do
      id = Map.fetch!(event, field)

      cond do
        not State.stat?(state, id, "hp") and not State.character?(state, id) and id != "user" and
            not Map.has_key?(state.people, id) ->
          {:error,
           error(:unknown_character, "unknown character: #{inspect(id)}", %{
             field: field,
             character_id: id
           })}

        not State.stat?(state, id, "hp") ->
          {:error,
           error(:invalid_event, "#{id} cannot fight: no hp stat", %{field: field, actor: id})}

        Keyword.get(opts, :alive, true) and State.stat(state, id, "hp") <= 0 ->
          {:error, error(:invalid_event, "#{id} is already down", %{field: field, actor: id})}

        true ->
          :ok
      end
    end
  end

  defp require_healer(state, from) do
    cond do
      State.stat?(state, from, "hp") and State.stat(state, from, "hp") <= 0 ->
        {:error, error(:invalid_event, "#{from} is down and cannot heal", %{field: :from})}

      State.character?(state, from) or State.stat?(state, from, "hp") or from == "user" or
          Map.has_key?(state.people, from) ->
        :ok

      true ->
        {:error, error(:unknown_character, "unknown healer: #{inspect(from)}", %{field: :from})}
    end
  end

  defp require_hurt(state, id) do
    if State.stat?(state, id, "max_hp") and
         State.stat(state, id, "hp") >= State.stat(state, id, "max_hp"),
       do: {:error, error(:invalid_event, "#{id} is not hurt", %{field: :to})},
       else: :ok
  end

  # Healing takes a healer (a "heal" stat) or an item the healer has: a
  # potion uses one of their "potions", a bandage one of "bandages".
  defp require_means(state, %{item: item, from: from}) when is_binary(item) do
    count = item <> "s"

    if State.stat(state, from, count) > 0,
      do: :ok,
      else: {:error, error(:invalid_event, "#{from} has no #{count} left", %{field: :item})}
  end

  defp require_means(state, %{from: from}) do
    if State.stat(state, from, "heal") > 0,
      do: :ok,
      else:
        {:error,
         error(:invalid_event, "#{from} cannot heal without a potion or a healer's skill", %{
           field: :item
         })}
  end

  defp optional_name(event, field) do
    case Map.get(event, field) do
      nil -> :ok
      _value -> require_name(event, field)
    end
  end

  defp require_character(state, event, field) do
    character_id = Map.get(event, field)

    cond do
      not is_binary(character_id) ->
        {:error,
         error(
           :invalid_event,
           "#{field} must be a character id, got: #{inspect(character_id)}",
           %{
             field: field
           }
         )}

      State.character?(state, character_id) ->
        :ok

      true ->
        {:error,
         error(:unknown_character, "unknown character: #{inspect(character_id)}", %{
           field: field,
           character_id: character_id
         })}
    end
  end

  # Characters who are inactive or blocked cannot initiate or join interactions.
  # External actors such as "user" are always available.
  defp require_available(state, id, field) do
    case State.character(state, id) do
      %Aethrion.Character{} = character ->
        if Aethrion.Character.can_act?(character) do
          :ok
        else
          {:error,
           error(:unavailable_character, "#{inspect(id)} is inactive or blocked", %{
             field: field,
             character_id: id
           })}
        end

      nil ->
        :ok
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
         "tone must be one of #{Enum.map_join(Event.tones(), ", ", &Atom.to_string/1)}, got: #{if is_binary(tone), do: tone, else: inspect(tone)}",
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
