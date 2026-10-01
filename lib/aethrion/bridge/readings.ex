defmodule Aethrion.Bridge.Readings do
  @moduledoc """
  What each chat line was read as, kept so a conversation replayed on every
  request asks the model only about new lines. In memory (ETS), and in a
  file when given one, so a restart does not ask again.
  """

  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The cache as `%{get: fun, put: fun}` for `Aethrion.Bridge.reader/3`."
  def cache, do: %{get: &get/1, put: &put/2}

  def get(key) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, key) do
      [{^key, readings}] -> readings
      _none -> nil
    end
  end

  def put(key, readings) do
    if :ets.whereis(@table) != :undefined, do: GenServer.cast(__MODULE__, {:put, key, readings})
    :ok
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    path = Keyword.get(opts, :path)
    if path, do: load(path)
    {:ok, %{path: path}}
  end

  @impl true
  def handle_cast({:put, key, readings}, state) do
    :ets.insert(@table, {key, readings})

    if state.path do
      line =
        Jason.encode!(%{
          "key" => key,
          "readings" => Base.encode64(:erlang.term_to_binary(readings))
        })

      File.write!(state.path, line <> "\n", [:append])
    end

    {:noreply, state}
  end

  # Terms come back only with atoms that already exist.
  defp load(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.each(fn line ->
        with {:ok, %{"key" => key, "readings" => data}} <- Jason.decode(line),
             {:ok, binary} <- Base.decode64(data) do
          :ets.insert(@table, {key, :erlang.binary_to_term(binary, [:safe])})
        end
      end)
    end
  rescue
    _corrupt -> :ok
  end
end
