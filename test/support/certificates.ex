defmodule Hue.Certificates do
  @moduledoc """
  Synthetic certificates shaped like a Hue bridge's, for the pinning tests.

  A bridge certificate is unusual in exactly one way that matters here: the
  common name is the bridge id, and there is **no subjectAltName at all**. These
  fixtures reproduce that shape — `C=NL, O=Philips Hue, CN=<bridge id>`, no SAN —
  so the pinning path is exercised against the condition it exists to handle.

  Two issuing shapes are covered, because they take different branches:

    * **self-signed** (`0011223344556677`, `00AABBCCDDEEFF00`, `FFFFFFFFFFFFFFFF`)
      arrives as `{:bad_cert, :selfsigned_peer}`.
    * **signed by an absent authority** (`00178800AABBCCDD`, issued by
      `CN=root-bridge`) arrives as `{:bad_cert, :unknown_ca}`. This is the real
      hardware shape: the issuer exists but is never sent and cannot be
      downloaded, so `bridge_issuing_ca.der` is deliberately kept out of the
      trust store in every test but the one that studies what happens when a CA
      *is* supplied.

  They are generated once with `openssl` and committed as DER, rather than
  assembled from ASN.1 records at runtime. Hand-built records track OTP's
  internal `public_key` shapes and break when those shift; committed bytes do
  not. They contain no real bridge data.

      openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -sha256 \\
        -subj "/C=NL/O=Philips Hue/CN=<bridge id>" \\
        -keyout <key> -outform DER -out bridge_<bridge id>.der

  The expected fingerprints below come from `openssl x509 -fingerprint -sha256`,
  not from `Hue.Transport`, so the fingerprint test compares against an
  independent implementation instead of restating the one under test.

  The `.key.der` files are the matching private keys, so the pinning tests can
  stand up a real TLS listener and prove the handshake behaves. They are
  throwaway test keys for certificates no bridge will ever present.
  """

  @dir Path.join(__DIR__, "fixtures/certificates")

  @fingerprints %{
    "0011223344556677" => "21cdf48f5217f21923a498576d01c31d800424dafef70efc259f1e05134f3274",
    "00AABBCCDDEEFF00" => "48fb79eeb1a24847b67340475d7d9d260847b7f3361d57587c761ae9f17d8f22",
    "FFFFFFFFFFFFFFFF" => "19b0176ff5be4461cf15626db089ad5ce1af401f6cc5798055522a9a04d466e1",
    "without_common_name" => "bc12a3a5645be5d4a1e7a9d31cf0c23110674a32ec50812507dcc5bfd94ed5df",
    "00178800AABBCCDD" => "2b7a4fb5984f1995bc687fa1099ae5c5e50c84784c4fefcd026b7f215b04e6f3",
    "issuing_ca" => "6283ffec7437b7fe7f9dad0cb983a24b06871b244a1d98b5eaf302431d646f52"
  }

  @doc "Returns `{der, fingerprint}` for the certificate with the given common name."
  def bridge_certificate(common_name \\ "0011223344556677") do
    {der(common_name), Map.fetch!(@fingerprints, common_name)}
  end

  @doc "The DER bytes of the certificate with the given common name."
  def der(common_name) do
    File.read!(Path.join(@dir, "bridge_#{common_name}.der"))
  end

  @doc "The private key of the certificate with the given common name, as DER."
  def key(common_name) do
    File.read!(Path.join(@dir, "bridge_#{common_name}.key.der"))
  end

  @doc """
  The same certificate decoded into the `OTPCertificate` record that OTP's
  `:ssl` hands to a `verify_fun` alongside the DER.
  """
  def otp_certificate(common_name \\ "0011223344556677") do
    :public_key.pkix_decode_cert(der(common_name), :otp)
  end

  @doc """
  Runs a one-shot TLS listener presenting the given bridge certificate and
  returns its port. The listener serves a single handshake and then goes away
  with the test.
  """
  def start_bridge_listener(common_name \\ "0011223344556677", options \\ []) do
    chain = if options[:chain], do: [cacerts: [der("issuing_ca")]], else: []

    {:ok, listen} =
      :ssl.listen(
        0,
        [
          cert: der(common_name),
          key: {:PrivateKeyInfo, key(common_name)},
          reuseaddr: true,
          active: false
        ] ++ chain
      )

    {:ok, {_address, port}} = :ssl.sockname(listen)

    acceptor =
      spawn(fn ->
        with {:ok, socket} <- :ssl.transport_accept(listen, 5000) do
          :ssl.handshake(socket, 5000)
        end
      end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :ssl.close(listen)
    end)

    port
  end

  @default_body ~s({"data":[]})

  @doc """
  Runs a TLS listener presenting the given bridge certificate that answers any
  request with a fixed JSON body, and returns its port.

  Enough of an HTTP server for a client to make a real request through Req,
  Finch, and Mint against a certificate shaped like a bridge's — which is the
  only way to observe what the TLS options do once those three have merged
  their own defaults into them.

  ## Options

    * `:body` — the JSON body to answer with. Defaults to `#{@default_body}`.
    * `:status` — the status code and reason phrase for the status line, as a
      tuple. Defaults to `{200, "OK"}`.

  The listener also tolerates a client that completes the handshake and
  disconnects without sending a request, which is exactly what
  `Hue.Transport.capture_certificate/3` does at first contact.
  """
  def start_bridge_https_listener(common_name \\ "0011223344556677", options \\ []) do
    {:ok, listen} =
      :ssl.listen(0,
        cert: der(common_name),
        key: {:PrivateKeyInfo, key(common_name)},
        reuseaddr: true,
        active: false,
        packet: :raw,
        mode: :binary
      )

    {:ok, {_address, port}} = :ssl.sockname(listen)

    response = response(options)
    acceptor = spawn(fn -> serve(listen, response) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :ssl.close(listen)
    end)

    port
  end

  defp response(options) do
    body = Keyword.get(options, :body, @default_body)
    {code, reason} = Keyword.get(options, :status, {200, "OK"})

    "HTTP/1.1 #{code} #{reason}\r\n" <>
      "content-type: application/json\r\n" <>
      "content-length: #{byte_size(body)}\r\n" <>
      "connection: close\r\n\r\n" <> body
  end

  defp serve(listen, response) do
    with {:ok, pending} <- :ssl.transport_accept(listen, 5000),
         {:ok, socket} <- :ssl.handshake(pending, 5000),
         {:ok, _request} <- :ssl.recv(socket, 0, 5000) do
      :ssl.send(socket, response)
      :ssl.close(socket)
    end

    serve(listen, response)
  end
end
