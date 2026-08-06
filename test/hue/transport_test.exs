defmodule Hue.TransportTest do
  use ExUnit.Case, async: true

  alias Hue.Transport

  test "fingerprint/1 is a stable lowercase sha256 hex digest" do
    {der, expected} = Hue.Certificates.bridge_certificate()

    assert Transport.fingerprint(der) == expected
    assert Transport.fingerprint(der) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "common_name/1 extracts the bridge id from the subject" do
    {der, _} = Hue.Certificates.bridge_certificate("00AABBCCDDEEFF00")

    assert Transport.common_name(der) == "00AABBCCDDEEFF00"
  end

  test "verify_pinned/3 accepts an unknown CA when the fingerprint matches" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()

    assert {:valid, ^fingerprint} =
             Transport.verify_pinned(der, {:bad_cert, :selfsigned_peer}, fingerprint)

    assert {:valid, ^fingerprint} =
             Transport.verify_pinned(der, {:bad_cert, :unknown_ca}, fingerprint)
  end

  test "verify_pinned/3 fails closed when the certificate changed" do
    {der, _} = Hue.Certificates.bridge_certificate("0011223344556677")
    {_other, other_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")

    assert {:fail, :certificate_changed} =
             Transport.verify_pinned(der, {:bad_cert, :unknown_ca}, other_fingerprint)
  end

  test "verify_pinned/3 rejects genuinely bad certificates regardless of the pin" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()

    assert {:fail, _} = Transport.verify_pinned(der, {:bad_cert, :cert_expired}, fingerprint)
  end

  test "verify_pinned/3 defers on extensions it does not understand" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()

    assert {:unknown, ^fingerprint} =
             Transport.verify_pinned(der, {:extension, :undefined}, fingerprint)
  end

  test "ssl_options/1 pins when given a fingerprint" do
    options = Transport.ssl_options(fingerprint: "abc123")

    assert options[:verify] == :verify_peer
    assert {fun, "abc123"} = options[:verify_fun]
    assert is_function(fun, 3)
  end

  test "ssl_options/1 disables verification only when explicitly asked" do
    assert Transport.ssl_options(verify: :none)[:verify] == :verify_none
  end

  test "ssl_options/1 is unverified before a fingerprint exists to pin to" do
    assert Transport.ssl_options()[:verify] == :verify_none
  end

  test "ssl_options/1 supplies no CA store, because trust comes from the pin" do
    assert Transport.ssl_options(fingerprint: "abc123")[:cacerts] == []
  end

  # OTP's :ssl hands verify_fun a decoded OTPCertificate record, not DER bytes.
  # Everything below the API must therefore accept both forms.
  describe "the certificate form OTP actually passes" do
    test "fingerprint/1 agrees across the DER and record forms" do
      {der, expected} = Hue.Certificates.bridge_certificate()

      assert Transport.fingerprint(Hue.Certificates.otp_certificate()) == expected
      assert Transport.fingerprint(der) == expected
    end

    test "common_name/1 reads the record form" do
      record = Hue.Certificates.otp_certificate("00AABBCCDDEEFF00")

      assert Transport.common_name(record) == "00AABBCCDDEEFF00"
    end

    test "verify_pinned/3 matches the pin against the record form" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()
      record = Hue.Certificates.otp_certificate()

      assert {:valid, ^fingerprint} =
               Transport.verify_pinned(record, {:bad_cert, :selfsigned_peer}, fingerprint)

      assert {:fail, :certificate_changed} =
               Transport.verify_pinned(record, {:bad_cert, :unknown_ca}, "nope")
    end
  end

  describe "a peer that verified normally" do
    test "still has to match the pin, because hostname checking is off" do
      {der, _} = Hue.Certificates.bridge_certificate("0011223344556677")
      {_other, other_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")

      assert {:fail, :certificate_changed} =
               Transport.verify_pinned(der, :valid_peer, other_fingerprint)
    end

    test "is accepted when it matches the pin" do
      {der, fingerprint} = Hue.Certificates.bridge_certificate()

      assert {:valid, ^fingerprint} = Transport.verify_pinned(der, :valid_peer, fingerprint)
    end

    test "does not drag an intermediate through the pin check" do
      {der, fingerprint} = Hue.Certificates.bridge_certificate()
      {other, _} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")

      assert {:valid, ^fingerprint} = Transport.verify_pinned(der, :valid, fingerprint)
      assert {:valid, ^fingerprint} = Transport.verify_pinned(other, :valid, fingerprint)
    end
  end

  test "common_name/1 is nil for a subject that carries none" do
    {der, _} = Hue.Certificates.bridge_certificate("without_common_name")

    assert Transport.common_name(der) == nil
  end

  describe "against a real TLS handshake" do
    @describetag :capture_log

    test "the pinned options accept the bridge that matches" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()
      port = Hue.Certificates.start_bridge_listener()

      assert {:ok, socket} =
               :ssl.connect(
                 ~c"127.0.0.1",
                 port,
                 Transport.ssl_options(fingerprint: fingerprint) ++ [active: false],
                 5000
               )

      :ssl.close(socket)
    end

    test "the pinned options refuse a bridge whose certificate changed" do
      {_other, wrong_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")
      port = Hue.Certificates.start_bridge_listener()

      assert {:error, {:tls_alert, {:handshake_failure, message}}} =
               :ssl.connect(
                 ~c"127.0.0.1",
                 port,
                 Transport.ssl_options(fingerprint: wrong_fingerprint) ++ [active: false],
                 5000
               )

      assert to_string(message) =~ "certificate_changed"
    end
  end
end
