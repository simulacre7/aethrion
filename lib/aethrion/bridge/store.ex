defmodule Aethrion.Bridge.Store do
  @moduledoc """
  A key-value store for `Aethrion.Bridge`, in memory (ETS) and, when given a
  path, in a file, so a restart remembers. The bridge keeps two:
  `Aethrion.Bridge.Readings` (what each chat line was read as, so a
  conversation replayed on every request asks the model only about new
  lines) and `Aethrion.Bridge.Checkpoints` (the world after each turn, so a
  chat the app has trimmed goes on from where it was).

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

  def get(name, key) do
    case :ets.whereis(name) != :undefined and :ets.lookup(name, key) do
      [{^key, value}] -> value
      _none -> nil
    end
  end

  def put(name, key, value) do
    if :ets.whereis(name) != :undefined, do: GenServer.cast(name, {:put, key, value})
    :ok
  end

  @impl true
  def init(opts) do
    table = :ets.new(Keyword.fetch!(opts, :name), [:named_table, :public, read_concurrency: true])
    path = Keyword.get(opts, :path)
    if path, do: load(table, path)
    {:ok, %{table: table, path: path}}
  end

  @impl true
  def handle_cast({:put, key, value}, state) do
    # A reroll puts the same thing again; the file gets it once.
    if :ets.lookup(state.table, key) != [{key, value}] do
      :ets.insert(state.table, {key, value})

      if state.path do
        line =
          Jason.encode!(%{"key" => key, "value" => Base.encode64(:erlang.term_to_binary(value))})

        File.write!(state.path, line <> "\n", [:append])
      end
    end

    {:noreply, state}
  end

  # Terms come back only with atoms that already exist; a line that cannot
  # be read is skipped.
  defp load(table, path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(fn line ->
        with {:ok, %{"key" => key, "value" => data}} <- Jason.decode(line),
             {:ok, binary} <- Base.decode64(data),
             {:ok, value} <- safe_term(binary) do
          :ets.insert(table, {key, value})
        end
      end)
    end
  end

  defp safe_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end
end
