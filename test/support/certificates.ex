defmodule Hue.Certificates do
  @moduledoc """
  Synthetic certificates shaped like a Hue bridge's, for the pinning tests.

  A bridge certificate is unusual in exactly one way that matters here: the
  common name is the bridge id, and there is **no subjectAltName at all**. These
  fixtures reproduce that shape — `C=NL, O=Philips Hue, CN=<bridge id>`,
  self-signed, no SAN — so the pinning path is exercised against the condition it
  exists to handle.

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

  `bridge_0011223344556677.key.der` is the matching private key, so the pinning
  tests can stand up a real TLS listener and prove the handshake behaves. It is a
  throwaway test key for a certificate no bridge will ever present.
  """

  @dir Path.join(__DIR__, "fixtures/certificates")

  @fingerprints %{
    "0011223344556677" => "21cdf48f5217f21923a498576d01c31d800424dafef70efc259f1e05134f3274",
    "00AABBCCDDEEFF00" => "48fb79eeb1a24847b67340475d7d9d260847b7f3361d57587c761ae9f17d8f22",
    "FFFFFFFFFFFFFFFF" => "19b0176ff5be4461cf15626db089ad5ce1af401f6cc5798055522a9a04d466e1",
    "without_common_name" => "bc12a3a5645be5d4a1e7a9d31cf0c23110674a32ec50812507dcc5bfd94ed5df"
  }

  @doc "Returns `{der, fingerprint}` for the certificate with the given common name."
  def bridge_certificate(common_name \\ "0011223344556677") do
    {der(common_name), Map.fetch!(@fingerprints, common_name)}
  end

  @doc "The DER bytes of the certificate with the given common name."
  def der(common_name) do
    File.read!(Path.join(@dir, "bridge_#{common_name}.der"))
  end

  @doc """
  The same certificate decoded into the `OTPCertificate` record that OTP's
  `:ssl` hands to a `verify_fun`.
  """
  def otp_certificate(common_name \\ "0011223344556677") do
    :public_key.pkix_decode_cert(der(common_name), :otp)
  end

  @doc """
  Runs a one-shot TLS listener presenting the bridge certificate and returns its
  port. The listener serves a single handshake and then goes away with the test.
  """
  def start_bridge_listener do
    {:ok, listen} =
      :ssl.listen(0,
        cert: der("0011223344556677"),
        key: {:PrivateKeyInfo, File.read!(Path.join(@dir, "bridge_0011223344556677.key.der"))},
        reuseaddr: true,
        active: false
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
end
