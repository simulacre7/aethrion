defmodule Aethrion.Persistence.JsonFile do
  @moduledoc """
  JSON file persistence adapter for local experiments.

  Loading validates the file with `Aethrion.State.parse/2`, so a malformed or
  hand-edited file is reported instead of crashing, and never creates atoms.
  """

  @behaviour Aethrion.Persistence

  alias Aethrion.{Error, State}

  @impl true
  def save(%State{} = state, opts \\ []) do
    with {:ok, path} <- fetch_path(opts),
         :ok <- io(File.mkdir_p(Path.dirname(path)), path),
         {:ok, json} <- encode(state) do
      io(File.write(path, json), path)
    end
  end

  @impl true
  def load(opts \\ []) do
    with {:ok, path} <- fetch_path(opts),
         {:ok, json} <- read(path),
         {:ok, data} <- decode(json, path) do
      State.parse(data, Keyword.take(opts, [:pipeline]))
    end
  end

  defp fetch_path(opts) do
    case Keyword.fetch(opts, :path) do
      {:ok, path} when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        {:error, Error.new(:invalid_options, "the :path option is required", %{field: :path})}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, json} ->
        {:ok, json}

      {:error, :enoent} ->
        {:error, Error.new(:not_found, "no saved state at #{path}", %{file: path})}

      error ->
        io(error, path)
    end
  end

  defp encode(state) do
    case Jason.encode(State.to_data(state), pretty: true) do
      {:ok, json} ->
        {:ok, json}

      {:error, error} ->
        {:error,
         Error.new(:invalid_state, "state cannot be saved as JSON: #{Exception.message(error)}")}
    end
  end

  defp decode(json, path) do
    case Jason.decode(json) do
      {:ok, data} ->
        {:ok, data}

      {:error, error} ->
        {:error,
         Error.new(:invalid_state, "#{path} is not valid JSON: #{Exception.message(error)}", %{
           path: []
         })}
    end
  end

  defp io(:ok, _path), do: :ok

  defp io({:error, reason}, path) do
    {:error,
     Error.new(:io_error, "could not use #{path}: #{:file.format_error(reason)}", %{
       reason: reason
     })}
  end
end
