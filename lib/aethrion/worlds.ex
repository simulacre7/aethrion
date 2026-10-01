defmodule Aethrion.Worlds do
  @moduledoc """
  Many worlds under one supervisor, one per key: a world per user in a chat
  app, per save slot or per room in a game.

  Keys are any term (a user id string, `{:room, 42}`), never turned into
  atoms, so the number of worlds is not limited by the atom table. Worlds
  start on first use from a function of the key, and with `:idle_after` stop
  again when nobody has used them for a while, so only active worlds take
  memory:

      children = [
        {Aethrion.Worlds,
         name: MyApp.Worlds,
         idle_after: :timer.minutes(30),
         world: fn user_id ->
           [
             initial_state: MyApp.Cast.starting_state(),
             journal: "data/worlds/\#{Aethrion.Worlds.file_name(user_id)}.jsonl",
             journal_compact_every: 500,
             expression: [adapter: Aethrion.LLM.Anthropic, timeout: 10_000]
           ]
         end}
      ]

      Aethrion.Worlds.subscribe(MyApp.Worlds, user_id)
      Aethrion.Worlds.dispatch(MyApp.Worlds, user_id, event)

  Subscribers receive `{:aethrion, {manager, key}, payload}` with the same
  payloads as `Aethrion.World`, and stay subscribed while the world is
  stopped and started again.

  Options:

  - `:name` (required) - an atom naming this set of worlds
  - `:world` (required) - a function from a key to world options: those of
    `Aethrion.World` except `:name` (`:initial_state`, `:journal`,
    `:persistence`, `:pipeline`, `:scheduler`, `:expression`, ...)
  - `:idle_after` - stop a world that has not been used (dispatched to,
    read, or written) for this many milliseconds. Its options must include
    `:journal` or `:persistence`, so it comes back as it was.

  A world that crashes restarts from its journal or snapshot, like an
  `Aethrion.World`.
  """

  use Supervisor

  alias Aethrion.{Error, Event, RuntimeServer, Scheduler, State}

  @world_options [
    :initial_state,
    :pipeline,
    :persistence,
    :journal,
    :journal_compact_every,
    :scheduler,
    :expression,
    :history_limit,
    :max_depth,
    :max_events,
    :hibernate_after
  ]

  @type key :: term()

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts a set of worlds. See the module documentation for options."
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    factory = Keyword.fetch!(opts, :world)

    unless is_function(factory, 1),
      do: raise(ArgumentError, ":world must be a function of one argument (the key)")

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    children = [
      {Registry, keys: :unique, name: registry(name)},
      %{id: :subscribers, start: {:pg, :start_link, [subscribers(name)]}},
      {DynamicSupervisor, name: worlds_supervisor(name), strategy: :one_for_one},
      {__MODULE__.Janitor,
       manager: name,
       world: Keyword.fetch!(opts, :world),
       idle_after: Keyword.get(opts, :idle_after)}
    ]

    # A janitor crash leaves the worlds alone; losing the registry restarts them.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  ## Using a world

  @doc """
  Dispatches `event` to the world for `key`, starting it if needed. See
  `Aethrion.RuntimeServer.dispatch/2`.
  """
  @spec dispatch(atom(), key(), Event.t()) ::
          {:ok, State.t(), [map()], [String.t()]} | {:error, Error.t()}
  def dispatch(manager, key, event),
    do: with_world(manager, key, &RuntimeServer.dispatch(&1, event))

  @doc "Like `dispatch/3`, returning the `Aethrion.Step`."
  @spec step(atom(), key(), Event.t()) :: {:ok, Aethrion.Step.t()} | {:error, Error.t()}
  def step(manager, key, event), do: with_world(manager, key, &RuntimeServer.step(&1, event))

  @doc "The current state of the world for `key`, starting it if needed."
  @spec get_state(atom(), key()) :: {:ok, State.t()} | {:error, Error.t()}
  def get_state(manager, key),
    do: with_world(manager, key, &{:ok, RuntimeServer.get_state(&1)})

  @doc """
  The state of the world for `key` without creating it: a world that has never
  been used (its `:journal` does not exist yet) is read from its options, so
  reads alone do not start worlds or write files. Otherwise like `get_state/2`.
  """
  @spec peek_state(atom(), key()) :: {:ok, State.t()} | {:error, Error.t()}
  def peek_state(manager, key) do
    with nil <- whereis(manager, key),
         {:ok, opts} <- __MODULE__.Janitor.world_options(manager, key),
         journal when is_binary(journal) <- Keyword.get(opts, :journal),
         false <- File.exists?(journal) do
      {:ok, Keyword.get(opts, :initial_state, Aethrion.Runtime.demo_state())}
    else
      {:error, %Error{}} = error -> error
      _running_or_stored -> get_state(manager, key)
    end
  end

  @doc "Replaces the state of the world for `key`. See `Aethrion.RuntimeServer.put_state/2`."
  @spec put_state(atom(), key(), State.t()) :: :ok | {:error, Error.t()}
  def put_state(manager, key, %State{} = state),
    do: with_world(manager, key, &RuntimeServer.put_state(&1, state))

  @doc """
  Subscribes `pid` to the world for `key`, whether or not it is running; the
  subscription lasts while the world stops and starts again.
  """
  @spec subscribe(atom(), key(), pid()) :: :ok
  def subscribe(manager, key, pid \\ self()) do
    scope = subscribers(manager)
    group = group(key)
    unless pid in :pg.get_local_members(scope, group), do: :ok = :pg.join(scope, group, pid)
    :ok
  end

  @doc "Unsubscribes `pid` from the world for `key`."
  @spec unsubscribe(atom(), key(), pid()) :: :ok
  def unsubscribe(manager, key, pid \\ self()) do
    _left_or_not_joined = :pg.leave(subscribers(manager), group(key), pid)
    :ok
  end

  @doc """
  Starts the world for `key` if it is not running. Returns the world's
  supervisor pid.
  """
  @spec start(atom(), key()) :: {:ok, pid()} | {:error, Error.t()}
  def start(manager, key) do
    case whereis(manager, key) do
      nil -> start_world(manager, key)
      pid -> {:ok, pid}
    end
  end

  @doc "Stops the world for `key`, if it is running. Its subscribers stay subscribed."
  @spec stop(atom(), key()) :: :ok
  def stop(manager, key) do
    __MODULE__.Janitor.forget(manager, key)

    case whereis(manager, key) do
      nil -> :ok
      pid -> stop_pid(manager, pid)
    end
  end

  @doc "The world for `key`'s supervisor pid, or `nil` when it is not running."
  @spec whereis(atom(), key()) :: pid() | nil
  # A registry forgets a stopped process a moment after it exits; until then
  # its pid is not handed out.
  def whereis(manager, key) do
    case Registry.lookup(registry(manager), {key, :world}) do
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "Keys of the worlds running now."
  @spec running(atom()) :: [key()]
  def running(manager) do
    Registry.select(registry(manager), [{{{:"$1", :world}, :_, :_}, [], [:"$1"]}])
  end

  @doc """
  A file name for `key`, safe to put under a directory and distinct for
  every key: readable characters of the key plus a hash of all of it, so
  `"alice:1"`, `"alice@1"`, and `"Alice_1"` never share a journal, even on a
  case-insensitive file system, and nothing a user sends can reach outside
  the directory.

      journal: Path.join("data/worlds", Aethrion.Worlds.file_name(user_id) <> ".jsonl")
  """
  @spec file_name(key()) :: String.t()
  def file_name(key) do
    text = if is_binary(key), do: key, else: inspect(key)

    readable =
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_\-]+/, "_")
      |> String.slice(0, 40)

    hash = :crypto.hash(:sha256, :erlang.term_to_binary(key)) |> Base.encode16(case: :lower)
    readable <> "-" <> binary_part(hash, 0, 16)
  end

  @doc false
  def via(manager, key, role), do: {:via, Registry, {registry(manager), {key, role}}}

  ## Helpers

  # A world stopped (idle, or by someone else) before the call reached it is
  # started again; the registry may take a moment to forget the old one.
  @attempts 3

  defp with_world(manager, key, call, attempt \\ 1) do
    with {:ok, _pid} <- start(manager, key) do
      __MODULE__.Janitor.touch(manager, key)

      try do
        call.(via(manager, key, :runtime))
      catch
        # Only a call that never reached the world is retried: one cut
        # short by a stop may already have been applied.
        :exit, {:noproc, _call} when attempt < @attempts ->
          Process.sleep(10 * attempt)
          with_world(manager, key, call, attempt + 1)

        :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
          {:error, not_running(manager, key)}
      end
    end
  end

  defp start_world(manager, key) do
    with {:ok, opts} <- __MODULE__.Janitor.world_options(manager, key) do
      spec = {__MODULE__.Instance, manager: manager, key: key, options: opts}

      case DynamicSupervisor.start_child(worlds_supervisor(manager), spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, could_not_start(key, reason)}
      end
    end
  end

  # Why a world could not start (a corrupt or foreign journal, an unreadable
  # snapshot) is for the operator; the caller learns that it could not.
  defp could_not_start(key, reason) do
    cause =
      case reason do
        {:shutdown, {:failed_to_start_child, _child, %Error{} = error}} -> error
        %Error{} = error -> error
        other -> other
      end

    Error.new(:world_failed, "the world #{inspect(key)} could not start", %{
      world: key,
      reason: cause
    })
  end

  defp stop_pid(manager, pid) do
    case DynamicSupervisor.terminate_child(worlds_supervisor(manager), pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp not_running(manager, key) do
    Error.new(:world_not_running, "the world #{inspect(key)} stopped while it was being used", %{
      world: key,
      manager: manager
    })
  end

  @doc false
  def group(key), do: {:world, key}

  @doc false
  def subscribers(manager), do: Module.concat(manager, Subscribers)
  defp registry(manager), do: Module.concat(manager, Registry)
  defp worlds_supervisor(manager), do: Module.concat(manager, Supervisor)

  @doc false
  def world_options, do: @world_options

  defmodule Instance do
    @moduledoc false
    # One world: its rendering tasks, runtime server, and scheduler, named
    # through the manager's registry rather than with atoms.
    use Supervisor

    alias Aethrion.Worlds

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :key)},
        start: {__MODULE__, :start_link, [opts]},
        type: :supervisor,
        restart: :transient
      }
    end

    def start_link(opts) do
      manager = Keyword.fetch!(opts, :manager)
      key = Keyword.fetch!(opts, :key)
      Supervisor.start_link(__MODULE__, opts, name: Worlds.via(manager, key, :world))
    end

    @impl true
    def init(opts) do
      manager = Keyword.fetch!(opts, :manager)
      key = Keyword.fetch!(opts, :key)
      options = Keyword.fetch!(opts, :options)
      runtime = Worlds.via(manager, key, :runtime)
      tasks = Worlds.via(manager, key, :tasks)

      expression =
        case Keyword.get(options, :expression) do
          nil -> []
          expression -> [expression: Keyword.put(expression, :task_supervisor, tasks)]
        end

      runtime_opts =
        [
          name: runtime,
          initial_state: Keyword.get(options, :initial_state, Aethrion.Runtime.demo_state()),
          subscribers: {Worlds.subscribers(manager), Worlds.group(key)},
          tag: {manager, key},
          # A world between messages holds little: most users are reading
          # or typing, not sending.
          hibernate_after: Keyword.get(options, :hibernate_after, 15_000)
        ] ++
          Keyword.take(options, [
            :pipeline,
            :persistence,
            :journal,
            :journal_compact_every,
            :history_limit,
            :max_depth,
            :max_events
          ]) ++ expression

      scheduler =
        case Keyword.get(options, :scheduler) do
          nil ->
            []

          scheduler_opts ->
            [
              {Scheduler,
               [runtime: runtime, name: Worlds.via(manager, key, :scheduler)] ++ scheduler_opts}
            ]
        end

      children =
        [
          {Task.Supervisor, name: tasks},
          {RuntimeServer, runtime_opts}
        ] ++ scheduler

      Supervisor.init(children, strategy: :rest_for_one)
    end
  end

  defmodule Janitor do
    @moduledoc false
    # Holds the world factory, and stops worlds nobody has used for
    # `:idle_after` milliseconds. Last use is kept in a public ETS table so
    # touching a world never waits on this process.
    use GenServer

    alias Aethrion.{Error, Worlds}

    def start_link(opts) do
      manager = Keyword.fetch!(opts, :manager)
      GenServer.start_link(__MODULE__, opts, name: Module.concat(manager, Janitor))
    end

    # Uses are recorded only when idle worlds are stopped.
    def touch(manager, key) do
      case :persistent_term.get({__MODULE__, manager}, nil) do
        %{table: table, idle_after: idle} when idle != nil ->
          :ets.insert(table, {key, System.monotonic_time(:millisecond)})

        _none ->
          :ok
      end

      :ok
    end

    def forget(manager, key) do
      case :persistent_term.get({__MODULE__, manager}, nil) do
        %{table: table} -> :ets.delete(table, key)
        nil -> :ok
      end

      :ok
    end

    def world_options(manager, key) do
      %{world: factory, idle_after: idle_after} = :persistent_term.get({__MODULE__, manager})

      case safe_call(factory, key) do
        {:raised, exception} ->
          {:error,
           Error.new(:world_failed, "the :world function raised for #{inspect(key)}", %{
             world: key,
             reason: exception
           })}

        opts when is_list(opts) ->
          check_options(opts, idle_after, key)

        other ->
          {:error,
           Error.new(:invalid_options, "the :world function must return a keyword list", %{
             world: key,
             returned: other
           })}
      end
    end

    defp safe_call(factory, key) do
      factory.(key)
    rescue
      exception -> {:raised, exception}
    end

    defp check_options(opts, idle_after, key) do
      unknown = Keyword.keys(opts) -- Worlds.world_options()

      cond do
        not Keyword.keyword?(opts) ->
          {:error,
           Error.new(:invalid_options, "world options must be a keyword list", %{world: key})}

        unknown != [] ->
          {:error,
           Error.new(:invalid_options, "unknown world options: #{inspect(unknown)}", %{
             world: key,
             options: unknown
           })}

        idle_after != nil and not Keyword.has_key?(opts, :journal) and
            not Keyword.has_key?(opts, :persistence) ->
          {:error,
           Error.new(
             :invalid_options,
             "with :idle_after, a world needs :journal or :persistence, or stopping it would lose it",
             %{world: key}
           )}

        true ->
          {:ok, opts}
      end
    end

    @impl true
    def init(opts) do
      manager = Keyword.fetch!(opts, :manager)
      idle_after = Keyword.get(opts, :idle_after)
      table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])

      :persistent_term.put({__MODULE__, manager}, %{
        world: Keyword.fetch!(opts, :world),
        idle_after: idle_after,
        table: table
      })

      state = %{manager: manager, idle_after: idle_after, table: table}
      {:ok, schedule(state)}
    end

    @impl true
    def handle_info(:sweep, state) do
      now = System.monotonic_time(:millisecond)

      for key <- Worlds.running(state.manager) do
        # A world started without a recorded use (Worlds.start/2, or after
        # this process restarted) starts its idle time now.
        last =
          case :ets.lookup(state.table, key) do
            [{^key, at}] ->
              at

            [] ->
              :ets.insert(state.table, {key, now})
              now
          end

        if now - last >= state.idle_after, do: Worlds.stop(state.manager, key)
      end

      {:noreply, schedule(state)}
    end

    @impl true
    def terminate(_reason, state) do
      :persistent_term.erase({__MODULE__, state.manager})
      :ok
    end

    defp schedule(%{idle_after: nil} = state), do: state

    defp schedule(%{idle_after: idle_after} = state) do
      Process.send_after(self(), :sweep, max(div(idle_after, 4), 50))
      state
    end
  end
end
