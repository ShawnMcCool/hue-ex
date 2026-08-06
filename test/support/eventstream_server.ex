defmodule Hue.EventstreamServer do
  @moduledoc """
  A TLS listener that answers one request with a Server-Sent Events body,
  written as chunks whose boundaries the test chooses.

  Enough of an HTTP server to drive `Hue.Events.stream/2` over a real socket,
  through Req, Finch, Mint, and this library's pinned TLS options. It presents
  the same synthetic bridge certificate `Hue.Certificates` serves elsewhere, so
  the stream is pinned exactly as it is against real hardware.

  Two things it reports back, both of which are the point of using a socket
  rather than a stub:

    * `{:eventstream_request, request}` — the request head as bytes, so a test
      can assert what headers went out.
    * `{:eventstream_finished, result}` — what `:ssl.recv/3` said after the
      body was written. `{:error, :closed}` means the client hung up, which is
      how early termination is observed from the outside.
  """

  @common_name "0011223344556677"
  @accept_timeout 5_000
  @linger_timeout 5_000

  @doc """
  Starts the listener and returns `{port, fingerprint}`.

  `fragments` are written one `:ssl.send/2` at a time, each as its own HTTP
  chunk, so a frame can be split at any byte a test names.

  ## Options

    * `:status` — the status line's code and reason, as `{code, reason}`.
      Defaults to `{200, "OK"}`. Anything but 200 is answered as an ordinary
      body rather than a stream.
    * `:body` — the body for a non-200 answer. Defaults to `""`.
    * `:content_type` — the content type for a non-200 answer. Defaults to
      `"application/json"`.
    * `:close_after` — `:done` writes the terminating chunk and closes once the
      fragments are out, which is what lets a test enumerate to completion.
      `:abruptly` drops the socket mid-body with no terminating chunk, which is
      what a bridge losing power looks like from the client. Defaults to
      `:never`, leaving the stream open the way a healthy bridge does.
    * `:delay` — milliseconds to pause between fragments, so the split is a
      real one at the socket rather than one the kernel may coalesce away.
      Defaults to `0`.
    * `:report_to` — where to send the two report messages. Defaults to the
      calling process.
  """
  def start(fragments, options \\ []) do
    common_name = Keyword.get(options, :common_name, @common_name)

    {:ok, listen} =
      :ssl.listen(0,
        cert: Hue.Certificates.der(common_name),
        key: {:PrivateKeyInfo, Hue.Certificates.key(common_name)},
        reuseaddr: true,
        active: false,
        packet: :raw,
        mode: :binary
      )

    {:ok, {_address, port}} = :ssl.sockname(listen)
    options = Keyword.put_new(options, :report_to, self())
    acceptor = spawn(fn -> serve(listen, fragments, options) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :ssl.close(listen)
    end)

    {_der, fingerprint} = Hue.Certificates.bridge_certificate(common_name)
    {port, fingerprint}
  end

  # Keeps accepting rather than serving one connection and going away, because
  # "how many times did the client ask?" is a question a test needs to be able
  # to answer. A listener that answers exactly once cannot tell a client that
  # asked once from a client that asked four times and found nobody home.
  defp serve(listen, fragments, options) do
    report_to = Keyword.fetch!(options, :report_to)

    with {:ok, pending} <- :ssl.transport_accept(listen, @accept_timeout),
         {:ok, socket} <- :ssl.handshake(pending, @accept_timeout),
         {:ok, request} <- :ssl.recv(socket, 0, @accept_timeout) do
      send(report_to, {:eventstream_request, request})
      respond(socket, fragments, options)
      send(report_to, {:eventstream_finished, :ssl.recv(socket, 0, @linger_timeout)})
      :ssl.close(socket)
    end

    serve(listen, fragments, options)
  end

  defp respond(socket, fragments, options) do
    case Keyword.get(options, :status, {200, "OK"}) do
      {200, reason} -> stream(socket, reason, fragments, options)
      status -> :ssl.send(socket, refusal(status, options))
    end
  end

  defp stream(socket, reason, fragments, options) do
    :ssl.send(
      socket,
      "HTTP/1.1 200 #{reason}\r\n" <>
        "content-type: text/event-stream\r\n" <>
        "cache-control: no-cache\r\n" <>
        "transfer-encoding: chunked\r\n\r\n"
    )

    delay = Keyword.get(options, :delay, 0)

    Enum.each(fragments, fn fragment ->
      :ssl.send(socket, chunk(fragment))
      if delay > 0, do: Process.sleep(delay)
    end)

    case Keyword.get(options, :close_after, :never) do
      :done -> :ssl.send(socket, "0\r\n\r\n")
      :abruptly -> :ssl.close(socket)
      :never -> :ok
    end
  end

  defp chunk(fragment) do
    size = fragment |> byte_size() |> Integer.to_string(16)
    "#{size}\r\n#{fragment}\r\n"
  end

  defp refusal({code, reason}, options) do
    body = Keyword.get(options, :body, "")
    content_type = Keyword.get(options, :content_type, "application/json")

    "HTTP/1.1 #{code} #{reason}\r\n" <>
      "content-type: #{content_type}\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <> body
  end
end
