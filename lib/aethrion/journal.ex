defmodule Aethrion.Journal do
  @moduledoc """
  Append-only event journals: a world as its starting state plus every host
  event, one JSON object per line.

  Because the runtime is deterministic, replaying a journal rebuilds exactly
  the same world, including every cascade, memory, and trace. A journal is
  therefore both a durable record and a reproducible bug report:

      {:ok, state, steps} = Aethrion.Journal.replay("tmp/world.jsonl")

  The first line is a header with the starting state and the Aethrion version
  that wrote it; each following line is one host event with the id it was
  assigned:

  ```json
  {"aethrion_journal": 1, "aethrion": "0.2.0-alpha", "state": {...}}
  {"id": "e1", "type": "gift_received", "from": "user", "to": "mina", ...}
  {"id": "e2", "type": "time_tick", "hours": 2, "now": "..."}
  ```

  A server that renders lines with a model also records what was said, so a
  replayed conversation (`Aethrion.Conversation`) holds the same words:

  ```json
  {"rendered": {"event_id": "e1", "from": "mina", "to": "user", "draft": "...", "text": "..."}}
  ```

  `Aethrion.RuntimeServer` (and `Aethrion.World`) keep a journal with the
  `:journal` option and rebuild from it on start. Custom event types can be
  replayed when the same pipeline is passed (`pipeline:`).

  Replay is exact for the Aethrion version (and pipeline) that wrote the
  journal. Rules change between versions, so reading a journal written by
  another version logs a warning; compact it with the old version before
  upgrading to keep the world as it was.

  A journal grows with every event and is replayed in full on start.
  `compact/2` (or `Aethrion.RuntimeServer.compact_journal/1` for a running
  world) replaces it with one that starts from the current state, trading the
  history for a fast start; pass `archive:` to keep the old file.
  """

  alias Aethrion.{Error, Event, Runtime, Scenario, State}

  require Logger

  @version 1
  @library_version Mix.Project.config()[:version]

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

  @doc false
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
      {:error, :enoent} -> {:error, Error.new(:not_found, "no journal at #{path}", %{file: path})}
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
           %{file: path}
         )}
    end
  end

  @doc false
  # Whether the tuning in the journal's header fits `pipeline`; loading it
  # with another pipeline would silently drop tuning for unknown rules.
  @spec check_tuning(Path.t(), Aethrion.Pipeline.t()) :: :ok | {:error, Error.t()}
  def check_tuning(path, pipeline) do
    with {:ok, contents} <- read_file(path),
         [header | _] <- String.split(contents, "\n", parts: 2),
         {:ok, %{"state" => %{"tuning" => %{} = tuning}}} <- Jason.decode(header),
         {:error, %Error{} = error} <- Aethrion.Tuning.from_data(tuning, pipeline: pipeline) do
      {:error,
       Error.new(
         :invalid_options,
         "the journal's tuning does not fit the pipeline (#{error.message}); " <>
           "compact with the pipeline the world runs with",
         %{file: path, reason: error}
       )}
    else
      {:error, %Error{} = error} -> {:error, error}
      _fits_or_no_tuning -> :ok
    end
  end

  defp archive(_path, nil), do: :ok

  defp archive(path, archive) do
    if File.exists?(archive),
      do: {:error, already_exists(archive)},
      else: copy_aside(path, archive)
  end

  # Copies next to the target and renames it into place, so a failed copy
  # never leaves a partial archive behind.
  defp copy_aside(path, archive) do
    tmp = tmp_path(archive)

    with :ok <- File.mkdir_p(Path.dirname(archive)),
         :ok <- File.cp(path, tmp) do
      File.rename(tmp, archive)
    end
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp)
        {:error, io_error(archive, reason)}
    end
  end

  defp write_header(path, state, version \\ nil) do
    header = %{
      "aethrion_journal" => @version,
      "aethrion" => @library_version,
      "state" => State.to_data(state)
    }

    tmp = tmp_path(path)

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- write_synced(tmp, Jason.encode!(header) <> "\n"),
           :ok <- unchanged(path, version) do
        File.rename(tmp, path)
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
    do: Error.new(:already_exists, "a file already exists at #{path}", %{file: path})

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

  @doc """
  Appends what a model said for a character's line (a rendered output), so
  that replay restores it in the conversation. Outputs that were not rendered
  by a model are ignored.
  """
  @spec append_rendered(Path.t(), map()) :: :ok | {:error, Error.t()}
  def append_rendered(path, output) do
    case Aethrion.Conversation.rendered_data(output) do
      nil ->
        :ok

      data ->
        case File.write(path, Jason.encode!(%{"rendered" => data}) <> "\n", [:append]) do
          :ok -> :ok
          {:error, reason} -> {:error, io_error(path, reason)}
        end
    end
  end

  @doc "Appends one processed host event (with its assigned `:id`)."
  @spec append(Path.t(), Event.t(), keyword()) :: :ok | {:error, Error.t()}
  def append(path, %{type: _type} = event, opts \\ []) do
    with {:ok, line} <- encode(event, opts) do
      case File.write(path, line <> "\n", [:append]) do
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
      file: path,
      reason: reason
    })
  end

  # A scenario file handed to a journal reader gets a pointer, not a parse error.
  defp not_a_scenario(contents) do
    case Jason.decode(contents) do
      {:ok, %{"events" => _}} -> {:error, invalid_journal(1, :scenario)}
      _journal_or_garbage -> :ok
    end
  end

  # The location (line) is added by `Aethrion.Error.format/1`.
  defp invalid_journal(line, reason) do
    Error.new(:invalid_journal, "invalid journal: #{describe(reason)}", %{
      line: line,
      reason: reason
    })
  end

  defp describe(%Jason.DecodeError{} = error), do: "not JSON (#{Exception.message(error)})"
  defp describe(:missing_header), do: "the first line is not a journal header"

  defp describe(:scenario),
    do: "this looks like a scenario file; run it with mix aethrion.scenario"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp safe_encode(event) do
    event |> Event.to_data() |> Jason.encode()
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  @doc """
  Reads a journal. Returns `{:ok, starting_state, events}` or
  `{:error, %Aethrion.Error{}}` with code `:not_found`, `:io_error`, or
  `:invalid_journal` (with the 1-based `:line` in `details`).

  Options: `:pipeline`, used to keep tuning for custom rules, and `:repair`:
  a last line cut short by a crash (no newline, not valid JSON) is always
  dropped with a warning, since that event was never committed; with
  `repair: true` it is also removed from the file. A complete last line that
  only lost its newline is kept, and `repair: true` restores the newline.
  """
  @spec read(Path.t(), keyword()) :: {:ok, State.t(), [Event.t()]} | {:error, Error.t()}
  def read(path, opts \\ []) do
    with {:ok, state, entries} <- read_entries(path, opts) do
      {:ok, state, Enum.reject(entries, &match?({:rendered, _line}, &1))}
    end
  end

  # Events and rendered lines, in the order they were written.
  defp read_entries(path, opts) do
    with {:ok, contents} <- read_file(path),
         :ok <- not_a_scenario(contents),
         {:ok, contents} <- drop_torn_line(path, contents, Keyword.get(opts, :repair, false)) do
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

  # An append cut short by a crash leaves a last line without its newline.
  # If that line is not valid JSON, the event was never committed (the server
  # writes the journal before it commits), so it is dropped; with
  # `repair: true` it is also cut from the file. If the line is complete and
  # only its newline was lost, it is kept, and `repair: true` restores the
  # newline. Either way later appends start on a fresh line.
  defp drop_torn_line(path, contents, repair?) do
    if contents == "" or String.ends_with?(contents, "\n") do
      {:ok, contents}
    else
      case split_last_line(contents) do
        [kept, torn] -> torn_or_unterminated(path, contents, kept, torn, repair?)
        [_only_line] -> terminate(path, contents, repair?)
      end
    end
  end

  defp torn_or_unterminated(path, contents, kept, torn, repair?) do
    case Jason.decode(torn) do
      {:ok, _complete} ->
        terminate(path, contents, repair?)

      {:error, _reason} ->
        Logger.warning(
          "dropping an incomplete last line of #{path}: #{inspect(String.slice(torn, 0, 60))}"
        )

        if repair?,
          do: with(:ok <- write_whole(path, kept), do: {:ok, kept}),
          else: {:ok, kept}
    end
  end

  defp terminate(path, contents, repair?) do
    terminated = contents <> "\n"

    if repair?,
      do: with(:ok <- write_whole(path, terminated), do: {:ok, terminated}),
      else: {:ok, terminated}
  end

  defp split_last_line(contents) do
    case :binary.matches(contents, "\n") do
      [] ->
        [contents]

      matches ->
        {position, 1} = List.last(matches)
        cut = position + 1
        [binary_part(contents, 0, cut), binary_part(contents, cut, byte_size(contents) - cut)]
    end
  end

  defp write_whole(path, contents) do
    tmp = tmp_path(path)

    case with(:ok <- write_synced(tmp, contents), do: File.rename(tmp, path)) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(tmp)
        {:error, io_error(path, reason)}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:error, Error.new(:not_found, "no journal at #{path}", %{file: path})}

      {:error, reason} ->
        {:error,
         Error.new(:io_error, "could not read #{path}: #{:file.format_error(reason)}", %{
           reason: reason
         })}
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
    with {:ok, state, entries} <- read_entries(path, opts) do
      replay_events(state, entries, opts)
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

  # Rendered lines restore what a model said in the conversation; they are
  # not events, so they produce no step and do not count as one.
  defp replay_events(state, entries, opts) do
    runtime_opts = Keyword.take(opts, [:pipeline, :max_depth, :max_events])

    entries
    |> Enum.reduce_while({:ok, state, [], 0}, fn
      {:rendered, line}, {:ok, state, steps, index} ->
        {:cont, {:ok, Aethrion.Conversation.put_rendered(state, line), steps, index}}

      event, {:ok, state, steps, index} ->
        case replay_event(state, event, index, runtime_opts) do
          {:ok, step} -> {:cont, {:ok, step.state, [step | steps], index + 1}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, state, steps, _count} -> {:ok, state, Enum.reverse(steps)}
      error -> error
    end
  end

  defp replay_event(state, event, index, runtime_opts) do
    recorded_id = Map.get(event, :id)

    case Runtime.step(state, Map.delete(event, :id), runtime_opts) do
      {:ok, step} when is_nil(recorded_id) or step.event.id == recorded_id ->
        {:ok, step}

      {:ok, step} ->
        {:error,
         Error.new(
           :journal_mismatch,
           "replayed event #{index} got id #{step.event.id}, but the journal recorded #{recorded_id}",
           %{index: index, expected: recorded_id, replayed: step.event.id}
         )}

      {:error, error} ->
        {:error, Error.add_details(error, %{index: index})}
    end
  end

  defp parse_header(line, opts) do
    with {:ok, %{"aethrion_journal" => @version, "state" => data} = header} <- Jason.decode(line),
         {:ok, state} <- State.parse(data, Keyword.take(opts, [:pipeline])) do
      warn_on_version(header)
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

      {:ok, %{"events" => _}} ->
        {:error, invalid_journal(1, :scenario)}

      _other ->
        {:error, invalid_journal(1, :missing_header)}
    end
  end

  defp warn_on_version(%{"aethrion" => version}) when version != @library_version do
    Logger.warning(
      "this journal was written by Aethrion #{inspect(version)} and is being read by " <>
        "#{@library_version}; rules may have changed, so replay can differ from the original. " <>
        "Compact it with #{inspect(version)} before upgrading to keep the world as it was, " <>
        "or compact it now to continue from the world as these rules replay it."
    )
  end

  defp warn_on_version(_header), do: :ok

  defp parse_events(lines, pipeline) do
    lines
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, entries} ->
      case parse_entry(line, pipeline) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, %Error{} = error} -> {:halt, {:error, invalid_journal(number, error.message)}}
        {:error, reason} -> {:halt, {:error, invalid_journal(number, reason)}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp parse_entry(line, pipeline) do
    case Jason.decode(line) do
      {:ok, %{"rendered" => rendered}} ->
        case Aethrion.Conversation.rendered_from_data(rendered) do
          {:ok, line} -> {:ok, {:rendered, line}}
          :error -> {:error, :invalid_rendered_line}
        end

      {:ok, data} ->
        with {:ok, event} <- Event.from_data(data, pipeline: pipeline) do
          case Map.get(data, "id") do
            id when is_binary(id) -> {:ok, Map.put(event, :id, id)}
            _ -> {:ok, event}
          end
        end

      error ->
        error
    end
  end
end
