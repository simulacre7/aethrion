defmodule Aethrion.StubHTTPServer do
  @moduledoc false
  # A tiny HTTP/1.1 server for adapter tests. Each request is forwarded to the
  # owner as `{:stub_request, request}` and answered by `responder`.

  def start(responder) when is_function(responder, 1) do
    owner = self()
    {:ok, socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    pid = spawn_link(fn -> accept_loop(socket, owner, responder) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    {:ok, "http://127.0.0.1:#{port}", pid}
  end

  defp accept_loop(socket, owner, responder) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        handle(client, owner, responder)
        accept_loop(socket, owner, responder)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle(client, owner, responder) do
    {:ok, head, rest} = read_head(client, "")
    [request_line | header_lines] = String.split(head, "\r\n", trim: true)
    [method, path, _version] = String.split(request_line, " ")

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    length = headers |> Map.get("content-length", "0") |> String.to_integer()
    body = read_body(client, rest, length)
    request = %{method: method, path: path, headers: headers, body: body}

    send(owner, {:stub_request, request})
    # A responder may add headers: {status, body, [{"retry-after", "0"}]}.
    {status, response, extra} =
      case responder.(request) do
        {status, response} -> {status, response, []}
        {status, response, extra} -> {status, response, extra}
      end

    :gen_tcp.send(client, [
      "HTTP/1.1 #{status} Stub\r\n",
      Enum.map(extra, fn {key, value} -> "#{key}: #{value}\r\n" end),
      "content-type: application/json\r\n",
      "content-length: #{byte_size(response)}\r\n",
      "connection: close\r\n\r\n",
      response
    ])

    :gen_tcp.close(client)
  end

  defp read_head(client, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {:ok, head, rest}

      [_incomplete] ->
        {:ok, data} = :gen_tcp.recv(client, 0, 5_000)
        read_head(client, buffer <> data)
    end
  end

  defp read_body(_client, buffer, length) when byte_size(buffer) >= length, do: buffer

  defp read_body(client, buffer, length) do
    {:ok, data} = :gen_tcp.recv(client, 0, 5_000)
    read_body(client, buffer <> data, length)
  end
end
