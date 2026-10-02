defmodule Aethrion.LLM.CLI do
  @moduledoc """
  A model on this machine, through its command-line tool: the Claude Code
  CLI (`claude -p`) or the Codex CLI (`codex exec`), with whatever account
  they are signed in to. No API key is needed in Aethrion.

  | option     | default    |                                                  |
  | ---------- | ---------- | ------------------------------------------------ |
  | `:command` | `"claude"` | `"claude"` or `"codex"`                          |
  | `:model`   | the CLI's  | passed as `--model`                              |
  | `:timeout` | `60_000`   | milliseconds for one call                        |

  Each call runs the tool once, with no tools of its own, in a temporary
  directory (so it does not read the project it is started from). A call
  takes seconds, slower than an HTTP API; for a model served locally
  (Ollama, LM Studio, llama.cpp), `Aethrion.LLM.OpenAICompatible` is faster.
  """

  @behaviour Aethrion.LLM.Adapter

  alias Aethrion.Expression.{Prompt, Request}

  @impl true
  def render(%Request{} = request, opts \\ []) do
    {system, content} = Prompt.render_parts(request, Keyword.take(opts, [:language]))

    with {:ok, text} <- complete(system, content, opts) do
      case Prompt.clean_line(text) do
        "" -> {:error, :empty_response}
        line -> {:ok, line}
      end
    end
  end

  @impl true
  def interpret(%Aethrion.Intent.Request{} = request, opts \\ []) do
    {system, content} = Prompt.intent_parts(request)
    with {:ok, text} <- complete(system, content, opts), do: Prompt.decode_json_object(text)
  end

  @impl true
  def complete(system, user, opts \\ []) do
    command = Keyword.get(opts, :command, "claude")

    case System.find_executable(command) do
      nil -> {:error, {:command_not_found, command}}
      path -> run(command, path, system, user, opts)
    end
  end

  @doc "Whether the command is installed."
  def configured?(opts \\ []),
    do: System.find_executable(Keyword.get(opts, :command, "claude")) != nil

  defp run(command, path, system, user, opts) do
    dir = Path.join(System.tmp_dir!(), "aethrion-cli")
    File.mkdir_p!(dir)
    model = if m = Keyword.get(opts, :model), do: ["--model", m], else: []
    out = Path.join(dir, "last-#{System.unique_integer([:positive])}.txt")

    args =
      case command do
        "codex" ->
          [
            "exec",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--output-last-message",
            out
          ] ++
            model ++ [system <> "\n\n" <> user]

        _claude ->
          ["-p", user, "--output-format", "text", "--tools", "", "--no-session-persistence"] ++
            ["--system-prompt", system] ++ model
      end

    try do
      case execute(path, args, dir, Keyword.get(opts, :timeout, 60_000)) do
        {:ok, text, 0} ->
          {:ok, if(command == "codex", do: read_out(out), else: String.trim(text))}

        {:ok, text, status} ->
          {:error, {:exit, status, String.slice(text, -400, 400)}}

        {:error, :timeout} ->
          {:error, :timeout}
      end
    after
      File.rm(out)
    end
  end

  # Runs the tool with stdin closed (so it neither waits for input nor warns
  # about it; the prompt is in the arguments, each its own word). On a
  # timeout, or if the caller goes away first, the tool and every process it
  # started are stopped.
  defp execute(path, args, dir, timeout) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :hide,
        args: ["-c", ~s(exec "$0" "$@" < /dev/null), path | args],
        cd: dir
      ])

    # A tool that already finished has no pid left to ask for.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    caller = self()
    reaper = spawn(fn -> reap(caller, os_pid) end)

    try do
      collect(port, [], System.monotonic_time(:millisecond) + timeout)
    after
      send(reaper, :done)
    end
  rescue
    error in ErlangError -> {:error, {:spawn_failed, Exception.message(error)}}
  end

  defp collect(port, acc, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [acc, data], deadline)

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(acc), status}
    after
      wait ->
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> kill_tree(os_pid)
          nil -> :ok
        end

        close(port)
        {:error, :timeout}
    end
  end

  defp close(port) do
    Port.close(port)
  catch
    :error, _closed -> :ok
  end

  defp reap(_caller, nil), do: :ok

  defp reap(caller, os_pid) do
    ref = Process.monitor(caller)

    receive do
      :done -> :ok
      {:DOWN, ^ref, :process, _pid, _reason} -> kill_tree(os_pid)
    end
  end

  @doc false
  # Stops a process and everything under it, children first.
  def kill_tree(os_pid) do
    {children, _status} = System.cmd("pgrep", ["-P", to_string(os_pid)], stderr_to_stdout: true)

    children
    |> String.split()
    |> Enum.each(&kill_tree/1)

    System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp read_out(path) do
    case File.read(path) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> ""
    end
  end
end
