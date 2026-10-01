defmodule Aethrion.Conversation do
  @moduledoc """
  What a character and a person recently said to each other.

  Every step records, per pair, what a person said to a character (a
  message, a gift, an apology), what the character said back (a reply or
  a proactive message), and what they did to each other in a fight (a
  `:deed`: a blow, a heal, holding back), keeping the last #{24} turns. Replies and proactive
  messages carry the recent turns in their expression request
  (`Aethrion.Expression.Request` `:conversation`), so a model answering in a
  chat sees the thread, not only the latest line.

  Characters' turns are recorded with the deterministic fallback text when
  the step runs. When a model phrases the line, `put_rendered/2` swaps in
  what was actually said; `Aethrion.RuntimeServer` does this for its world
  and journals it, so a replayed journal holds the same conversation.

  Conversations are bookkeeping for expression: no rule reads them, so they
  never change what happens.
  """

  alias Aethrion.State

  @turns_kept 24

  @type kind :: :message | :gift | :apology | :reply | :proactive | :deed
  @type turn :: %{
          from: String.t(),
          to: String.t(),
          text: String.t(),
          kind: kind(),
          tone: atom() | nil,
          event_id: String.t() | nil,
          at: non_neg_integer()
        }

  @doc "How many turns are kept per pair."
  @spec turns_kept() :: pos_integer()
  def turns_kept, do: @turns_kept

  @doc """
  The last `limit` turns between `a` and `b` (in either direction), oldest
  first.
  """
  @spec recent(State.t(), String.t(), String.t(), non_neg_integer()) :: [turn()]
  def recent(%State{} = state, a, b, limit \\ @turns_kept) do
    state.conversations
    |> Map.get(pair(a, b), [])
    |> Enum.take(-limit)
  end

  @doc false
  # Records what a step's people said to characters and what characters said
  # to people, in order: the events first, then the lines they led to.
  @spec record_step(State.t(), [map()], [map()]) :: State.t()
  def record_step(%State{} = state, events, outputs) do
    turns =
      Enum.flat_map(events, &said_by_person(state, &1)) ++
        Enum.flat_map(outputs, &(said_to_person(state, &1) ++ deed(state, &1)))

    Enum.reduce(turns, state, &append(&2, &1))
  end

  @doc """
  Replaces a character's recorded line with the text a model rendered for it.
  Takes a rendered output (one with `expression: %{status: :ok}`); anything
  else, or a line no longer kept, leaves the state as it is.
  """
  @spec put_rendered(State.t(), map()) :: State.t()
  def put_rendered(
        %State{} = state,
        %{
          type: type,
          character_id: from,
          to: to,
          event_id: event_id,
          text: text,
          expression: %{status: :ok},
          context: %{fallback_text: draft}
        }
      )
      when type in [:reply, :proactive_message] and is_binary(text) do
    put_rendered(state, %{event_id: event_id, from: from, to: to, draft: draft, text: text})
  end

  def put_rendered(%State{} = state, %{
        event_id: event_id,
        from: from,
        to: to,
        draft: draft,
        text: text
      })
      when is_binary(text) do
    key = pair(from, to)

    case Map.fetch(state.conversations, key) do
      {:ok, turns} ->
        matches? = &match?(%{event_id: ^event_id, from: ^from, to: ^to, text: ^draft}, &1)

        case Enum.find_index(turns, matches?) do
          nil ->
            state

          index ->
            turns = List.update_at(turns, index, &%{&1 | text: text})
            %{state | conversations: Map.put(state.conversations, key, turns)}
        end

      :error ->
        state
    end
  end

  def put_rendered(%State{} = state, _output), do: state

  @doc false
  # What a rendered output changes, as plain data for a journal line.
  @spec rendered_data(map()) :: map() | nil
  def rendered_data(%{
        type: type,
        character_id: from,
        to: to,
        event_id: event_id,
        text: text,
        expression: %{status: :ok},
        context: %{fallback_text: draft}
      })
      when type in [:reply, :proactive_message] and is_binary(text) do
    %{"event_id" => event_id, "from" => from, "to" => to, "draft" => draft, "text" => text}
  end

  def rendered_data(_output), do: nil

  @doc false
  @spec rendered_from_data(map()) :: {:ok, map()} | :error
  def rendered_from_data(%{
        "event_id" => id,
        "from" => from,
        "to" => to,
        "draft" => draft,
        "text" => text
      })
      when is_binary(id) and is_binary(from) and is_binary(to) and is_binary(draft) and
             is_binary(text),
      do: {:ok, %{event_id: id, from: from, to: to, draft: draft, text: text}}

  def rendered_from_data(_data), do: :error

  ## Serialization

  @doc false
  def to_data(conversations) do
    conversations
    |> Enum.sort()
    |> Enum.map(fn {{a, b}, turns} ->
      %{"between" => [a, b], "turns" => Enum.map(turns, &turn_to_data/1)}
    end)
  end

  @doc false
  def from_data(list) when is_list(list) do
    Map.new(list, fn %{"between" => [a, b], "turns" => turns} ->
      {pair(a, b), Enum.map(turns, &turn_from_data/1)}
    end)
  end

  def from_data(_none), do: %{}

  @doc false
  # Whether untrusted data has the shape `from_data/1` expects.
  def valid_data?(list) when is_list(list) do
    Enum.all?(list, fn
      %{"between" => [a, b], "turns" => turns}
      when is_binary(a) and is_binary(b) and is_list(turns) ->
        Enum.all?(turns, &valid_turn?/1)

      _other ->
        false
    end)
  end

  def valid_data?(_data), do: false

  @kinds [:message, :gift, :apology, :reply, :proactive, :deed]
  @tones [:warm, :neutral, :cold, :hostile, :gift, :apology]

  defp valid_turn?(%{"from" => from, "to" => to, "text" => text, "kind" => kind} = turn) do
    is_binary(from) and is_binary(to) and is_binary(text) and
      Enum.any?(@kinds, &(Atom.to_string(&1) == kind)) and
      (is_nil(turn["tone"]) or is_binary(turn["tone"])) and
      (is_nil(turn["event_id"]) or is_binary(turn["event_id"])) and
      (is_integer(turn["at"]) and turn["at"] >= 0)
  end

  defp valid_turn?(_turn), do: false

  defp turn_to_data(turn) do
    %{
      "from" => turn.from,
      "to" => turn.to,
      "text" => turn.text,
      "kind" => Atom.to_string(turn.kind),
      "tone" => turn.tone && Atom.to_string(turn.tone),
      "event_id" => turn.event_id,
      "at" => turn.at
    }
  end

  defp turn_from_data(data) do
    %{
      from: data["from"],
      to: data["to"],
      text: data["text"],
      kind: Enum.find(@kinds, :message, &(Atom.to_string(&1) == data["kind"])),
      tone: Enum.find(@tones, &(Atom.to_string(&1) == data["tone"])),
      event_id: data["event_id"],
      at: data["at"]
    }
  end

  ## Helpers

  defp said_by_person(state, %{from: from, to: to} = event)
       when is_binary(from) and is_binary(to) do
    if person?(state, from) and State.character?(state, to) do
      case event do
        %{type: :message_sent, text: text, tone: tone} ->
          [turn(state, event, :message, text, tone)]

        %{type: :gift_received, item: item} ->
          [turn(state, event, :gift, item, nil)]

        %{type: :apology_offered, reason: reason} ->
          [turn(state, event, :apology, reason, nil)]

        _other ->
          []
      end
    else
      []
    end
  end

  defp said_by_person(_state, _event), do: []

  defp said_to_person(state, %{type: type, character_id: from, to: to, text: text} = output)
       when type in [:reply, :proactive_message] and is_binary(to) and is_binary(text) do
    if person?(state, to) do
      kind = if type == :reply, do: :reply, else: :proactive

      [
        %{
          from: from,
          to: to,
          text: text,
          kind: kind,
          # For a reply, the tone it answers (a gift and an apology count too).
          tone: Map.get(output, :tone),
          event_id: Map.get(output, :event_id),
          at: state.clock
        }
      ]
    else
      []
    end
  end

  defp said_to_person(_state, _output), do: []

  # What a person and a character did to each other in a fight (a blow, a
  # heal, holding back), told in a line, so a reply can remember it.
  defp deed(state, %{type: :combat, kind: kind, character_id: from, to: to} = output)
       when kind in [:hit, :critical, :healed, :holds_back] and is_binary(to) do
    if from != to and person?(state, from) != person?(state, to) and
         (State.character?(state, from) or State.character?(state, to)) do
      [
        %{
          from: from,
          to: to,
          text: deed_text(output),
          kind: :deed,
          tone: nil,
          event_id: Map.get(output, :event_id),
          at: state.clock
        }
      ]
    else
      []
    end
  end

  defp deed(_state, _output), do: []

  # Ids, not "you": the line is read from either side.
  defp deed_text(%{kind: :healed, to: to, amount: amount}), do: "heals #{to} for #{amount}"
  defp deed_text(%{kind: :holds_back, to: to}), do: "holds back instead of fighting beside #{to}"
  defp deed_text(%{kind: :critical, to: to, amount: amount}), do: "hits #{to} hard for #{amount}"
  defp deed_text(%{to: to, amount: amount}), do: "hits #{to} for #{amount}"

  defp turn(state, event, kind, text, tone) do
    %{
      from: event.from,
      to: event.to,
      text: to_string(text),
      kind: kind,
      tone: tone,
      event_id: Map.get(event, :id),
      at: state.clock
    }
  end

  defp append(state, turn) do
    key = pair(turn.from, turn.to)

    turns =
      state.conversations |> Map.get(key, []) |> Kernel.++([turn]) |> Enum.take(-@turns_kept)

    %{state | conversations: Map.put(state.conversations, key, turns)}
  end

  defp person?(state, id), do: not State.character?(state, id)

  defp pair(a, b) when a <= b, do: {a, b}
  defp pair(a, b), do: {b, a}
end
