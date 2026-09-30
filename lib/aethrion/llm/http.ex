defmodule Aethrion.LLM.HTTP do
  @moduledoc false
  # Minimal JSON-over-HTTP client on Erlang's built-in :httpc, shared by the
  # provider adapters so Aethrion needs no HTTP dependency.

  @doc """
  POSTs `body` as JSON. Returns `{:ok, decoded}` for 2xx responses,
  `{:error, {:http_status, status, decoded_or_raw}}` otherwise, or
  `{:error, {:http_error, reason}}` for transport failures and timeouts.
  """
  def post_json(url, headers, body, timeout) do
    {:ok, _apps} = Application.ensure_all_started([:inets, :ssl])

    headers =
      [{~c"accept", ~c"application/json"}] ++
        Enum.map(headers, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)

    request = {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}
    http_options = [timeout: timeout, connect_timeout: timeout] ++ ssl_options(url)

    case :httpc.request(:post, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, response_body}} when status in 200..299 ->
        case Jason.decode(response_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _error} -> {:error, {:invalid_json, response_body}}
        end

      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        {:error, {:http_status, status, decode(response_body)}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

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
