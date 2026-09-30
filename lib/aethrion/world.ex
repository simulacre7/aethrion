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

  1. a `:pg` scope holding subscribers
  2. `Task.Supervisor` for expression rendering
  3. `Aethrion.RuntimeServer`
  4. `Aethrion.Scheduler` (when `:scheduler` is given)

  If the runtime server crashes it restarts from the last persisted snapshot
  or journal (when `:persistence` or `:journal` is given), and the scheduler
  restarts after it; subscribers stay subscribed. A crash inside an
  expression adapter never reaches the runtime.

  Subscribers receive `{:aethrion, world_name, {:dispatched, step}}` and, with
  `:expression`, `{:aethrion, world_name, {:expressed, output}}`, so one
  process can listen to many worlds.
  """

  use Supervisor

  alias Aethrion.{Runtime, RuntimeServer, Scheduler}

  @doc """
  Starts a world.

  Options:

  - `:name` (required) - an atom identifying the world. Each world
    registers a few processes under names derived from it, and atoms are
    never freed, so for an open-ended number of users keep worlds for active
    users only rather than one per user ever seen.
  - `:initial_state` - the starting `Aethrion.State` (default: demo state);
    ignored when the journal or snapshot already exists, which wins. To load
    a save into a running world, use `put_state/2`.
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
        initial_state: Keyword.get(opts, :initial_state, Runtime.demo_state()),
        subscribers: subscribers(name),
        tag: name
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
        %{id: :subscribers, start: {:pg, :start_link, [subscribers(name)]}},
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

  @doc false
  # The :pg scope holding subscribers, so they outlive a runtime restart.
  def subscribers(name), do: Module.concat([__MODULE__, to_string(name), "Subscribers"])

  @doc "Registered name of the world's expression task supervisor."
  @spec task_supervisor(atom()) :: module()
  def task_supervisor(name), do: Module.concat([__MODULE__, to_string(name), "TaskSupervisor"])

  @doc false
  @spec supervisor_name(atom()) :: module()
  def supervisor_name(name), do: Module.concat([__MODULE__, to_string(name)])

  @doc """
  The world's supervisor pid, or `nil` when it is not running: for example to
  stop a world started under a `DynamicSupervisor` with
  `DynamicSupervisor.terminate_child/2`.
  """
  @spec whereis(atom()) :: pid() | nil
  def whereis(name), do: Process.whereis(supervisor_name(name))

  @doc "See `Aethrion.RuntimeServer.dispatch/2`."
  @spec dispatch(atom(), Aethrion.Event.t()) ::
          {:ok, Aethrion.State.t(), [map()], [String.t()]} | {:error, Aethrion.Error.t()}
  def dispatch(name, event),
    do: running(name, fn -> RuntimeServer.dispatch(runtime(name), event) end)

  @doc "See `Aethrion.RuntimeServer.step/2`."
  @spec step(atom(), Aethrion.Event.t()) ::
          {:ok, Aethrion.Step.t()} | {:error, Aethrion.Error.t()}
  def step(name, event), do: running(name, fn -> RuntimeServer.step(runtime(name), event) end)

  # A world that is not running is an error value, not an exit.
  defp running(name, call) do
    call.()
  catch
    :exit, {:noproc, _call} ->
      {:error,
       Aethrion.Error.new(:world_not_running, "no world named #{inspect(name)} is running", %{
         world: name
       })}
  end

  @doc "Current state of the world."
  @spec get_state(atom()) :: Aethrion.State.t()
  def get_state(name), do: RuntimeServer.get_state(runtime(name))

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
