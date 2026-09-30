defmodule Aethrion.Transition do
  @moduledoc """
  Accumulator that rules use to change state explainably.

  A transition wraps the state being advanced for one event. Rules call helpers
  such as `adjust_character/4` or `remember/2` instead of editing state
  directly; each helper applies the change, clamps it, and records an
  `Aethrion.Trace` entry tagged with the current rule and event id. Relationship
  changes and memories also emit outputs, and most helpers add a log line.

  Rules may also `enqueue/2` follow-up events. The runtime validates and
  processes them after the current event, so derived social behavior (a
  character confiding in a friend, a friend offering comfort) passes through the
  same rules and validation as host events.
  """

  alias Aethrion.{CharacterState, Memory, Output, Relationship, State, Trace}

  @type t :: %__MODULE__{
          state: State.t(),
          event: map(),
          rule: atom() | nil,
          rule_module: module() | nil,
          outputs: [map()],
          log: [String.t()],
          trace: [Trace.t()],
          follow_ups: [map()]
        }

  # outputs, log, trace, and follow_ups are accumulated in reverse order.
  defstruct [
    :state,
    :event,
    rule: nil,
    rule_module: nil,
    outputs: [],
    log: [],
    trace: [],
    follow_ups: []
  ]

  @doc false
  def new(%State{} = state, event), do: %__MODULE__{state: state, event: event}

  @doc false
  def put_rule(%__MODULE__{} = transition, rule) when is_atom(rule) do
    if Code.ensure_loaded?(rule) and function_exported?(rule, :id, 0),
      do: %{transition | rule: rule.id(), rule_module: rule},
      else: %{transition | rule: rule, rule_module: nil}
  end

  @doc """
  Reads a parameter of the current rule: the world's override from
  `Aethrion.Tuning` if present, otherwise the rule's declared default.
  Raises for parameters the rule does not declare.
  """
  def param(%__MODULE__{rule_module: module, state: state}, key) when is_atom(module) do
    Aethrion.Tuning.get(state, module, key)
  end

  @doc false
  def finalize(%__MODULE__{} = transition) do
    %{
      state: transition.state,
      outputs: Enum.reverse(transition.outputs),
      log: Enum.reverse(transition.log),
      trace: Enum.reverse(transition.trace),
      follow_ups: Enum.reverse(transition.follow_ups)
    }
  end

  @doc "Display name for a character id, or the id itself for external actors."
  def name(%__MODULE__{state: state}, id), do: State.name(state, id)

  @doc "Current state of a character."
  def character_state(%__MODULE__{state: state}, id), do: state.characters[id].state

  @doc """
  Adds `delta` to a numeric character field, clamped to `0..100`.

  Logs `[State] Name field +n` unless `log: false` is given. Changes that clamp
  to zero are skipped entirely.
  """
  def adjust_character(%__MODULE__{} = transition, character_id, field, delta, opts \\ [])
      when is_integer(delta) do
    unless field in CharacterState.numeric_fields() do
      raise ArgumentError, "#{inspect(field)} is not a numeric character field"
    end

    before = Map.fetch!(character_state(transition, character_id), field)
    value = CharacterState.clamp(before + delta)

    if value == before do
      transition
    else
      state =
        State.update_character_state(transition.state, character_id, &Map.put(&1, field, value))

      %{transition | state: state}
      |> add_trace(:character, character_id, character_id, field, before, value)
      |> maybe_log(
        Keyword.get(opts, :log, true),
        "[State] #{name(transition, character_id)} #{field} #{signed(value - before)}"
      )
    end
  end

  @doc """
  Sets a non-numeric character field such as `:mood` or `:last_active_at`.
  Records a trace entry when the value changes; never logs.
  """
  def set_character(%__MODULE__{} = transition, character_id, field, value) do
    before = Map.fetch!(character_state(transition, character_id), field)

    if before == value do
      transition
    else
      state =
        State.update_character_state(transition.state, character_id, &Map.put(&1, field, value))

      %{transition | state: state}
      |> add_trace(:character, character_id, character_id, field, before, value)
    end
  end

  @doc """
  Adds `delta` to a relationship field, clamped to `-100..100`, and emits a
  `:relationship_changed` output with the applied delta. Pass `log: false` or
  `output: false` for routine background changes.
  """
  def adjust_relationship(%__MODULE__{} = transition, from, to, field, delta, opts \\ [])
      when is_integer(delta) do
    unless field in Relationship.fields() do
      raise ArgumentError, "#{inspect(field)} is not a relationship field"
    end

    before = transition.state |> State.get_relationship(from, to) |> Map.fetch!(field)
    value = Relationship.clamp_value(before + delta)

    if value == before do
      transition
    else
      state = State.update_relationship(transition.state, from, to, &Map.put(&1, field, value))
      applied = value - before

      transition =
        add_trace(
          %{transition | state: state},
          :relationship,
          from,
          {from, to},
          field,
          before,
          value
        )

      if(Keyword.get(opts, :output, true),
        do: emit(transition, Output.relationship_changed(from, to, %{field => applied})),
        else: transition
      )
      |> maybe_log(
        Keyword.get(opts, :log, true),
        "[Relation] #{name(transition, from)} #{field} toward #{name(transition, to)} #{signed(applied)}"
      )
    end
  end

  @doc """
  Stores a memory and emits `:memory_created`. The memory's `created_tick` is
  set to the current clock unless `created_tick:` is given.
  """
  def remember(%__MODULE__{} = transition, %Memory{} = memory, opts \\ []) do
    memory = %{memory | created_tick: Keyword.get(opts, :created_tick, transition.state.clock)}
    state = State.add_memory(transition.state, memory)

    %{transition | state: state}
    |> add_trace(:memory, memory.character_id, memory.id, nil, nil, memory.strength,
      detail: "#{memory.character_id} remembers #{inspect(memory.content)}"
    )
    |> emit(Output.memory_created(memory))
    |> log("[Memory] #{name(transition, memory.character_id)} remembers: \"#{memory.content}\"")
  end

  @doc """
  Updates an existing memory with `fun`. Records a trace entry for `field` when
  given, so decay and sharing remain inspectable.
  """
  def update_memory(%__MODULE__{} = transition, memory_id, fun, opts \\ []) do
    case State.memory(transition.state, memory_id) do
      nil ->
        transition

      memory ->
        updated = fun.(memory)
        state = State.update_memory(transition.state, memory_id, fn _ -> updated end)
        transition = %{transition | state: state}

        case Keyword.get(opts, :field) do
          nil ->
            transition

          field ->
            before = Map.fetch!(memory, field)
            value = Map.fetch!(updated, field)

            if before == value do
              transition
            else
              add_trace(transition, :memory, memory.character_id, memory_id, field, before, value)
            end
        end
    end
  end

  @doc """
  Applies `fun` to every memory in one pass and records a trace entry for
  each memory whose `field` changed. Use this instead of calling
  `update_memory/4` in a loop, which is quadratic in the number of memories.
  """
  def map_memories(%__MODULE__{} = transition, field, fun, opts \\ []) when is_atom(field) do
    on_change = Keyword.get(opts, :on_change, fn transition, _before, _after -> transition end)

    {memories, changes} =
      Enum.map_reduce(transition.state.memories, [], fn memory, changes ->
        updated = fun.(memory)
        before = Map.fetch!(memory, field)
        value = Map.fetch!(updated, field)

        if before == value,
          do: {updated, changes},
          else: {updated, [{memory, updated, before, value} | changes]}
      end)

    transition = %{transition | state: %{transition.state | memories: memories}}

    # Memories are stored newest first, so `changes` is already oldest first,
    # matching the order memories were created in.
    Enum.reduce(changes, transition, fn {memory, updated, before, value}, transition ->
      transition
      |> add_trace(:memory, memory.character_id, memory.id, field, before, value)
      |> on_change.(memory, updated)
    end)
  end

  @doc """
  Removes every memory for which `fun` returns true, tracing each removal.
  Use sparingly: forgotten memories cannot be inspected any more.
  """
  def drop_memories(%__MODULE__{} = transition, fun) do
    {dropped, kept} = Enum.split_with(transition.state.memories, fun)

    transition = %{transition | state: %{transition.state | memories: kept}}

    dropped
    |> Enum.reverse()
    |> Enum.reduce(transition, fn memory, transition ->
      add_trace(transition, :memory, memory.character_id, memory.id, nil, memory.strength, nil,
        detail: "#{memory.character_id} forgot #{inspect(memory.content)}"
      )
    end)
  end

  @doc """
  Emits an output, tagging it with the current event id and rule.
  """
  def emit(%__MODULE__{} = transition, output) do
    output = Map.merge(output, %{event_id: event_id(transition), rule: transition.rule})
    subject = Map.get(output, :character_id) || Map.get(output, :from)

    %{transition | outputs: [output | transition.outputs]}
    |> add_trace(:output, subject, output.type, nil, nil, nil,
      detail: "emitted #{output.type}" <> output_detail(output)
    )
  end

  @doc "Appends a log line."
  def log(%__MODULE__{} = transition, line) do
    %{transition | log: [line | transition.log]}
  end

  @doc """
  Records a rule decision that did not directly change state, and logs it as
  `[Rule] text`.
  """
  def note(%__MODULE__{} = transition, text, opts \\ []) do
    transition
    |> add_trace(:note, Keyword.get(opts, :subject), nil, nil, nil, nil, detail: text)
    |> log("[Rule] #{text}")
  end

  @doc """
  Enqueues a follow-up event. It is validated and processed after the current
  event, with `:cause` pointing at the current event id.
  """
  def enqueue(%__MODULE__{} = transition, %{type: type} = event) do
    event = Map.put(event, :cause, event_id(transition))

    %{transition | follow_ups: [event | transition.follow_ups]}
    |> add_trace(:event, Map.get(event, :from), type, nil, nil, nil, detail: "enqueued #{type}")
  end

  @doc "See `Aethrion.State.cooldown_ready?/3`."
  def cooldown_ready?(%__MODULE__{state: state}, key, hours),
    do: State.cooldown_ready?(state, key, hours)

  @doc "Records that a rate-limited behavior fired now."
  def put_cooldown(%__MODULE__{} = transition, key) do
    %{transition | state: State.put_cooldown(transition.state, key)}
  end

  @doc "Replaces the state directly. Prefer the tracked helpers."
  def put_state(%__MODULE__{} = transition, %State{} = state), do: %{transition | state: state}

  @doc "Id of the event being processed."
  def event_id(%__MODULE__{event: event}), do: Map.get(event, :id)

  @doc "Formats an integer delta with an explicit sign."
  def signed(delta) when delta >= 0, do: "+#{delta}"
  def signed(delta), do: "#{delta}"

  defp add_trace(transition, kind, subject, target, field, before, value, opts \\ []) do
    entry = %Trace{
      event_id: event_id(transition),
      rule: transition.rule,
      kind: kind,
      subject: subject,
      target: target,
      field: field,
      before: before,
      after: value,
      detail: Keyword.get(opts, :detail)
    }

    %{transition | trace: [entry | transition.trace]}
  end

  defp maybe_log(transition, true, line), do: log(transition, line)
  defp maybe_log(transition, false, _line), do: transition

  defp output_detail(%{type: :relationship_changed, from: from, to: to, delta: delta}),
    do: " #{from}->#{to} #{inspect(delta)}"

  defp output_detail(%{type: :memory_created, memory: memory}), do: " #{memory.id}"

  defp output_detail(%{character_id: id, to: to} = output),
    do: " #{id}->#{to}" <> reason_detail(output)

  defp output_detail(%{kind: kind, from: from, to: to}), do: " #{kind} #{from}->#{to}"
  defp output_detail(_output), do: ""

  defp reason_detail(%{reason: reason}), do: " reason=#{reason}"
  defp reason_detail(_output), do: ""
end
