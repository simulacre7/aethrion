defmodule Aethrion.Runtime do
  @moduledoc """
  Deterministic runtime entry point.

  `dispatch/3` validates an event, runs it through the rule pipeline, then
  processes any follow-up events the rules enqueued (a character confiding in a
  friend, a friend offering comfort) until the cascade settles:

  ```txt
  host event
    -> validate -> event rules -> reactive rules
    -> follow-up events (validated, same pipeline, breadth-first)
    -> {:ok, state, outputs, log}
  ```

  The same state and event always produce the same result. Nothing here
  performs I/O or calls a model.
  """

  alias Aethrion.{Error, Pipeline, State, Step, Transition, Validator}

  @max_depth 4
  @max_events 32
  @events_per_character 4

  @doc "The built-in Mina / Yuna / Haru world. See `Aethrion.State.demo/0`."
  def demo_state, do: State.demo()

  @doc """
  Dispatches an event through the deterministic runtime.

  Returns `{:ok, state, outputs, log}` on success or `{:error, error}` when the
  input is invalid. Invalid events never change state.

  Options:

  - `:pipeline` - an `Aethrion.Pipeline` (default `Aethrion.Pipeline.default/0`)
  - `:max_depth` - maximum follow-up generations (default #{@max_depth})
  - `:max_events` - maximum events processed per dispatch (default: the larger
    of #{@max_events} and #{@events_per_character} per character, so cascades scale with the world)
  """
  @spec dispatch(State.t(), Aethrion.Event.t(), keyword()) ::
          {:ok, State.t(), [map()], [String.t()]} | {:error, Error.t()}
  def dispatch(state, event, opts \\ []) do
    case step(state, event, opts) do
      {:ok, %Step{} = step} -> {:ok, step.state, step.outputs, step.log}
      {:error, %Error{}} = error -> error
    end
  end

  @doc """
  Like `dispatch/3`, but returns an `Aethrion.Step` with the full trace and every
  processed event, including follow-ups.
  """
  @spec step(State.t(), Aethrion.Event.t(), keyword()) :: {:ok, Step.t()} | {:error, Error.t()}
  def step(state, event, opts \\ []) do
    pipeline = Keyword.get(opts, :pipeline, Pipeline.default())
    event = Aethrion.Event.normalize(event)

    with :ok <- Validator.validate_dispatch(state, event, pipeline) do
      limits = %{
        max_depth: Keyword.get(opts, :max_depth, @max_depth),
        max_events: Keyword.get(opts, :max_events, default_max_events(state))
      }

      {state, root} = assign_id(state, Map.delete(event, :cause))
      acc = %Step{state: state, event: root}

      {:ok, run_queue(:queue.from_list([{root, 0}]), acc, pipeline, limits) |> finish()}
    end
  end

  @doc """
  Dispatches `events` in order, stopping at the first invalid event.

  Returns `{:ok, final_state, steps}`, or `{:error, error}` where
  `error.details` includes the `:index` of the rejected event and the `:steps`
  completed before it.
  """
  @spec run(State.t(), [Aethrion.Event.t()], keyword()) ::
          {:ok, State.t(), [Step.t()]} | {:error, Error.t()}
  def run(state, events, opts \\ []) when is_list(events) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state, []}, fn {event, index}, {:ok, state, steps} ->
      case step(state, event, opts) do
        {:ok, step} ->
          {:cont, {:ok, step.state, [step | steps]}}

        {:error, error} ->
          {:halt, {:error, Error.add_details(error, %{index: index, steps: Enum.reverse(steps)})}}
      end
    end)
    |> case do
      {:ok, state, steps} -> {:ok, state, Enum.reverse(steps)}
      error -> error
    end
  end

  @doc false
  def default_max_events(%State{} = state),
    do: max(@max_events, @events_per_character * map_size(state.characters))

  defp run_queue(queue, acc, pipeline, limits) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        acc

      {{:value, {event, depth}}, queue} ->
        {acc, follow_ups} = process(acc, event, depth, pipeline)

        {queue, acc} =
          Enum.reduce(follow_ups, {queue, acc}, fn follow_up, {queue, acc} ->
            enqueue_follow_up(queue, acc, follow_up, depth + 1, pipeline, limits)
          end)

        run_queue(queue, acc, pipeline, limits)
    end
  end

  defp process(acc, event, depth, pipeline) do
    acc =
      if depth > 0 do
        names = &State.name(acc.state, &1)
        add_log(acc, ["[Event] " <> Aethrion.Event.describe(event, names)])
      else
        acc
      end

    result =
      pipeline
      |> Pipeline.rules_for(event.type)
      |> Enum.reduce(Transition.new(acc.state, event), fn rule, transition ->
        transition |> Transition.put_rule(rule) |> rule.apply()
      end)
      |> Transition.finalize()

    acc = %{
      acc
      | state: result.state,
        events: [event | acc.events],
        outputs: Enum.reverse(result.outputs, acc.outputs),
        trace: Enum.reverse(result.trace, acc.trace)
    }

    {add_log(acc, result.log), result.follow_ups}
  end

  defp enqueue_follow_up(queue, acc, event, depth, pipeline, limits) do
    queued = :queue.len(queue)

    cond do
      depth > limits.max_depth ->
        {queue, drop(acc, event, "cascade depth limit #{limits.max_depth} reached")}

      length(acc.events) + queued >= limits.max_events ->
        {queue, drop(acc, event, "cascade event limit #{limits.max_events} reached")}

      true ->
        case Validator.validate_dispatch(acc.state, Aethrion.Event.normalize(event), pipeline) do
          :ok ->
            {state, event} = assign_id(acc.state, Aethrion.Event.normalize(event))
            {:queue.in({event, depth}, queue), %{acc | state: state}}

          {:error, %Error{message: message}} ->
            {queue, drop(acc, event, message)}
        end
    end
  end

  defp drop(acc, event, reason) do
    entry = %Aethrion.Trace{
      event_id: Map.get(event, :cause),
      kind: :event,
      subject: Map.get(event, :from),
      target: event.type,
      detail: "dropped follow-up #{event.type}: #{reason}"
    }

    %{acc | trace: [entry | acc.trace]}
    |> add_log(["[Cascade] dropped #{event.type}: #{reason}"])
  end

  defp assign_id(%State{} = state, event) do
    seq = state.seq + 1
    {%{state | seq: seq}, Map.put(event, :id, "e#{seq}")}
  end

  defp add_log(acc, lines), do: %{acc | log: Enum.reverse(lines, acc.log)}

  defp finish(%Step{} = acc) do
    %{
      acc
      | events: Enum.reverse(acc.events),
        outputs: Enum.reverse(acc.outputs),
        log: Enum.reverse(acc.log),
        trace: Enum.reverse(acc.trace)
    }
  end
end
