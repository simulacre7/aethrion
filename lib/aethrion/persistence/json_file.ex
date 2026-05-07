defmodule Aethrion.Persistence.JsonFile do
  @moduledoc """
  JSON file persistence adapter for local experiments.
  """

  @behaviour Aethrion.Persistence

  alias Aethrion.State

  @impl true
  def save(%State{} = state, opts \\ []) do
    with {:ok, path} <- fetch_path(opts),
         :ok <- ensure_parent_dir(path),
         {:ok, json} <- Jason.encode(State.to_data(state), pretty: true),
         :ok <- File.write(path, json) do
      :ok
    end
  end

  @impl true
  def load(opts \\ []) do
    with {:ok, path} <- fetch_path(opts),
         {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json) do
      {:ok, State.from_data(data)}
    end
  end

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :missing_path}
    end
  end

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end
end
