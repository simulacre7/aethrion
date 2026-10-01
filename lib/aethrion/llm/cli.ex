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

    # Run with stdin closed, so the tool neither waits for input nor warns
    # about it; the prompt is in the arguments.
    task =
      Task.async(fn ->
        System.cmd("/bin/sh", ["-c", ~s(exec "$0" "$@" < /dev/null), path | args], cd: dir)
      end)

    try do
      case Task.yield(task, Keyword.get(opts, :timeout, 60_000)) ||
             Task.shutdown(task, :brutal_kill) do
        {:ok, {text, 0}} ->
          {:ok, if(command == "codex", do: read_out(out), else: String.trim(text))}

        {:ok, {text, status}} ->
          {:error, {:exit, status, String.slice(text, -400, 400)}}

        nil ->
          {:error, :timeout}
      end
    after
      File.rm(out)
    end
  end

  defp read_out(path) do
    case File.read(path) do
      {:ok, text} -> String.trim(text)
      {:error, _} -> ""
    end
  end
end
