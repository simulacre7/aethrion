defmodule Aethrion.Intent do
  @moduledoc """
  Turns free text into a proposed event, without letting a model decide what
  happens.

  An adapter may *propose* an interpretation of what the user typed ("this is
  an apology", "this message is warm"), but it can only choose from a closed
  set of intents and tones. `interpret/3` normalizes the proposal and builds the
  event with the regular constructors. The event is returned, not dispatched:
  it still has to pass `Aethrion.Runtime.dispatch/3` validation and rules
  before anything changes.

      {:ok, event, meta} = Aethrion.Intent.interpret(state, "sorry about earlier", to: "yuna")
      event.type
      #=> :apology_offered

  If the adapter errors, raises, or proposes something outside the allowed set,
  the deterministic `Aethrion.LLM.FakeAdapter` interpretation is used instead
  and `meta.status` is `:fallback`.
  """

  alias Aethrion.{Error, Event, State}
  alias Aethrion.LLM.FakeAdapter

  defmodule Request do
    @moduledoc """
    Read-only input for `c:Aethrion.LLM.Adapter.interpret/2`.
    """

    @type t :: %__MODULE__{
            text: String.t(),
            from: String.t(),
            to: String.t(),
            listener: map(),
            intents: [atom()],
            tones: [atom()]
          }

    defstruct [:text, :from, :to, :listener, intents: [:message, :apology], tones: []]
  end

  @intents [:message, :apology]

  @doc """
  Interprets `text` sent from `:from` (default `"user"`) to character `:to`.

  Options: `:to` (required), `:from`, `:at`, `:adapter`, `:adapter_opts`.

  Returns `{:ok, event, meta}` or `{:error, %Aethrion.Error{}}` when the text is
  empty or the target is unknown.
  """
  def interpret(%State{} = state, text, opts) do
    from = Keyword.get(opts, :from, "user")
    to = Keyword.fetch!(opts, :to)
    adapter = Keyword.get(opts, :adapter, FakeAdapter)

    cond do
      not is_binary(text) or String.trim(text) == "" ->
        {:error, error(:invalid_event, "text must be a non-empty string", %{field: :text})}

      not State.character?(state, to) ->
        {:error,
         error(:unknown_character, "unknown character: #{inspect(to)}", %{
           field: :to,
           character_id: to
         })}

      true ->
        request = %Request{
          text: String.trim(text),
          from: from,
          to: to,
          listener: listener(state, to),
          intents: @intents,
          tones: Event.tones()
        }

        {proposal, meta} = propose(adapter, request, Keyword.get(opts, :adapter_opts, []))
        {:ok, build_event(proposal, request, Keyword.get(opts, :at, "intent")), meta}
    end
  end

  defp propose(adapter, request, adapter_opts) do
    result =
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :interpret, 2) do
        safe_interpret(adapter, request, adapter_opts)
      else
        {:error, :interpret_not_supported}
      end

    case result do
      {:ok, proposal} ->
        case normalize(proposal) do
          {:ok, proposal} -> {proposal, %{adapter: adapter, status: :ok, proposal: proposal}}
          :error -> fallback(adapter, request, {:invalid_proposal, proposal})
        end

      {:error, reason} ->
        fallback(adapter, request, reason)

      other ->
        fallback(adapter, request, {:invalid_response, other})
    end
  end

  defp fallback(adapter, request, reason) do
    {:ok, proposal} = FakeAdapter.interpret(request)
    {proposal, %{adapter: adapter, status: :fallback, reason: reason, proposal: proposal}}
  end

  defp safe_interpret(adapter, request, adapter_opts) do
    adapter.interpret(request, adapter_opts)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  def normalize(proposal) when is_map(proposal) do
    intent = proposal |> fetch(:intent) |> to_enum(@intents)

    case {intent, fetch(proposal, :tone)} do
      {:apology, _tone} ->
        {:ok, %{intent: :apology}}

      {:message, nil} ->
        {:ok, %{intent: :message, tone: :neutral}}

      {:message, tone} ->
        case to_enum(tone, Event.tones()) do
          nil -> :error
          tone -> {:ok, %{intent: :message, tone: tone}}
        end

      _ ->
        :error
    end
  end

  def normalize(_proposal), do: :error

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp to_enum(value, allowed) when is_atom(value), do: if(value in allowed, do: value)

  defp to_enum(value, allowed) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp to_enum(_value, _allowed), do: nil

  defp build_event(%{intent: :apology}, request, at) do
    Event.apology_offered(request.from, request.to, request.text, at: at)
  end

  defp build_event(%{intent: :message, tone: tone}, request, at) do
    Event.message_sent(request.from, request.to, request.text, tone: tone, at: at)
  end

  defp listener(state, id) do
    character = State.character(state, id)
    %{id: id, name: character.name, profile: character.profile, traits: character.traits}
  end

  defp error(code, message, details), do: %Error{code: code, message: message, details: details}
end
