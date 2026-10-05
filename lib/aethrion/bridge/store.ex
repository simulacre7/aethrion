defmodule Aethrion.Bridge.Store do
  @moduledoc """
  A key-value store for `Aethrion.Bridge`, in memory (ETS) and, when given a
  path, in a file, so a restart remembers. The bridge keeps two:
  `Aethrion.Bridge.Readings` (what each chat line was read as, so a
  conversation replayed on every request asks the model only about new
  lines) and `Aethrion.Bridge.Checkpoints` (the world after each turn, so a
  chat the app has trimmed goes on from where it was).

  Values are JSON: what is kept is what comes back, in this VM or a fresh
  one, whatever modules it has loaded (no atoms to restore).

      {Aethrion.Bridge.Store, name: Aethrion.Bridge.Readings, path: "data/bridge-readings.jsonl"}
  """

  use GenServer

  def child_spec(opts),
    do: %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc """
  The store as `%{get: fun, put: fun}` for `Aethrion.Bridge`; when it is
  not running, nothing is found and nothing is kept.
  """
  def cache(name), do: %{get: &get(name, &1), put: &put(name, &1, &2)}

  @doc """
  The store as a cache whose puts are held back until `commit` (or dropped
  by `discard`): `{cache, commit, discard}`. What is put is found again by
  the same cache at once. For work that counts only if it ends well, such
  as a turn whose reply may fail. Call all three from the same process.
  """
  def staged(name) do
    ref = make_ref()
    keys = {ref, :keys}

    get = fn key ->
      case Process.get({ref, key}) do
        nil -> get(name, key)
        value -> value
      end
    end

    put = fn key, value ->
      if Process.get({ref, key}) == nil, do: Process.put(keys, [key | Process.get(keys, [])])
      Process.put({ref, key}, normalize(value))
      :ok
    end

    discard = fn ->
      for key <- Process.get(keys, []), do: Process.delete({ref, key})
      Process.delete(keys)
      :ok
    end

    commit = fn ->
      for key <- Enum.reverse(Process.get(keys, [])), do: put(name, key, Process.get({ref, key}))
      discard.()
    end

    {%{get: get, put: put}, commit, discard}
  end

  def get(name, key) do
    case :ets.whereis(name) != :undefined and :ets.lookup(name, key) do
      [{^key, value}] -> value
      _none -> nil
    end
  end

  def put(name, key, value) do
    if :ets.whereis(name) != :undefined, do: GenServer.cast(name, {:put, key, normalize(value)})
    :ok
  end

  @doc "Everything kept, as `{key, value}` (in no order)."
  def all(name) do
    if :ets.whereis(name) != :undefined, do: :ets.tab2list(name), else: []
  end

  @doc """
  Puts `value` in place of what was kept under `key` (`put/3` keeps what
  was there first), and waits until it is kept. For what someone edits by
  hand; a nil value forgets the key.
  """
  def replace(name, key, value) do
    if :ets.whereis(name) != :undefined,
      do: GenServer.call(name, {:replace, key, normalize(value)}),
      else: :ok
  end

  # As it would come back from the file.
  defp normalize(value), do: value |> Jason.encode!() |> Jason.decode!()

  @impl true
  def init(opts) do
    table = :ets.new(Keyword.fetch!(opts, :name), [:named_table, :public, read_concurrency: true])
    path = Keyword.get(opts, :path)
    if path, do: load(table, path)
    {:ok, %{table: table, path: path}}
  end

  @impl true
  def handle_cast({:put, key, value}, state) do
    # What was kept first stays: a reroll puts the same thing again, and
    # two requests racing for one turn cannot leave the world of a reply
    # someone saw behind the other's. The file gets each key once.
    if :ets.insert_new(state.table, {key, value}) do
      if state.path do
        line = Jason.encode!(%{"key" => key, "value" => value})
        File.write!(state.path, line <> "\n", [:append])
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:replace, key, value}, _from, state) do
    # A key forgotten is gone: what is put under it next is kept.
    if value == nil,
      do: :ets.delete(state.table, key),
      else: :ets.insert(state.table, {key, value})

    if state.path do
      line = Jason.encode!(%{"key" => key, "value" => value, "replace" => true})
      File.write!(state.path, line <> "\n", [:append])
    end

    {:reply, :ok, state}
  end

  # A line that cannot be read (or was written in an older format) is
  # skipped; a key written twice keeps its first value, unless a later
  # line replaces it or forgets it.
  defp load(table, path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(fn line ->
        case Jason.decode(line) do
          {:ok, %{"key" => key, "value" => nil, "replace" => true}} when is_binary(key) ->
            :ets.delete(table, key)

          {:ok, %{"key" => key, "value" => value, "replace" => true}} when is_binary(key) ->
            :ets.insert(table, {key, value})

          {:ok, %{"key" => key, "value" => value}} when is_binary(key) ->
            :ets.insert_new(table, {key, value})

          _other ->
            :ok
        end
      end)
    end
  end
end
