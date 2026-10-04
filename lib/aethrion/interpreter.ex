defmodule Aethrion.Interpreter do
  @moduledoc """
  What a line a player typed does, as events the engine can check and apply.
  This is the seam between free text and the rules: the rules never see
  text, only the events an interpreter proposes, and everything after that
  (validation, state, journals, replay) stays deterministic.

  An interpreter is a module with `c:interpret/2`. It gets a `Request` (the
  state, who says what to whom, and a `schema` of what is possible in this
  world right now) and returns readings, in order:

      [%{as: :talk, event: %{type: :message_sent, ...}, confidence: 0.9},
       %{as: :combat, event: %{type: :attack, ...}, confidence: 0.97}]

  `Aethrion.Interpreter.Rules` is the built-in one (keywords and patterns,
  no model). A model plugs in by answering the schema's `questions/1`
  (choices drawn from the cast: what the line does, at whom, in what tone,
  which activity) and turning the answers into readings with
  `from_answers/2`; a decision model that returns typed choices with
  probabilities (Jev, say) or an LLM with structured output fits this
  shape. `read/5` falls back to the rules when an interpreter fails, returns
  something that is not a reading, or is less sure than `:min_confidence`.

  The readings become events like any other: an interpreter cannot change
  a number the rules did not change, and a journal holds the events, so a
  replay never asks the interpreter again.
  """

  alias Aethrion.{Combat, Event, State}

  defmodule Request do
    @moduledoc "What an interpreter is asked: a line in a world, and what is possible there."
    @type t :: %__MODULE__{
            state: Aethrion.State.t(),
            from: String.t(),
            to: String.t(),
            text: String.t(),
            schema: map()
          }
    defstruct [:state, :from, :to, :text, :schema]
  end

  @type reading :: %{as: :combat | :activity | :gift | :talk, event: map(), confidence: float()}

  @callback interpret(Request.t(), keyword()) :: {:ok, [reading()]} | {:error, term()}

  @kinds ~w(attack defend heal flee activity gift talk apology)a
  @tones [:warm, :neutral, :cold, :hostile]

  @doc """
  The readings of `text`, said by `from` to `to`: `{:ok, readings, meta}`,
  where `meta.status` is `:ok`, or `:fallback` with a `:reason` when the
  rules stood in. Options: `:interpreter` (default
  `Aethrion.Interpreter.Rules`), `:interpreter_opts`, `:min_confidence`
  (default 0.5), and `:intent` (the adapter options the rules use to read
  the tone of talk, as `Aethrion.Intent` takes them).
  """
  @spec read(State.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [reading()], map()}
  def read(%State{} = state, from, to, text, opts \\ []) do
    request = %Request{
      state: state,
      from: from,
      to: to,
      text: text,
      schema: schema(state, from, to)
    }

    interpreter = Keyword.get(opts, :interpreter, __MODULE__.Rules)

    result =
      try do
        interpreter.interpret(
          request,
          Keyword.get(opts, :interpreter_opts, []) ++
            intent(opts) ++ [allow_none: Keyword.get(opts, :allow_none, false)]
        )
      rescue
        exception -> {:error, {:exception, Exception.message(exception)}}
      end

    case result do
      # The line does nothing the rules track (`:allow_none`): the player
      # walks on, or fights something the cast does not have.
      {:ok, []} when interpreter != __MODULE__.Rules ->
        if Keyword.get(opts, :allow_none, false),
          do: {:ok, [], %{interpreter: interpreter, status: :ok}},
          else: fallback(request, opts, {:invalid_response, []})

      {:ok, [_ | _] = readings} ->
        taken(readings, request, interpreter, opts)

      {:error, reason} ->
        fallback(request, opts, reason)

      other ->
        fallback(request, opts, {:invalid_response, other})
    end
  end

  # The interpreter's readings when they can be taken, the rules' otherwise.
  defp taken(readings, %Request{state: state} = request, interpreter, opts) do
    min = Keyword.get(opts, :min_confidence, 0.5)

    cond do
      not Enum.all?(readings, &reading?/1) ->
        fallback(request, opts, {:invalid_readings, readings})

      Enum.any?(readings, &(&1.confidence < min)) ->
        fallback(request, opts, :unsure)

      true ->
        # The rules standing in for themselves would read the same.
        case interpreter != __MODULE__.Rules and invalid(state, readings) do
          problem when is_binary(problem) ->
            fallback(request, opts, {:invalid_event, problem})

          _valid ->
            {:ok, readings, %{interpreter: interpreter, status: :ok}}
        end
    end
  end

  defp intent(opts), do: [intent: Keyword.get(opts, :intent, [])]

  # A reading the runtime would reject is not taken: the first reading must
  # be valid now (later ones may depend on it, and are checked when applied).
  defp invalid(state, [%{event: event} | _]) do
    case Aethrion.Validator.validate_dispatch(state, event, Aethrion.Story.pipeline()) do
      :ok -> nil
      {:error, error} -> error.message
    end
  end

  defp fallback(request, opts, reason) do
    {:ok, readings} = __MODULE__.Rules.interpret(request, intent(opts))
    {:ok, readings, %{interpreter: __MODULE__.Rules, status: :fallback, reason: reason}}
  end

  defp reading?(%{as: as, event: %{type: type}, confidence: c})
       when as in [:combat, :activity, :gift, :talk] and is_atom(type) and is_number(c),
       do: true

  defp reading?(_reading), do: false

  @doc """
  What is possible for a line from `from` to `to` in `state`: whether a
  fight is on, the people and characters it may concern (with their side),
  the tones, and the story's activities.
  """
  @spec schema(State.t(), String.t(), String.t()) :: map()
  def schema(%State{} = state, from, to) do
    targets =
      for character <- State.sorted_characters(state) do
        side =
          cond do
            State.stat(state, character.id, "enemy") > 0 -> :enemy
            State.stat(state, character.id, "party") > 0 -> :party
            true -> :other
          end

        %{
          id: character.id,
          name: character.name,
          side: side,
          down: State.down?(state, character.id)
        }
      end

    %{
      from: from,
      to: to,
      fight: Combat.foe(state) != nil and not Combat.over?(state),
      kinds: @kinds,
      targets: targets,
      healers:
        for(
          t <- targets,
          Combat.healer?(state, t.id),
          State.stat(state, t.id, "away") == 0,
          do: t.id
        ),
      tones: @tones,
      activities: state.story |> Map.get(:activities, %{}) |> Map.keys() |> Enum.sort()
    }
  end

  @doc """
  The schema as typed questions, for a decision model or a structured
  output: each with an `id`, the `question`, and its `options` (`:choice`),
  or a yes/no `:noul`. Ids and option values are what `from_answers/2`
  takes back.
  """
  @spec questions(map()) :: [map()]
  def questions(schema) do
    ids = Enum.map(schema.targets, & &1.id)

    [
      %{
        id: "does",
        type: :choice,
        question:
          "What does the player's chat line do in this world? " <>
            if(schema.fight, do: "A fight is on.", else: "No fight is on."),
        options: Enum.map(schema.kinds, &Atom.to_string/1)
      },
      %{
        id: "target",
        type: :choice,
        question: "Whom is it aimed at or said to? (" <> names(schema.targets) <> ")",
        options: ["user" | ids]
      },
      %{
        id: "tone",
        type: :choice,
        question: "If it is talk, in what tone?",
        options: Enum.map(schema.tones, &Atom.to_string/1)
      },
      %{
        id: "activity",
        type: :choice,
        question: "If it suggests an activity, which?",
        options: schema.activities
      },
      %{
        id: "helper",
        type: :choice,
        question: "If it asks someone else to heal, who?",
        options: schema.healers
      }
    ]
  end

  defp names(targets), do: Enum.map_join(targets, ", ", &"#{&1.id} = #{&1.name} (#{&1.side})")

  @doc """
  Readings from answers to `questions/1`: `%{"does" => "attack", "target"
  => "wolf"}`, `%{"does" => "talk", "tone" => "warm"}`, `%{"does" =>
  "heal", "helper" => "ria", "target" => "user"}`. `"confidence"` (0..1)
  is carried over. A gift's `"item"` is taken as given, or named from the
  words. Answers outside
  the schema are an error.
  """
  @spec from_answers(Request.t(), map()) :: {:ok, [reading()]} | {:error, term()}
  def from_answers(%Request{schema: schema} = request, answers) when is_map(answers) do
    confidence = Map.get(answers, "confidence", 1.0)
    target = Map.get(answers, "target")
    known = ["user" | Enum.map(schema.targets, & &1.id)]

    with {:ok, kind} <- pick(answers, "does", Enum.map(schema.kinds, &Atom.to_string/1)),
         :ok <- confidence(confidence),
         :ok <- in_a_fight(schema, kind),
         :ok <- if(target in [nil | known], do: :ok, else: {:error, {:unknown_target, target}}) do
      case event(request, String.to_existing_atom(kind), answers, target) do
        {:ok, as, event} -> {:ok, [%{as: as, event: event, confidence: confidence}]}
        error -> error
      end
    end
  end

  defp confidence(c) when is_number(c) and c >= 0 and c <= 1, do: :ok
  defp confidence(c), do: {:error, {:invalid_confidence, c}}

  # Fight moves only while a fight is on.
  defp in_a_fight(%{fight: false}, kind) when kind in ~w(attack defend heal flee),
    do: {:error, :no_fight}

  defp in_a_fight(_schema, _kind), do: :ok

  defp pick(answers, key, options) do
    value = Map.get(answers, key)
    if value in options, do: {:ok, value}, else: {:error, {:not_an_option, key, value}}
  end

  defp event(%Request{from: from, schema: schema} = request, kind, _answers, target)
       when kind in [:attack, :flee] do
    foe = target || Combat.foe(request.state)

    cond do
      not schema.fight or foe == nil -> {:error, :no_fight}
      kind == :attack -> {:ok, :combat, Event.attack(from, foe, skill: request.text)}
      true -> {:ok, :combat, Event.flee(from, foe)}
    end
  end

  defp event(%Request{from: from}, :defend, _answers, target),
    do: {:ok, :combat, Event.defend(from, to: if(target in [nil, from], do: nil, else: target))}

  defp event(%Request{from: from, schema: schema} = request, :heal, answers, target) do
    case Map.get(answers, "helper") do
      helper when is_binary(helper) ->
        if helper in schema.healers,
          do: {:ok, :combat, Event.heal(helper, target || from, asked_by: from)},
          else: {:error, {:not_an_option, "helper", helper}}

      # The player's own heal takes what the rules would: their healing,
      # or a potion they hold. The amount is never the model's.
      nil ->
        to = target || from

        {:ok, :combat,
         Event.heal(from, to, item: Combat.heal_item(request.state, from, request.text))}
    end
  end

  defp event(%Request{to: to, schema: schema}, :activity, answers, _target) do
    with {:ok, name} <- pick(answers, "activity", schema.activities) do
      {:ok, :activity, Event.activity(to, name)}
    end
  end

  defp event(%Request{from: from, to: to, text: text}, :gift, answers, target) do
    item =
      case Map.get(answers, "item") do
        item when is_binary(item) and item != "" -> String.slice(item, 0, 40)
        _none -> Aethrion.Chat.item(text)
      end

    {:ok, :gift, Event.gift_received(from, target || to, item)}
  end

  defp event(%Request{from: from, to: to, text: text}, :apology, _answers, target),
    do: {:ok, :talk, Event.apology_offered(from, target || to, text)}

  defp event(%Request{from: from, to: to, text: text}, :talk, answers, target) do
    with {:ok, tone} <- pick(answers, "tone", ~w(warm neutral cold hostile)) do
      {:ok, :talk,
       Event.message_sent(from, target || to, text, tone: String.to_existing_atom(tone))}
    end
  end
end
