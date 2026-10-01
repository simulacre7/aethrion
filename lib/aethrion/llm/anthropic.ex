defmodule Aethrion.LLM.Anthropic do
  @moduledoc """
  Adapter for the Anthropic Messages API (`POST /v1/messages`).

  Like every adapter, it only phrases outputs or proposes intents; it never
  sees or changes simulation state. It uses Erlang's built-in `:httpc`.

  ## Configuration

  Resolved from adapter options, then `config :aethrion, Aethrion.LLM.Anthropic`,
  then environment variables.

  | option       | environment variable        | default                      |
  | ------------ | --------------------------- | ---------------------------- |
  | `:api_key`   | `ANTHROPIC_API_KEY`         | required                     |
  | `:model`     | `AETHRION_ANTHROPIC_MODEL`  | `"claude-opus-5-5"`          |
  | `:base_url`  | `ANTHROPIC_BASE_URL`        | `"https://api.anthropic.com"`|
  | `:effort`    | -                           | `"low"`                      |
  | `:max_tokens`| -                           | `1024`                       |
  | `:timeout`   | -                           | `30_000`                     |
  | `:fallbacks` | -                           | `true` (see below)           |
  | `:retries`   | -                           | `2`                          |

  Rate limits (429), overload (529), server errors, and failed connections
  are retried `:retries` times with backoff, honoring `retry-after`.

  Lines are short, so requests run at `low` effort. For models that support
  it, the server-side refusal fallback (`fallbacks: "default"`) is enabled so a
  declined request is retried on a fallback model within the same call; pass
  `fallbacks: false` to disable it. A final `stop_reason` of `"refusal"` is
  returned as `{:error, {:refusal, stop_details}}`, which makes
  `Aethrion.Expression` keep the deterministic fallback text.
  """

  @behaviour Aethrion.LLM.Adapter

  alias Aethrion.Expression.{Prompt, Request}
  alias Aethrion.LLM.HTTP

  @api_version "2023-06-01"
  @fallback_beta "server-side-fallback-2026-07-01"
  @fallback_models ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

  @defaults [
    model: "claude-opus-5-5",
    base_url: "https://api.anthropic.com",
    effort: "low",
    max_tokens: 1024,
    timeout: 30_000,
    fallbacks: true,
    retries: 2
  ]

  @env %{
    api_key: "ANTHROPIC_API_KEY",
    model: "AETHRION_ANTHROPIC_MODEL",
    base_url: "ANTHROPIC_BASE_URL"
  }

  @impl true
  def render(%Request{} = request, opts \\ []) do
    {system, content} = Prompt.render_parts(request, Keyword.take(opts, [:language]))

    with {:ok, config} <- config(opts),
         {:ok, text} <- create_message(config, system, content) do
      case Prompt.clean_line(text) do
        "" -> {:error, :empty_response}
        line -> {:ok, line}
      end
    end
  end

  @impl true
  def interpret(%Aethrion.Intent.Request{} = request, opts \\ []) do
    {system, content} = Prompt.intent_parts(request)

    with {:ok, config} <- config(opts),
         {:ok, text} <- create_message(config, system, content) do
      Prompt.decode_json_object(text)
    end
  end

  @impl true
  def complete(system, user, opts \\ []) do
    with {:ok, config} <- config(opts), do: create_message(config, system, user)
  end

  @doc "Returns true when an API key can be resolved."
  def configured?(opts \\ []), do: match?({:ok, _config}, config(opts))

  @doc false
  def config(opts) do
    app = Application.get_env(:aethrion, __MODULE__, [])

    config =
      Map.new(Keyword.keys(@defaults) ++ [:api_key], fn key ->
        # An explicit adapter option always wins, even when blank.
        value =
          case Keyword.fetch(opts, key) do
            {:ok, value} ->
              value

            :error ->
              first_present([Keyword.get(app, key), env(key), Keyword.get(@defaults, key)])
          end

        {key, value}
      end)

    if config.api_key in [nil, ""], do: {:error, :missing_api_key}, else: {:ok, config}
  end

  @doc false
  def request_body(config, system, content) do
    body = %{
      model: config.model,
      max_tokens: config.max_tokens,
      system: system,
      messages: [%{role: "user", content: content}],
      output_config: %{effort: config.effort}
    }

    if fallbacks?(config), do: Map.put(body, :fallbacks, "default"), else: body
  end

  defp create_message(config, system, content) do
    headers =
      [{"x-api-key", config.api_key}, {"anthropic-version", @api_version}] ++
        if fallbacks?(config), do: [{"anthropic-beta", @fallback_beta}], else: []

    url = String.trim_trailing(config.base_url, "/") <> "/v1/messages"

    case HTTP.post_json(url, headers, request_body(config, system, content), config.timeout,
           retries: config.retries
         ) do
      {:ok, %{"stop_reason" => "refusal"} = response} ->
        {:error, {:refusal, Map.get(response, "stop_details")}}

      {:ok, %{"content" => blocks}} when is_list(blocks) ->
        # Adaptive thinking may add thinking blocks; only text blocks are the line.
        case for(%{"type" => "text", "text" => text} <- blocks, do: text) do
          [] -> {:error, :empty_response}
          texts -> {:ok, Enum.join(texts, "")}
        end

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, {:http_status, status, %{"error" => %{"type" => type} = error}}} ->
        {:error, {:api_error, status, type, Map.get(error, "message")}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fallbacks?(config), do: config.fallbacks == true and config.model in @fallback_models

  defp first_present(values), do: Enum.find(values, &(&1 not in [nil, ""]))

  defp env(key) do
    case Map.fetch(@env, key) do
      {:ok, name} -> System.get_env(name)
      :error -> nil
    end
  end
end
