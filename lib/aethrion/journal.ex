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

  A journal grows with every event and is replayed in full on start.
  `compact/2` (or `Aethrion.RuntimeServer.compact_journal/1` for a running
  world) replaces it with one that starts from the current state, trading the
  history for a fast start; pass `archive:` to keep the old file.
  """

  alias Aethrion.{Error, Event, Runtime, Scenario, State}

  @version 1

  @doc """
  Creates a journal at `path` whose starting state is `state`. Fails if the
  file already exists. The header is written to a temporary file and renamed
  into place, so a failed create never leaves a half-written journal.
  """
  @spec create(Path.t(), State.t()) :: :ok | {:error, Error.t()}
  def create(path, %State{} = state) do
    if File.exists?(path),
      do: {:error, already_exists(path)},
      else: write_header(path, state)
  end

  @doc """
  Replaces a journal's contents with `state` as the new starting state and no
  events. Used by `Aethrion.RuntimeServer.compact_journal/1`, which already
  holds the current state; to compact a journal on disk, use `compact/2`.
  Like `create/2`, the file is written aside and renamed into place, so a
  failure leaves the old journal intact.
  """
  @spec rewrite(Path.t(), State.t()) :: :ok | {:error, Error.t()}
  def rewrite(path, %State{} = state), do: write_header(path, state)

  @doc """
  Compacts the journal at `path`: replays it and replaces it with a journal
  that starts from the resulting state and has no events. Event ids continue
  from where they were. The history (and with it, `Aethrion.Explain` for past
  events) is discarded unless `archive:` names a new file to keep the old
  journal in.

  Returns `{:ok, state, compacted}` where `compacted` is the number of events
  folded into the new starting state.

  Options: `:archive`, and `:pipeline`, `:max_depth`, `:max_events` as for
  `replay/2`. The result is only right with the pipeline and limits the world
  runs with; a journal whose tuning names rules outside `:pipeline` is refused
  rather than rewritten without them.

  Do not compact a journal a running server is appending to: use
  `Aethrion.RuntimeServer.compact_journal/1` (or `Aethrion.World.compact_journal/1`)
  for that. As a safeguard, if the file changes while it is being compacted,
  it is left alone and `:journal_changed` is returned.
  """
  @spec compact(Path.t(), keyword()) :: {:ok, State.t(), non_neg_integer()} | {:error, Error.t()}
  def compact(path, opts \\ []) do
    with {:ok, version} <- file_version(path),
         :ok <- check_tuning(path, Keyword.get(opts, :pipeline, Aethrion.Pipeline.default())),
         {:ok, state, steps} <- replay(path, opts),
         :ok <- unchanged(path, version),
         :ok <- archive(path, Keyword.get(opts, :archive)),
         :ok <- write_header(path, state, version) do
      {:ok, state, length(steps)}
    end
  end

  # Size, modification time, and inode: an append, a rewrite, or a rename by
  # someone else all change it.
  defp file_version(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, {stat.size, stat.mtime, stat.inode}}
      {:error, :enoent} -> {:error, Error.new(:not_found, "no journal at #{path}", %{path: path})}
      {:error, reason} -> {:error, io_error(path, reason)}
    end
  end

  defp unchanged(_path, nil), do: :ok

  defp unchanged(path, version) do
    case file_version(path) do
      {:ok, ^version} ->
        :ok

      _changed ->
        {:error,
         Error.new(
           :journal_changed,
           "#{path} changed while it was being compacted; is a server still appending to it?",
           %{path: path}
         )}
    end
  end

  defp check_tuning(path, pipeline) do
    with {:ok, contents} <- read_file(path),
         [header | _] <- String.split(contents, "\n", parts: 2),
         {:ok, %{"state" => %{"tuning" => %{} = tuning}}} <- Jason.decode(header),
         {:error, %Error{} = error} <- Aethrion.Tuning.from_data(tuning, pipeline: pipeline) do
      {:error,
       Error.new(
         :invalid_options,
         "the journal's tuning does not fit the pipeline (#{error.message}); " <>
           "compact with the pipeline the world runs with",
         %{path: path, reason: error}
       )}
    else
      {:error, %Error{} = error} -> {:error, error}
      _fits_or_no_tuning -> :ok
    end
  end

  defp archive(_path, nil), do: :ok

  defp archive(path, archive) do
    tmp = tmp_path(archive)

    cond do
      File.exists?(archive) ->
        {:error, already_exists(archive)}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(archive)),
             :ok <- File.cp(path, tmp),
             :ok <- File.rename(tmp, archive) do
          :ok
        else
          {:error, reason} ->
            File.rm(tmp)
            {:error, io_error(archive, reason)}
        end
    end
  end

  defp write_header(path, state, version \\ nil) do
    header = %{"aethrion_journal" => @version, "state" => State.to_data(state)}
    tmp = tmp_path(path)

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- write_synced(tmp, Jason.encode!(header) <> "\n"),
           :ok <- unchanged(path, version),
           :ok <- File.rename(tmp, path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        File.rm(tmp)
        {:error, error}

      {:error, reason} ->
        File.rm(tmp)
        {:error, io_error(path, reason)}
    end
  end

  # The new contents reach the disk before they replace the old ones.
  defp write_synced(path, contents) do
    case File.open(path, [:write, :binary], fn file ->
           with :ok <- IO.binwrite(file, contents), do: :file.sync(file)
         end) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp tmp_path(path), do: "#{path}.#{System.unique_integer([:positive])}.tmp"

  defp already_exists(path),
    do: Error.new(:already_exists, "a file already exists at #{path}", %{path: path})

  @doc """
  Encodes a processed host event as a journal line, or returns
  `{:error, %Aethrion.Error{code: :invalid_event}}` if the event would not come back
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
      false -> {:error, not_replayable(:changes_through_json)}
      {:error, reason} -> {:error, not_replayable(reason)}
    end
  end

  @doc "Appends one processed host event (with its assigned `:id`)."
  @spec append(Path.t(), Event.t(), keyword()) :: :ok | {:error, Error.t()}
  def append(path, %{type: _type} = event, opts \\ []) do
    with {:ok, line} <- encode(event, opts) do
      case File.write(path, line <> "\n", [:append, :utf8]) do
        :ok -> :ok
        {:error, reason} -> {:error, io_error(path, reason)}
      end
    end
  end

  defp not_replayable(%Error{} = error) do
    Error.new(:invalid_event, "event cannot be journaled faithfully: #{Error.format(error)}", %{
      reason: error
    })
  end

  defp not_replayable(reason) do
    Error.new(:invalid_event, "event cannot be journaled faithfully: #{inspect(reason)}", %{
      reason: reason
    })
  end

  defp io_error(path, reason) do
    Error.new(:io_error, "could not write #{path}: #{inspect(reason)}", %{
      path: path,
      reason: reason
    })
  end

  defp invalid_journal(line, reason) do
    Error.new(:invalid_journal, "invalid journal at line #{line}: #{inspect(reason)}", %{
      line: line,
      reason: reason
    })
  end

  defp safe_encode(event) do
    event |> Event.to_data() |> Jason.encode()
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  Reads a journal. Returns `{:ok, starting_state, events}` or
  `{:error, %Aethrion.Error{}}` with code `:not_found`, `:io_error`, or
  `:invalid_journal` (with the 1-based `:line` in `details`).

  Options: `:pipeline`, used to keep tuning for custom rules.
  """
  @spec read(Path.t(), keyword()) :: {:ok, State.t(), [Event.t()]} | {:error, Error.t()}
  def read(path, opts \\ []) do
    with {:ok, contents} <- read_file(path) do
      lines =
        contents
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _number} -> String.trim(line) == "" end)

      case lines do
        [] ->
          {:error, invalid_journal(1, :empty)}

        [{header, 1} | events] ->
          with {:ok, state} <- parse_header(header, opts),
               {:ok, events} <- parse_events(events, Keyword.get(opts, :pipeline)) do
            {:ok, state, events}
          end

        [{_line, number} | _rest] ->
          {:error, invalid_journal(number, :missing_header)}
      end
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:error, Error.new(:not_found, "no journal at #{path}", %{path: path})}

      {:error, reason} ->
        {:error,
         Error.new(:io_error, "could not read #{path}: #{inspect(reason)}", %{reason: reason})}
    end
  end

  @doc """
  Rebuilds the world by replaying the journal. Returns
  `{:ok, state, steps}` or `{:error, %Aethrion.Error{}}`: the read errors of
  `read/2`, the error of a rejected event (with its `:index`), or
  `:journal_mismatch` when a replayed event gets a different id than the one
  recorded, which means the journal does not match its starting state.

  Options: `:pipeline`, `:max_depth`, `:max_events` (use the ones the world ran with).
  """
  @spec replay(Path.t(), keyword()) ::
          {:ok, State.t(), [Aethrion.Step.t()]} | {:error, Error.t()}
  def replay(path, opts \\ []) do
    with {:ok, state, events} <- read(path, opts) do
      replay_events(state, events, opts)
    end
  end

  @doc """
  Converts a journal into scenario data (ready for `Jason.encode!/2`), with
  snapshot expectations like `Aethrion.Scenario.record/5`.
  """
  @spec to_scenario(Path.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
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
           {:error,
            Error.new(
              :journal_mismatch,
              "replayed event #{index} got id #{step.event.id}, but the journal recorded #{recorded_id}",
              %{index: index, expected: recorded_id, replayed: step.event.id}
            )}}

        {:error, error} ->
          {:halt, {:error, Error.add_details(error, %{index: index})}}
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
        {:error, invalid_journal(1, :missing_state)}

      {:ok, %{"aethrion_journal" => version}} ->
        {:error, invalid_journal(1, {:unsupported_version, version})}

      {:error, %Error{} = error} ->
        {:error, invalid_journal(1, error.message)}

      {:error, reason} ->
        {:error, invalid_journal(1, reason)}

      _other ->
        {:error, invalid_journal(1, :missing_header)}
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
        {:error, %Error{} = error} -> {:halt, {:error, invalid_journal(number, error.message)}}
        {:error, reason} -> {:halt, {:error, invalid_journal(number, reason)}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end
end
