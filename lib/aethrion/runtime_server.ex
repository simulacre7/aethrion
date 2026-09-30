defmodule Aethrion.RuntimeServer do
  @moduledoc """
  Supervised stateful wrapper around the deterministic runtime.

  `Aethrion.Runtime.step/3` remains the authoritative simulation core. This
  server adds the long-running concerns around it:

  - **State ownership** - the current `Aethrion.State` lives in the process.
  - **Subscriptions** - processes can `subscribe/1` to receive every dispatched
    step and every expression rendering.
  - **History** - the host events dispatched so far, for replay and debugging.
  - **Snapshots** - with `:persistence`, the state is saved after each dispatch
    and restored on start, so a supervised restart resumes where it left off.
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
  - `:history_limit` - how many host events to keep. Defaults to #{@default_history_limit}.
  - `:persistence` - `{adapter, opts}`, for example
    `{Aethrion.Persistence.JsonFile, path: "tmp/world.json"}`. A saved state is
    loaded on start (taking precedence over `:initial_state`) and saved after
    every successful dispatch.
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
  def dispatch(server, event) do
    case step(server, event) do
      {:ok, %Step{} = step} -> {:ok, step.state, step.outputs, step.log}
      error -> error
    end
  end

  @doc """
  Dispatches an event and returns the full `Aethrion.Step`.
  """
  def step(server, event) do
    GenServer.call(server, {:step, event})
  end

  @doc "Returns the current runtime state."
  def get_state(server), do: GenServer.call(server, :get_state)

  @doc """
  Replaces the current state, for example after loading a save. History is
  cleared because it no longer describes how the state was reached.
  """
  def put_state(server, %State{} = state), do: GenServer.call(server, {:put_state, state})

  @doc "Host events dispatched so far, oldest first, with their assigned ids."
  def history(server), do: GenServer.call(server, :history)

  @doc "Subscribes `pid` (default: the caller) to dispatch and expression messages."
  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @doc "Removes a subscription."
  def unsubscribe(server, pid \\ self()), do: GenServer.call(server, {:unsubscribe, pid})

  @doc false
  def crash(server) do
    GenServer.call(server, :crash)
  end

  ## Server

  @impl true
  def init(opts) do
    with {:ok, world} <- initial_world(opts),
         {:ok, expression} <- expression_config(Keyword.get(opts, :expression)) do
      {:ok,
       %{
         world: world,
         pipeline: Keyword.get(opts, :pipeline, Pipeline.default()),
         persistence: Keyword.get(opts, :persistence),
         history: [],
         history_limit: Keyword.get(opts, :history_limit, @default_history_limit),
         subscribers: %{},
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
        server =
          %{server | world: step.state}
          |> record_history(step.event)
          |> persist()
          |> broadcast({:dispatched, step})
          |> render_async(step.outputs)

        {:reply, {:ok, step}, server}

      {:error, error} ->
        {:reply, {:error, error}, server}
    end
  end

  def handle_call(:get_state, _from, server), do: {:reply, server.world, server}

  def handle_call({:put_state, state}, _from, server) do
    {:reply, :ok, persist(%{server | world: state, history: []})}
  end

  def handle_call(:history, _from, server), do: {:reply, Enum.reverse(server.history), server}

  def handle_call({:subscribe, pid}, _from, server) do
    if Map.has_key?(server.subscribers, pid) do
      {:reply, :ok, server}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(server.subscribers[pid], ref)}
    end
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

  def handle_call(:crash, _from, _server) do
    raise "intentional RuntimeServer crash"
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
    Runtime.step(server.world, event, pipeline: server.pipeline)
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

  defp initial_world(opts) do
    fallback = Keyword.get(opts, :initial_state, Runtime.demo_state())

    case Keyword.get(opts, :persistence) do
      {adapter, persistence_opts} ->
        load_opts =
          Keyword.put_new(
            persistence_opts,
            :pipeline,
            Keyword.get(opts, :pipeline, Pipeline.default())
          )

        case adapter.load(load_opts) do
          {:ok, %State{} = state} ->
            {:ok, state}

          # No snapshot yet: start fresh.
          {:error, :enoent} ->
            validate_state(fallback)

          {:error, :missing_state} ->
            validate_state(fallback)

          # A snapshot exists but cannot be read. Refuse to start rather than
          # overwrite it with a fresh world on the next dispatch.
          {:error, reason} ->
            Logger.error(
              "Aethrion.RuntimeServer could not restore its snapshot: #{inspect(reason)}"
            )

            {:error, {:invalid_snapshot, reason}}
        end

      nil ->
        validate_state(fallback)
    end
  end

  defp validate_state(%State{} = state), do: {:ok, state}
  defp validate_state(other), do: {:error, {:invalid_initial_state, other}}

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

  defp broadcast(server, payload) do
    for pid <- Map.keys(server.subscribers), do: send(pid, {:aethrion, self(), payload})
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
