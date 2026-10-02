defmodule Aethrion.LLM.HTTP do
  @moduledoc false
  # Minimal JSON-over-HTTP client on Erlang's built-in :httpc, shared by the
  # provider adapters so Aethrion needs no HTTP dependency.

  # Worth trying again: rate limits, overload, and server errors. A timeout
  # is not retried, since the caller's own deadline is usually close.
  @retry_statuses [408, 429, 500, 502, 503, 504, 529]
  @max_wait_ms 5_000

  @doc """
  POSTs `body` as JSON. Returns `{:ok, decoded}` for 2xx responses,
  `{:error, {:http_status, status, decoded_or_raw}}` otherwise, or
  `{:error, {:http_error, reason}}` for transport failures and timeouts.

  `timeout` bounds the whole call, retries included. Options: `:retries`
  (default 2) retries rate limits, overload, server errors, and failed
  connections, waiting `:backoff_ms` (default 500) doubled each time with
  jitter, or what a `retry-after` header asks (at most #{@max_wait_ms} ms),
  as long as at least a second would be left for the next attempt. A 500,
  502, 504, or 408 may follow a generation the provider completed, so a
  retry can be billed twice; 429, 529, and 503 are refused before any work.
  """
  def post_json(url, headers, body, timeout, opts \\ []) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    headers =
      [{~c"accept", ~c"application/json"}] ++
        Enum.map(headers, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)

    request = {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}

    retry = %{
      retries: Keyword.get(opts, :retries, 2),
      backoff: Keyword.get(opts, :backoff_ms, 500),
      deadline: now() + timeout,
      ssl: ssl_options(url)
    }

    attempt(request, retry, 0)
  end

  @least_attempt_ms 1_000

  defp attempt(request, retry, tried) do
    remaining = max(retry.deadline - now(), 1)
    http_options = [timeout: remaining, connect_timeout: remaining] ++ retry.ssl

    case send_request(request, http_options) do
      {:retry, wait, error} when tried < retry.retries ->
        wait = wait || jittered(retry.backoff * Integer.pow(2, tried))

        if retry.deadline - now() - wait >= @least_attempt_ms do
          Process.sleep(wait)
          attempt(request, retry, tried + 1)
        else
          error
        end

      {:retry, _wait, error} ->
        error

      result ->
        result
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp send_request(request, http_options) do
    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _error} -> {:error, {:invalid_json, response_body}}
        end

      {:ok, {{_version, status, _reason}, headers, response_body}}
      when status in @retry_statuses ->
        {:retry, retry_after(headers), {:error, {:http_status, status, decode(response_body)}}}

      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:error, {:http_status, status, decode(response_body)}}

      {:error, {:failed_connect, _details} = reason} ->
        {:retry, nil, {:error, {:http_error, reason}}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp retry_after(headers) do
    with {_key, value} <- List.keyfind(headers, ~c"retry-after", 0),
         {seconds, _rest} <- Integer.parse(to_string(value)) do
      min(max(seconds, 0) * 1000, @max_wait_ms)
    else
      _none -> nil
    end
  end

  defp jittered(ms), do: min(ms + :rand.uniform(max(div(ms, 2), 1)), @max_wait_ms)

  defp ssl_options("https" <> _rest) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  defp ssl_options(_url), do: []

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _error} -> body
    end
  end
end
