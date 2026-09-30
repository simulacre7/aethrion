defmodule Aethrion.RuntimeServer do
  @moduledoc """
  Supervised stateful wrapper around the deterministic runtime.

  `Aethrion.Runtime.step/3` remains the authoritative simulation core. This
  server adds the long-running concerns around it:

  - **State ownership** - the current `Aethrion.State` lives in the process.
  - **Subscriptions** - processes can `subscribe/1` to receive every dispatched
    step and every expression rendering, as `{:aethrion, tag, payload}`.
  - **History** - the host events dispatched so far, for replay and debugging.
  - **Snapshots** - with `:persistence`, the state is saved after each dispatch
    and restored on start, so a supervised restart resumes where it left off.
  - **Journals** - with `:journal`, every host event is appended to an
    `Aethrion.Journal` and the world is rebuilt by replaying it on start.
  - **Asynchronous expression** - with `:expression`, expressive outputs are
    rendered by an `Aethrion.LLM.Adapter` in supervised tasks. Dispatch never
    waits for a model; slow, failing, or crashing adapters are isolated and the
    deterministic fallback text is delivered instead.

  Subscribers receive:

  - `{:aethrion, server_pid, {:dispatched, %Aethrion.Step{}}}`
  - `{:aethrion, server_pid, {:expressed, output}}` - for each expressive output
    when `:expression` is configured; `output.expression.status` is `:ok` or
    `:fallback`
  """

  use GenServer

  alias Aethrion.{Expression, Output, Pipeline, Runtime, State, Step}

  require Logger

  @type server :: GenServer.server()

  @default_history_limit 500
  @default_expression_timeout 15_000

  @doc """
  Starts a runtime server.

  Options:

  - `:initial_state` - an `Aethrion.State` struct. Defaults to the demo state.
  - `:name` - optional GenServer name.
  - `:pipeline` - an `Aethrion.Pipeline`. Defaults to `Aethrion.Pipeline.default/0`.
  - `:max_depth`, `:max_events` - cascade limits, see `Aethrion.Runtime.dispatch/3`.
    Journal replay uses the same limits.
  - `:history_limit` - how many host events to keep. Defaults to #{@default_history_limit}.
  - `:persistence` - `{adapter, opts}`, for example
    `{Aethrion.Persistence.JsonFile, path: "tmp/world.json"}`. A saved state is
    loaded on start (taking precedence over `:initial_state`) and saved after
    every successful dispatch.
  - `:journal` - path of an `Aethrion.Journal`. If it exists, the world is
    rebuilt by replaying it (taking precedence over `:initial_state`);
    otherwise it is created from the initial state. Every successful dispatch
    appends its host event. Cannot be combined with `:persistence`, and
    `put_state/2` is refused while journaling.
  - `:journal_compact_every` - with `:journal`, compact the journal (see
    `compact_journal/1`) after this many host events, so a long-running world
    starts quickly. A failed compaction is logged and retried after the next
    event; the journal stays valid either way.
  - `:subscribers` - a started `:pg` scope to keep subscribers in, so they
    survive a restart of this server (`Aethrion.World` provides one)
  - `:tag` - what subscriber messages carry as their second element (default:
    this server's pid; `Aethrion.World` uses the world's name)
  - `:expression` - keyword options enabling asynchronous rendering:
    `:adapter` (required), `:adapter_opts`, `:timeout` (ms, default
    #{@default_expression_timeout}), `:task_supervisor` (a `Task.Supervisor`;
    one is started and linked when omitted).
  """
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc """
  Dispatches an event and stores the updated state on success.
  Returns the same shape as `Aethrion.Runtime.dispatch/3`.
  """
  @spec dispatch(server(), Aethrion.Event.t()) ::
          {:ok, State.t(), [map()], [String.t()]} | {:error, Aethrion.Error.t()}
  def dispatch(server, event) do
    case step(server, event) do
      {:ok, %Step{} = step} -> {:ok, step.state, step.outputs, step.log}
      error -> error
    end
  end

  @doc """
  Dispatches an event and returns the full `Aethrion.Step`.
  """
  @spec step(server(), Aethrion.Event.t()) :: {:ok, Step.t()} | {:error, Aethrion.Error.t()}
  def step(server, event) do
    GenServer.call(server, {:step, event})
  end

  @doc "Returns the current runtime state."
  @spec get_state(server()) :: State.t()
  def get_state(server), do: GenServer.call(server, :get_state)

  @doc """
  Replaces the current state, for example after loading a save. History is
  cleared because it no longer describes how the state was reached. A
  journaled server starts its journal over from the new state (the events
  before it are gone, as after compaction); a snapshotting one saves it.
  """
  @spec put_state(server(), State.t()) :: :ok | {:error, Aethrion.Error.t()}
  def put_state(server, %State{} = state), do: GenServer.call(server, {:put_state, state})

  @doc """
  Compacts the server's journal: replaces it with one that starts from the
  current state (see `Aethrion.Journal.compact/2`). Events are serialized with
  dispatches, so none is lost. Returns `{:error, %Aethrion.Error{code:
  :invalid_options}}` when the server does not journal.
  """
  @spec compact_journal(server()) :: :ok | {:error, Aethrion.Error.t()}
  def compact_journal(server), do: GenServer.call(server, :compact_journal)

  @doc "Host events dispatched so far, oldest first, with their assigned ids."
  @spec history(server()) :: [Aethrion.Event.t()]
  def history(server), do: GenServer.call(server, :history)

  @doc "Subscribes `pid` (default: the caller) to dispatch and expression messages."
  @spec subscribe(server(), pid()) :: :ok
  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @doc "Removes a subscription."
  @spec unsubscribe(server(), pid()) :: :ok
  def unsubscribe(server, pid \\ self()), do: GenServer.call(server, {:unsubscribe, pid})

  ## Server

  @impl true
  def init(opts) do
    with :ok <- check_storage(opts),
         {:ok, world, journaled} <- initial_world(opts),
         {:ok, expression} <- expression_config(Keyword.get(opts, :expression)) do
      {:ok,
       %{
         world: world,
         pipeline: Keyword.get(opts, :pipeline, Pipeline.default()),
         limits: Keyword.take(opts, [:max_depth, :max_events]),
         persistence: Keyword.get(opts, :persistence),
         journal: Keyword.get(opts, :journal),
         compact_every: Keyword.get(opts, :journal_compact_every),
         # Events already in the journal count toward the next compaction.
         since_compaction: journaled,
         history: [],
         history_limit: Keyword.get(opts, :history_limit, @default_history_limit),
         subscribers: %{},
         # A :pg scope holding subscribers outside this process, so they
         # survive a restart (Aethrion.World provides one).
         pg: Keyword.get(opts, :subscribers),
         tag: Keyword.get(opts, :tag, self()),
         expression: expression,
         pending: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:step, event}, _from, server) do
    case safe_step(server, event) do
      {:ok, %Step{} = step} ->
        # The journal is written before the state is committed, so a failed
        # write rejects the event instead of leaving a journal that no longer
        # replays to the live world.
        case journal(server, step.event) do
          :ok ->
            server =
              %{server | world: step.state}
              |> maybe_compact()
              |> record_history(step.event)
              |> persist()
              |> broadcast({:dispatched, step})
              |> render_async(step.outputs)

            {:reply, {:ok, step}, server}

          {:error, error} ->
            {:reply, {:error, error}, server}
        end

      {:error, error} ->
        {:reply, {:error, error}, server}
    end
  end

  def handle_call(:get_state, _from, server), do: {:reply, server.world, server}

  # A journaled world starts its journal over from the new state.
  def handle_call({:put_state, state}, _from, %{journal: path} = server) when is_binary(path) do
    case Aethrion.Journal.rewrite(path, state) do
      :ok -> {:reply, :ok, %{server | world: state, history: [], since_compaction: 0}}
      error -> {:reply, error, server}
    end
  end

  def handle_call({:put_state, state}, _from, server) do
    {:reply, :ok, persist(%{server | world: state, history: []})}
  end

  def handle_call(:history, _from, server), do: {:reply, Enum.reverse(server.history), server}

  def handle_call(:compact_journal, _from, %{journal: nil} = server) do
    error = Aethrion.Error.new(:invalid_options, "this runtime server has no :journal")
    {:reply, {:error, error}, server}
  end

  def handle_call(:compact_journal, _from, %{journal: path} = server) do
    case Aethrion.Journal.rewrite(path, server.world) do
      :ok -> {:reply, :ok, %{server | since_compaction: 0}}
      error -> {:reply, error, server}
    end
  end

  def handle_call({:subscribe, pid}, _from, %{pg: scope} = server) when not is_nil(scope) do
    unless pid in :pg.get_local_members(scope, :subscribers),
      do: :ok = :pg.join(scope, :subscribers, pid)

    {:reply, :ok, server}
  end

  def handle_call({:subscribe, pid}, _from, server) do
    if Map.has_key?(server.subscribers, pid) do
      {:reply, :ok, server}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(server.subscribers[pid], ref)}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, %{pg: scope} = server) when not is_nil(scope) do
    _left_or_not_joined = :pg.leave(scope, :subscribers, pid)
    {:reply, :ok, server}
  end

  def handle_call({:unsubscribe, pid}, _from, server) do
    case Map.pop(server.subscribers, pid) do
      {nil, _subscribers} ->
        {:reply, :ok, server}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{server | subscribers: subscribers}}
    end
  end

  @impl true
  # A rendering task finished.
  def handle_info({ref, rendered}, server) when is_map_key(server.pending, ref) do
    Process.demonitor(ref, [:flush])
    {{_output, timer, _pid}, pending} = Map.pop(server.pending, ref)
    Process.cancel_timer(timer)

    {:noreply, broadcast(%{server | pending: pending}, {:expressed, rendered})}
  end

  # A rendering task crashed or was killed.
  def handle_info({:DOWN, ref, :process, _pid, reason}, server)
      when is_map_key(server.pending, ref) do
    {{output, timer, _pid}, pending} = Map.pop(server.pending, ref)
    Process.cancel_timer(timer)
    rendered = fallback(output, server, {:crashed, reason})

    {:noreply, broadcast(%{server | pending: pending}, {:expressed, rendered})}
  end

  # A subscriber went away.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, server) do
    {:noreply, %{server | subscribers: Map.delete(server.subscribers, pid)}}
  end

  def handle_info({:expression_timeout, ref}, server) when is_map_key(server.pending, ref) do
    {{output, _timer, pid}, pending} = Map.pop(server.pending, ref)
    Process.demonitor(ref, [:flush])
    Task.Supervisor.terminate_child(server.expression.task_supervisor, pid)
    rendered = fallback(output, server, :timeout)

    {:noreply, broadcast(%{server | pending: pending}, {:expressed, rendered})}
  end

  def handle_info({:expression_timeout, _ref}, server), do: {:noreply, server}

  def handle_info(message, server) do
    Logger.debug("Aethrion.RuntimeServer ignored message: #{inspect(message)}")
    {:noreply, server}
  end

  ## Helpers

  # A crashing rule (for example a custom rule with a bug) must not take down
  # the world and its in-memory state. The event is rejected instead.
  defp safe_step(server, event) do
    Runtime.step(server.world, event, [pipeline: server.pipeline] ++ server.limits)
  rescue
    exception ->
      Logger.error(
        "Aethrion.RuntimeServer rejected an event after a rule raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error,
       %Aethrion.Error{
         code: :rule_failed,
         message: "a rule raised while processing the event: #{Exception.message(exception)}",
         details: %{exception: exception.__struct__}
       }}
  end

  defp check_storage(opts) do
    every = Keyword.get(opts, :journal_compact_every)

    cond do
      Keyword.get(opts, :journal) && Keyword.get(opts, :persistence) ->
        {:error,
         Aethrion.Error.new(:invalid_options, "use either :journal or :persistence, not both")}

      not is_nil(every) and not (is_integer(every) and every > 0) ->
        {:error,
         Aethrion.Error.new(
           :invalid_options,
           ":journal_compact_every must be a positive integer, got: #{inspect(every)}",
           %{field: :journal_compact_every}
         )}

      not is_nil(every) and is_nil(Keyword.get(opts, :journal)) ->
        {:error,
         Aethrion.Error.new(:invalid_options, ":journal_compact_every needs :journal", %{
           field: :journal_compact_every
         })}

      true ->
        :ok
    end
  end

  defp initial_world(opts) do
    fallback = Keyword.get(opts, :initial_state, Runtime.demo_state())
    pipeline = Keyword.get(opts, :pipeline, Pipeline.default())

    case Keyword.get(opts, :journal) do
      nil ->
        with {:ok, state} <- snapshot_world(opts, fallback, pipeline), do: {:ok, state, 0}

      path ->
        journal_world(
          path,
          fallback,
          [pipeline: pipeline, repair: true] ++ Keyword.take(opts, [:max_depth, :max_events])
        )
    end
  end

  defp journal_world(path, fallback, replay_opts) do
    if File.exists?(path) do
      case check_then_replay(path, replay_opts) do
        {:ok, state, steps} ->
          {:ok, state, length(steps)}

        {:error, error} ->
          Logger.error("Aethrion.RuntimeServer could not replay its journal: #{error.message}")
          {:error, error}
      end
    else
      with {:ok, state} <- validate_state(fallback),
           :ok <- Aethrion.Journal.create(path, state) do
        {:ok, state, 0}
      end
    end
  end

  # Refuse a journal whose tuning the pipeline cannot hold: starting anyway
  # would drop that tuning, and the next compaction would lose it for good.
  defp check_then_replay(path, replay_opts) do
    with :ok <- Aethrion.Journal.check_tuning(path, Keyword.fetch!(replay_opts, :pipeline)) do
      Aethrion.Journal.replay(path, replay_opts)
    end
  end

  defp snapshot_world(opts, fallback, pipeline) do
    case Keyword.get(opts, :persistence) do
      {adapter, persistence_opts} ->
        load_opts = Keyword.put_new(persistence_opts, :pipeline, pipeline)

        case adapter.load(load_opts) do
          {:ok, %State{} = state} ->
            {:ok, state}

          # No snapshot yet: start fresh.
          {:error, %Aethrion.Error{code: :not_found}} ->
            validate_state(fallback)

          # A snapshot exists but cannot be read. Refuse to start rather than
          # overwrite it with a fresh world on the next dispatch.
          {:error, reason} ->
            Logger.error(
              "Aethrion.RuntimeServer could not restore its snapshot: #{inspect(reason)}"
            )

            {:error,
             Aethrion.Error.new(:invalid_snapshot, "the saved snapshot cannot be loaded", %{
               error: reason
             })}
        end

      nil ->
        validate_state(fallback)
    end
  end

  defp validate_state(%State{} = state), do: {:ok, state}

  defp validate_state(other) do
    {:error,
     Aethrion.Error.new(:invalid_state, "initial state must be an Aethrion.State", %{
       state: other
     })}
  end

  defp expression_config(nil), do: {:ok, nil}

  defp expression_config(opts) when is_list(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    supervisor =
      case Keyword.fetch(opts, :task_supervisor) do
        {:ok, supervisor} ->
          supervisor

        :error ->
          {:ok, supervisor} = Task.Supervisor.start_link()
          supervisor
      end

    {:ok,
     %{
       adapter: adapter,
       adapter_opts: Keyword.get(opts, :adapter_opts, []),
       timeout: Keyword.get(opts, :timeout, @default_expression_timeout),
       task_supervisor: supervisor
     }}
  end

  defp record_history(server, event) do
    %{server | history: Enum.take([event | server.history], server.history_limit)}
  end

  defp persist(%{persistence: nil} = server), do: server

  defp persist(%{persistence: {adapter, opts}} = server) do
    case adapter.save(server.world, opts) do
      :ok ->
        server

      {:error, reason} ->
        Logger.warning("Aethrion.RuntimeServer could not save state: #{inspect(reason)}")
        server
    end
  end

  defp maybe_compact(%{journal: path, compact_every: every} = server)
       when is_binary(path) and is_integer(every) and every > 0 do
    count = server.since_compaction + 1

    if count >= every do
      case Aethrion.Journal.rewrite(path, server.world) do
        :ok ->
          %{server | since_compaction: 0}

        {:error, error} ->
          Logger.warning("Aethrion.RuntimeServer could not compact its journal: #{error.message}")
          %{server | since_compaction: count}
      end
    else
      %{server | since_compaction: count}
    end
  end

  defp maybe_compact(server), do: server

  defp journal(%{journal: nil}, _event), do: :ok

  defp journal(%{journal: path} = server, event) do
    case Aethrion.Journal.append(path, event, pipeline: server.pipeline) do
      :ok ->
        :ok

      # The event itself cannot be stored faithfully: reject it.
      {:error, %Aethrion.Error{code: :invalid_event} = error} ->
        {:error, error}

      {:error, %Aethrion.Error{} = error} ->
        Logger.error("Aethrion.RuntimeServer could not append to its journal: #{error.message}")

        {:error,
         Aethrion.Error.new(
           :journal_failed,
           "could not append to the journal: #{error.message}",
           %{
             error: error
           }
         )}
    end
  end

  defp broadcast(server, payload) do
    subscribers =
      case server.pg do
        nil -> Map.keys(server.subscribers)
        scope -> :pg.get_local_members(scope, :subscribers)
      end

    for pid <- subscribers, do: send(pid, {:aethrion, server.tag, payload})
    server
  end

  defp render_async(%{expression: nil} = server, _outputs), do: server

  defp render_async(server, outputs) do
    config = server.expression

    outputs
    |> Enum.filter(&Output.expressive?/1)
    |> Enum.reduce(server, fn output, server ->
      task =
        Task.Supervisor.async_nolink(config.task_supervisor, fn ->
          Expression.render_output(output,
            adapter: config.adapter,
            adapter_opts: config.adapter_opts
          )
        end)

      timer = Process.send_after(self(), {:expression_timeout, task.ref}, config.timeout)
      put_in(server.pending[task.ref], {output, timer, task.pid})
    end)
  end

  defp fallback(output, server, reason) do
    Map.put(output, :expression, %{
      status: :fallback,
      adapter: server.expression.adapter,
      reason: reason
    })
  end
end
