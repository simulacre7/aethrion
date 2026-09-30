defmodule Aethrion.Expression do
  @moduledoc """
  The expression layer: turning structured outputs into language.

  Rules attach a deterministic fallback `:text` and a read-only `:context`
  snapshot (`Aethrion.Expression.Request`) to every expressive output. This
  module can later re-render that text through an `Aethrion.LLM.Adapter`:

      {:ok, state, outputs, _log} = Aethrion.dispatch(state, event)
      outputs = Aethrion.Expression.render(outputs, adapter: MyApp.LLMAdapter)

  Rendering only ever touches output text. It does not take the state as an
  argument and cannot return one. On adapter errors, timeouts, or exceptions
  the fallback text is kept and the output is marked with
  `expression: %{status: :fallback, ...}`.
  """

  alias Aethrion.{Character, Memories, Memory, Output, State}
  alias Aethrion.Expression.{Request, Templates}
  alias Aethrion.LLM.FakeAdapter

  @doc """
  Builds a request snapshot for `speaker_id` addressing `listener_id`.

  Options:

  - `:reason` - required
  - `:memories` - explicit memories to include; otherwise the speaker's most
    relevant memories focused on the listener are selected
  - `:focus` - extra character ids for memory selection
  - `:tone`, `:message` - incoming tone and text for replies
  """
  @spec build_request(State.t(), atom(), String.t(), String.t(), keyword()) :: Request.t()
  def build_request(%State{} = state, kind, speaker_id, listener_id, opts) do
    memories =
      Keyword.get_lazy(opts, :memories, fn ->
        Memories.relevant(state, speaker_id,
          focus: [listener_id | Keyword.get(opts, :focus, [])],
          limit: 3
        )
      end)

    request = %Request{
      kind: kind,
      reason: Keyword.fetch!(opts, :reason),
      speaker: actor(state, speaker_id),
      listener: actor(state, listener_id),
      relationship: relationship(state, speaker_id, listener_id),
      memories: Enum.map(memories, &memory_view/1),
      names: names(state, [speaker_id, listener_id], memories),
      tone: Keyword.get(opts, :tone),
      message: Keyword.get(opts, :message),
      since_contact: Keyword.get(opts, :since_contact),
      repeats: Keyword.get(opts, :repeats),
      now: state.clock
    }

    %{request | fallback_text: Templates.render(request)}
  end

  @doc """
  Renders expressive outputs through `:adapter` (default `Aethrion.LLM.FakeAdapter`).
  Non-expressive outputs pass through unchanged.

  Options:

  - `:adapter` - an `Aethrion.LLM.Adapter` module
  - `:adapter_opts` - keyword options forwarded to the adapter
  """
  @spec render([map()], keyword()) :: [map()]
  def render(outputs, opts \\ []) when is_list(outputs) do
    Enum.map(outputs, &render_output(&1, opts))
  end

  @doc """
  Renders a single output. See `render/2`.
  """
  @spec render_output(map(), keyword()) :: map()
  def render_output(output, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, FakeAdapter)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case output do
      %{context: %Request{} = request} ->
        if Output.expressive?(output) do
          apply_rendering(output, adapter, safe_render(adapter, request, adapter_opts))
        else
          output
        end

      _other ->
        output
    end
  end

  defp safe_render(adapter, request, adapter_opts) do
    adapter.render(request, adapter_opts)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp apply_rendering(output, adapter, {:ok, text}) when is_binary(text) do
    case String.trim(text) do
      "" ->
        Map.put(output, :expression, %{
          status: :fallback,
          adapter: adapter,
          reason: :empty_response
        })

      text ->
        Map.merge(output, %{text: text, expression: %{status: :ok, adapter: adapter}})
    end
  end

  defp apply_rendering(output, adapter, {:error, reason}) do
    Map.put(output, :expression, %{status: :fallback, adapter: adapter, reason: reason})
  end

  defp apply_rendering(output, adapter, other) do
    Map.put(output, :expression, %{
      status: :fallback,
      adapter: adapter,
      reason: {:invalid_response, other}
    })
  end

  defp actor(state, id) do
    case State.character(state, id) do
      %Character{} = character ->
        %{
          id: id,
          name: character.name,
          profile: character.profile,
          traits: character.traits,
          mood: Aethrion.Rules.Mood.derive(character.state, state)
        }

      nil ->
        %{id: id, name: display_name(state, id), profile: nil, traits: [], mood: nil}
    end
  end

  defp relationship(state, from, to) do
    relationship = State.get_relationship(state, from, to)

    %{
      affinity: relationship.affinity,
      trust: relationship.trust,
      tension: relationship.tension,
      bond: Aethrion.Rules.Bond.derive(relationship, state)
    }
  end

  defp memory_view(%Memory{} = memory) do
    %{
      id: memory.id,
      content: memory.content,
      kind: memory.kind,
      importance: memory.importance,
      strength: memory.strength,
      source: memory.source,
      topic: memory.topic,
      created_tick: memory.created_tick,
      # Folded topics are bookkeeping, not something to phrase.
      data: Map.delete(memory.data, "topics")
    }
  end

  defp names(state, ids, memories) do
    memory_ids =
      Enum.flat_map(memories, fn memory ->
        data_ids = memory.data |> Map.take(["from", "to"]) |> Map.values()
        [memory.source | memory.related_characters] ++ data_ids
      end)

    (ids ++ memory_ids)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(&{&1, display_name(state, &1)})
  end

  # The user is addressed directly in generated lines.
  defp display_name(_state, "user"), do: "you"
  defp display_name(state, id), do: State.name(state, id)
end
