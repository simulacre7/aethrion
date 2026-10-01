defmodule Aethrion.CLI.TaskArgs do
  @moduledoc false
  # Shared helpers for the mix tasks: options that are not understood are an
  # error, not silently ignored, and files that cannot be written say why
  # instead of printing a stack trace.

  @doc false
  # Parses `args` strictly: unknown options, and positional arguments beyond
  # `max_paths`, raise with `usage`.
  @spec parse!([String.t()], keyword(), String.t(), non_neg_integer() | :infinity) ::
          {keyword(), [String.t()]}
  def parse!(args, switches, usage, max_paths \\ :infinity) do
    # Write UTF-8 (Korean names and lines) whatever the shell's locale says.
    :io.setopts(:standard_io, encoding: :unicode)

    case OptionParser.parse(args, strict: switches) do
      {opts, paths, []} when max_paths == :infinity or length(paths) <= max_paths ->
        {opts, paths}

      {_opts, _paths, [{option, _value} | _]} ->
        Mix.raise("unknown or incomplete option #{option}\nusage: #{usage}")

      {_opts, [_ | _] = paths, []} ->
        Mix.raise("unexpected argument #{inspect(List.last(paths))}\nusage: #{usage}")
    end
  end

  @doc false
  # Writes `contents` to `path`, creating its directory.
  @spec write!(Path.t(), iodata()) :: :ok
  def write!(path, contents) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, contents) do
      :ok
    else
      {:error, reason} -> Mix.raise("could not write #{path}: #{:file.format_error(reason)}")
    end
  end
end
