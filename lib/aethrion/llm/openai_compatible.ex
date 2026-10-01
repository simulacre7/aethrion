defmodule Aethrion.LLM.OpenAICompatible do
  @moduledoc """
  Adapter for any server that implements the OpenAI Chat Completions API:
  OpenAI, vLLM, Ollama, llama.cpp server, LM Studio, and others.

  It uses Erlang's built-in `:httpc`, so Aethrion gains no runtime
  dependencies. The adapter only returns text (or an intent proposal); it never
  sees or changes simulation state.

  ## Configuration

  Each option is resolved from, in order: adapter options, application config,
  then environment variables.

  | option         | application config key   | environment variable      |
  | -------------- | ------------------------ | ------------------------- |
  | `:base_url`    | `:base_url`              | `AETHRION_LLM_BASE_URL`   |
  | `:api_key`     | `:api_key`               | `AETHRION_LLM_API_KEY`    |
  | `:model`       | `:model`                 | `AETHRION_LLM_MODEL`      |
  | `:timeout`     | `:timeout`               | -                         |
  | `:temperature` | `:temperature`           | -                         |
  | `:max_tokens`  | `:max_tokens`            | -                         |
  | `:retries`     | `:retries`               | -                         |

  Rate limits, overload, server errors, and failed connections are retried
  `:retries` times (default 2) with backoff, honoring `retry-after`.

  `:base_url` and `:model` are required. `:api_key` is optional for local
  servers.

      # config/runtime.exs
      config :aethrion, Aethrion.LLM.OpenAICompatible,
        base_url: "http://localhost:11434/v1",
        model: "llama3.2"

      # or per call
      Aethrion.Expression.render(outputs,
        adapter: Aethrion.LLM.OpenAICompatible,
        adapter_opts: [base_url: "https://api.openai.com/v1", model: "...", api_key: key]
      )
  """

  @behaviour Aethrion.LLM.Adapter

  alias Aethrion.Expression.{Prompt, Request}
  alias Aethrion.LLM.HTTP

  # A reply may run to three sentences, in any language.
  @defaults [timeout: 15_000, temperature: 0.7, max_tokens: 200, retries: 2]
  @env %{
    base_url: "AETHRION_LLM_BASE_URL",
    api_key: "AETHRION_LLM_API_KEY",
    model: "AETHRION_LLM_MODEL"
  }

  @impl true
  def render(%Request{} = request, opts \\ []) do
    with {:ok, config} <- config(opts),
         {:ok, text} <- complete(config, Prompt.render_messages(request, opts), []) do
      case Prompt.clean_line(text) do
        "" -> {:error, :empty_response}
        line -> {:ok, line}
      end
    end
  end

  @impl true
  def interpret(%Aethrion.Intent.Request{} = request, opts \\ []) do
    with {:ok, config} <- config(opts),
         {:ok, text} <-
           complete(config, Prompt.intent_messages(request), temperature: 0, max_tokens: 40) do
      Prompt.decode_json_object(text)
    end
  end

  @doc """
  Returns true when `:base_url` and `:model` can be resolved.
  """
  def configured?(opts \\ []), do: match?({:ok, _config}, config(opts))

  @doc false
  def config(opts) do
    app = Application.get_env(:aethrion, __MODULE__, [])

    config =
      Map.new(
        [:base_url, :api_key, :model, :timeout, :temperature, :max_tokens, :retries],
        fn key ->
          value =
            Keyword.get(opts, key) || Keyword.get(app, key) || env(key) ||
              Keyword.get(@defaults, key)

          {key, value}
        end
      )

    cond do
      blank?(config.base_url) -> {:error, :missing_base_url}
      blank?(config.model) -> {:error, :missing_model}
      true -> {:ok, config}
    end
  end

  defp complete(config, messages, overrides) do
    body = %{
      model: config.model,
      messages: messages,
      temperature: Keyword.get(overrides, :temperature, config.temperature),
      max_tokens: Keyword.get(overrides, :max_tokens, config.max_tokens)
    }

    url = String.trim_trailing(config.base_url, "/") <> "/chat/completions"

    headers =
      if blank?(config.api_key), do: [], else: [{"authorization", "Bearer " <> config.api_key}]

    with {:ok, response} <-
           HTTP.post_json(url, headers, body, config.timeout, retries: config.retries) do
      case response do
        %{"choices" => [%{"message" => %{"content" => content}} | _]} when is_binary(content) ->
          {:ok, content}

        %{"error" => error} ->
          {:error, {:provider_error, error}}

        other ->
          {:error, {:unexpected_response, other}}
      end
    end
  end

  defp env(key) do
    case Map.fetch(@env, key) do
      {:ok, name} -> System.get_env(name)
      :error -> nil
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
