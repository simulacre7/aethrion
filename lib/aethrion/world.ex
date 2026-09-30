defmodule Aethrion.World do
  @moduledoc """
  A supervised, long-running world: runtime server, expression task supervisor,
  and optional scheduler under one supervisor.

      children = [
        {Aethrion.World,
         name: :garden,
         initial_state: Aethrion.Runtime.demo_state(),
         persistence: {Aethrion.Persistence.JsonFile, path: "tmp/garden.json"},
         scheduler: [interval_ms: 60_000, tick_hours: 1],
         expression: [adapter: Aethrion.LLM.OpenAICompatible, timeout: 10_000]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

      Aethrion.World.subscribe(:garden)
      Aethrion.World.dispatch(:garden, Aethrion.Event.message_sent("user", "yuna", "hi"))

  The children are started in this order under a `:rest_for_one` strategy:

  1. `Task.Supervisor` for expression rendering
  2. `Aethrion.RuntimeServer`
  3. `Aethrion.Scheduler` (when `:scheduler` is given)

  If the runtime server crashes it restarts from the last persisted snapshot
  (when `:persistence` is given), and the scheduler restarts after it. A crash
  inside an expression adapter never reaches the runtime.
  """

  use Supervisor

  alias Aethrion.{Runtime, RuntimeServer, Scheduler}

  @doc """
  Starts a world.

  Options:

  - `:name` (required) - an atom identifying the world
  - `:initial_state` - the starting `Aethrion.State` (default: demo state)
  - `:pipeline` - an `Aethrion.Pipeline`
  - `:persistence` - `{adapter, opts}`, see `Aethrion.RuntimeServer`
  - `:journal` - path of an `Aethrion.Journal` to rebuild from and append to
  - `:journal_compact_every` - compact the journal after this many events
  - `:scheduler` - keyword options for `Aethrion.Scheduler` (without `:runtime`)
  - `:expression` - keyword options for asynchronous rendering (without
    `:task_supervisor`), see `Aethrion.RuntimeServer`
  - `:history_limit`
  - `:max_depth`, `:max_events` - cascade limits, see `Aethrion.Runtime.dispatch/3`
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(name))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    runtime_opts =
      [
        name: runtime(name),
        initial_state: Keyword.get(opts, :initial_state, Runtime.demo_state())
      ] ++
        Keyword.take(opts, [
          :pipeline,
          :persistence,
          :journal,
          :journal_compact_every,
          :history_limit,
          :max_depth,
          :max_events
        ]) ++
        expression_opts(name, Keyword.get(opts, :expression))

    scheduler =
      case Keyword.get(opts, :scheduler) do
        nil ->
          []

        scheduler_opts ->
          [{Scheduler, [runtime: runtime(name), name: scheduler(name)] ++ scheduler_opts}]
      end

    children =
      [
        {Task.Supervisor, name: task_supervisor(name)},
        {RuntimeServer, runtime_opts}
      ] ++ scheduler

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Registered name of the world's runtime server."
  @spec runtime(atom()) :: module()
  def runtime(name), do: Module.concat([__MODULE__, to_string(name), "Runtime"])

  @doc "Registered name of the world's scheduler."
  @spec scheduler(atom()) :: module()
  def scheduler(name), do: Module.concat([__MODULE__, to_string(name), "Scheduler"])

  @doc "Registered name of the world's expression task supervisor."
  @spec task_supervisor(atom()) :: module()
  def task_supervisor(name), do: Module.concat([__MODULE__, to_string(name), "TaskSupervisor"])

  @doc false
  @spec supervisor_name(atom()) :: module()
  def supervisor_name(name), do: Module.concat([__MODULE__, to_string(name)])

  @doc "See `Aethrion.RuntimeServer.dispatch/2`."
  @spec dispatch(atom(), Aethrion.Event.t()) ::
          {:ok, State.t(), [map()], [String.t()]} | {:error, Aethrion.Error.t()}
  def dispatch(name, event), do: RuntimeServer.dispatch(runtime(name), event)

  @doc "See `Aethrion.RuntimeServer.step/2`."
  @spec step(atom(), Aethrion.Event.t()) ::
          {:ok, Aethrion.Step.t()} | {:error, Aethrion.Error.t()}
  def step(name, event), do: RuntimeServer.step(runtime(name), event)

  @doc "Current state of the world."
  @spec state(atom()) :: Aethrion.State.t()
  def state(name), do: RuntimeServer.get_state(runtime(name))

  @doc "Host events dispatched so far."
  @spec history(atom()) :: [Aethrion.Event.t()]
  def history(name), do: RuntimeServer.history(runtime(name))

  @doc "See `Aethrion.RuntimeServer.subscribe/2`."
  @spec subscribe(atom(), pid()) :: :ok
  def subscribe(name, pid \\ self()), do: RuntimeServer.subscribe(runtime(name), pid)

  @doc "See `Aethrion.RuntimeServer.unsubscribe/2`."
  @spec unsubscribe(atom(), pid()) :: :ok
  def unsubscribe(name, pid \\ self()), do: RuntimeServer.unsubscribe(runtime(name), pid)

  @doc "See `Aethrion.RuntimeServer.put_state/2`."
  @spec put_state(atom(), Aethrion.State.t()) :: :ok | {:error, Aethrion.Error.t()}
  def put_state(name, state), do: RuntimeServer.put_state(runtime(name), state)

  @doc "Compacts the world's journal. See `Aethrion.RuntimeServer.compact_journal/1`."
  @spec compact_journal(atom()) :: :ok | {:error, Aethrion.Error.t()}
  def compact_journal(name), do: RuntimeServer.compact_journal(runtime(name))

  defp expression_opts(_name, nil), do: []

  defp expression_opts(name, opts) do
    [expression: Keyword.put(opts, :task_supervisor, task_supervisor(name))]
  end
end
