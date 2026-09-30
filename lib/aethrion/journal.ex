defmodule Aethrion.Journal do
  @moduledoc """
  Append-only event journals: a world as its starting state plus every host
  event, one JSON object per line.

  Because the runtime is deterministic, replaying a journal rebuilds exactly
  the same world, including every cascade, memory, and trace. A journal is
  therefore both a durable record and a reproducible bug report:

      {:ok, state, steps} = Aethrion.Journal.replay("tmp/world.jsonl")

  The first line is a header with the starting state; each following line is
  one host event with the id it was assigned:

  ```json
  {"aethrion_journal": 1, "state": {...}}
  {"id": "e1", "type": "gift_received", "from": "user", "to": "mina", ...}
  {"id": "e2", "type": "time_tick", "hours": 2, "now": "..."}
  ```

  `Aethrion.RuntimeServer` (and `Aethrion.World`) keep a journal with the
  `:journal` option and rebuild from it on start. Custom event types can be
  replayed when the same pipeline is passed (`pipeline:`).
  """

  alias Aethrion.{Event, Runtime, Scenario, State}

  @version 1

  @doc """
  Creates a journal at `path` whose starting state is `state`. Fails if the
  file already exists. The header is written to a temporary file and renamed
  into place, so a failed create never leaves a half-written journal.
  """
  def create(path, %State{} = state) do
    header = %{"aethrion_journal" => @version, "state" => State.to_data(state)}
    tmp = path <> ".tmp"

    cond do
      File.exists?(path) ->
        {:error, :already_exists}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(tmp, Jason.encode!(header) <> "\n"),
             :ok <- File.rename(tmp, path) do
          :ok
        else
          {:error, reason} ->
            File.rm(tmp)
            {:error, reason}
        end
    end
  end

  @doc """
  Encodes a processed host event as a journal line, or returns
  `{:error, {:not_replayable, reason}}` if the event would not come back
  unchanged from JSON (for example a tuple or DateTime in a field, or a custom
  field value that is an atom). Pass the world's `pipeline:` for custom events.
  """
  def encode(%{type: _type} = event, opts \\ []) do
    event = Map.delete(event, :cause)

    with {:ok, json} <- safe_encode(event),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, replayed} <- Event.from_data(decoded, Keyword.take(opts, [:pipeline])),
         true <- Map.put(replayed, :id, Map.get(event, :id)) == event do
      {:ok, json}
    else
      false -> {:error, {:not_replayable, :changes_through_json}}
      {:error, reason} -> {:error, {:not_replayable, reason}}
    end
  end

  @doc "Appends one processed host event (with its assigned `:id`)."
  def append(path, %{type: _type} = event, opts \\ []) do
    with {:ok, line} <- encode(event, opts) do
      append_line(path, line)
    end
  end

  @doc false
  def append_line(path, line), do: File.write(path, line <> "\n", [:append, :utf8])

  defp safe_encode(event) do
    event |> Event.to_data() |> Jason.encode()
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  Reads a journal. Returns `{:ok, starting_state, events}` or
  `{:error, {:invalid_journal, line_number, reason}}`.

  Options: `:pipeline`, used to keep tuning for custom rules.
  """
  def read(path, opts \\ []) do
    with {:ok, contents} <- File.read(path) do
      lines =
        contents
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _number} -> String.trim(line) == "" end)

      case lines do
        [] ->
          {:error, {:invalid_journal, 1, :empty}}

        [{header, 1} | events] ->
          with {:ok, state} <- parse_header(header, opts),
               {:ok, events} <- parse_events(events, Keyword.get(opts, :pipeline)) do
            {:ok, state, events}
          end

        [{_line, number} | _rest] ->
          {:error, {:invalid_journal, number, :missing_header}}
      end
    end
  end

  @doc """
  Rebuilds the world by replaying the journal. Returns
  `{:ok, state, steps}`, or an error if the journal cannot be read, an event
  is rejected, or a replayed event gets a different id than the one recorded
  (which means the journal does not match its starting state).

  Options: `:pipeline` (use the same pipeline the world ran with).
  """
  def replay(path, opts \\ []) do
    with {:ok, state, events} <- read(path, opts) do
      replay_events(state, events, opts)
    end
  end

  @doc """
  Converts a journal into scenario data (ready for `Jason.encode!/2`), with
  snapshot expectations like `Aethrion.Scenario.record/5`.
  """
  def to_scenario(path, opts \\ []) do
    with {:ok, state, events} <- read(path, opts),
         {:ok, final, steps} <- replay_events(state, events, opts) do
      {:ok,
       Scenario.record(state, events, final, Enum.flat_map(steps, & &1.outputs),
         name: Keyword.get(opts, :name, Path.basename(path)),
         description: "Replayed from the journal #{Path.basename(path)}."
       )}
    end
  end

  defp replay_events(state, events, opts) do
    runtime_opts = Keyword.take(opts, [:pipeline, :max_depth, :max_events])

    events
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state, []}, fn {event, index}, {:ok, state, steps} ->
      recorded_id = Map.get(event, :id)

      case Runtime.step(state, Map.delete(event, :id), runtime_opts) do
        {:ok, step} when is_nil(recorded_id) or step.event.id == recorded_id ->
          {:cont, {:ok, step.state, [step | steps]}}

        {:ok, step} ->
          {:halt,
           {:error, {:journal_mismatch, index, expected: recorded_id, replayed: step.event.id}}}

        {:error, error} ->
          {:halt, {:error, {:rejected, index, error}}}
      end
    end)
    |> case do
      {:ok, state, steps} -> {:ok, state, Enum.reverse(steps)}
      error -> error
    end
  end

  defp parse_header(line, opts) do
    with {:ok, %{"aethrion_journal" => @version, "state" => data}} <- Jason.decode(line),
         {:ok, state} <- State.parse(data, Keyword.take(opts, [:pipeline])) do
      {:ok, state}
    else
      {:ok, %{"aethrion_journal" => @version}} ->
        {:error, {:invalid_journal, 1, :missing_state}}

      {:ok, %{"aethrion_journal" => version}} ->
        {:error, {:invalid_journal, 1, {:unsupported_version, version}}}

      {:error, reason} ->
        {:error, {:invalid_journal, 1, reason}}

      _other ->
        {:error, {:invalid_journal, 1, :missing_header}}
    end
  end

  defp parse_events(lines, pipeline) do
    lines
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, events} ->
      with {:ok, data} <- Jason.decode(line),
           {:ok, event} <- Event.from_data(data, pipeline: pipeline) do
        event =
          case Map.get(data, "id") do
            id when is_binary(id) -> Map.put(event, :id, id)
            _ -> event
          end

        {:cont, {:ok, [event | events]}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_journal, number, reason}}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end
end
