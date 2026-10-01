defmodule Aethrion.LLM.Backend do
  @moduledoc """
  Named model backends for the mix tasks (`--llm NAME`), each an adapter and
  its options:

  | name        | what                                   | needs                                     |
  | ----------- | -------------------------------------- | ----------------------------------------- |
  | `anthropic` | the Claude API                         | `ANTHROPIC_API_KEY`                       |
  | `openai`    | any OpenAI-compatible API              | `AETHRION_LLM_BASE_URL`, `--model`        |
  | `ollama`    | Ollama on this machine (port 11434)    | `ollama serve`, `--model` (e.g. qwen3)    |
  | `lmstudio`  | LM Studio's server (port 1234)         | a loaded model, `--model`                 |
  | `llamacpp`  | llama.cpp's `llama-server` (port 8080) | a running server                          |
  | `claude`    | the Claude Code CLI (`claude -p`)      | `claude` installed and signed in          |
  | `codex`     | the Codex CLI (`codex exec`)           | `codex` installed and signed in           |

  `--model` and `--base-url` override the defaults.
  """

  alias Aethrion.LLM.{Anthropic, CLI, OpenAICompatible}

  @names ~w(anthropic openai ollama lmstudio llamacpp claude codex)

  @doc "The backend names."
  def names, do: @names

  @doc "`{:ok, adapter, adapter_opts, label}` for a name, or `{:error, message}`."
  @spec resolve(String.t(), keyword()) ::
          {:ok, module(), keyword(), String.t()} | {:error, String.t()}
  def resolve(name, opts \\ []) do
    model = Keyword.get(opts, :model)
    base_url = Keyword.get(opts, :base_url)

    case preset(name, model, base_url) do
      :unknown ->
        {:error, "unknown --llm #{inspect(name)}; use one of #{Enum.join(@names, ", ")}"}

      {adapter, adapter_opts, label} ->
        if adapter.configured?(adapter_opts),
          do: {:ok, adapter, adapter_opts, label <> if(model, do: " (#{model})", else: "")},
          else: {:error, "#{label} is not ready: #{needs(name)}"}
    end
  end

  defp preset(name, model, base_url) do
    model_opt = if model, do: [model: model], else: []

    case name do
      "anthropic" -> {Anthropic, model_opt, "Claude API"}
      "openai" -> {OpenAICompatible, model_opt ++ url(base_url), "OpenAI-compatible API"}
      "ollama" -> {OpenAICompatible, local(11_434, base_url, model), "Ollama"}
      "lmstudio" -> {OpenAICompatible, local(1234, base_url, model), "LM Studio"}
      "llamacpp" -> {OpenAICompatible, local(8080, base_url, model || "local"), "llama.cpp"}
      "claude" -> {CLI, [command: "claude"] ++ model_opt, "Claude Code CLI"}
      "codex" -> {CLI, [command: "codex"] ++ model_opt, "Codex CLI"}
      _other -> :unknown
    end
  end

  defp url(nil), do: []
  defp url(base_url), do: [base_url: base_url]

  # Local servers need no key; a model name is required by the API shape.
  defp local(port, base_url, model),
    do:
      [base_url: base_url || "http://localhost:#{port}/v1", api_key: ""] ++
        if(model, do: [model: model], else: [])

  defp needs("anthropic"), do: "set ANTHROPIC_API_KEY"
  defp needs("openai"), do: "set AETHRION_LLM_BASE_URL (or --base-url) and --model"

  defp needs(name) when name in ["ollama", "lmstudio"],
    do: "pass --model (the name of a model the server has)"

  defp needs("llamacpp"), do: "start llama-server"
  defp needs(command), do: "install the #{command} command and sign in"
end
