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

  test "verify_pinned/4 accepts an unknown CA when the fingerprint matches" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()
    otp = Hue.Certificates.otp_certificate()

    assert {:valid, ^fingerprint} =
             Transport.verify_pinned(otp, der, {:bad_cert, :selfsigned_peer}, fingerprint)

    assert {:valid, ^fingerprint} =
             Transport.verify_pinned(otp, der, {:bad_cert, :unknown_ca}, fingerprint)
  end

  test "verify_pinned/4 fails closed when the certificate changed" do
    {der, _} = Hue.Certificates.bridge_certificate("0011223344556677")
    otp = Hue.Certificates.otp_certificate("0011223344556677")
    {_other, other_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")

    assert {:fail, :certificate_changed} =
             Transport.verify_pinned(otp, der, {:bad_cert, :unknown_ca}, other_fingerprint)
  end

  test "verify_pinned/4 rejects genuinely bad certificates regardless of the pin" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()
    otp = Hue.Certificates.otp_certificate()

    assert {:fail, _} =
             Transport.verify_pinned(otp, der, {:bad_cert, :cert_expired}, fingerprint)
  end

  test "verify_pinned/4 defers on extensions it does not understand" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()
    otp = Hue.Certificates.otp_certificate()

    assert {:unknown, ^fingerprint} =
             Transport.verify_pinned(otp, der, {:extension, :undefined}, fingerprint)
  end

  test "verify_pinned/4 fails closed on an event it does not recognise" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()
    otp = Hue.Certificates.otp_certificate()

    assert {:fail, :unexpected_verification_event} =
             Transport.verify_pinned(otp, der, :something_new_in_a_later_otp, fingerprint)
  end

  test "ssl_options/1 pins when given a fingerprint" do
    options = Transport.ssl_options(fingerprint: "abc123")

    assert options[:verify] == :verify_peer
    assert {fun, "abc123"} = options[:verify_fun]
    assert is_function(fun, 4)
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

  # "I made a typo" must not be spelled the same as "verify nothing".
  describe "ssl_options/1 refuses to degrade silently" do
    test "a misspelled option raises rather than disabling verification" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Transport.ssl_options(finegrprint: "abc123")
      end
    end

    test "verify: :none alongside a fingerprint raises rather than discarding the pin" do
      assert_raise ArgumentError, ~r/contradicts/, fn ->
        Transport.ssl_options(verify: :none, fingerprint: "abc123")
      end
    end

    test "a verify value other than :none raises" do
      assert_raise ArgumentError, ~r/only value is :none/, fn ->
        Transport.ssl_options(verify: :verify_peer)
      end
    end

    test "a non-string fingerprint raises" do
      assert_raise ArgumentError, ~r/hex string/, fn ->
        Transport.ssl_options(fingerprint: :abc123)
      end
    end
  end

  describe "a peer that verified normally" do
    test "still has to match the pin" do
      {der, _} = Hue.Certificates.bridge_certificate("0011223344556677")
      otp = Hue.Certificates.otp_certificate("0011223344556677")
      {_other, other_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")

      assert {:fail, :certificate_changed} =
               Transport.verify_pinned(otp, der, :valid_peer, other_fingerprint)
    end

    test "is accepted when it matches the pin" do
      {der, fingerprint} = Hue.Certificates.bridge_certificate()
      otp = Hue.Certificates.otp_certificate()

      assert {:valid, ^fingerprint} = Transport.verify_pinned(otp, der, :valid_peer, fingerprint)
    end

    test "does not drag an intermediate through the pin check" do
      {der, fingerprint} = Hue.Certificates.bridge_certificate()
      otp = Hue.Certificates.otp_certificate()
      {other, _} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")
      other_otp = Hue.Certificates.otp_certificate("FFFFFFFFFFFFFFFF")

      assert {:valid, ^fingerprint} = Transport.verify_pinned(otp, der, :valid, fingerprint)

      assert {:valid, ^fingerprint} =
               Transport.verify_pinned(other_otp, other, :valid, fingerprint)
    end
  end

  describe "the real hardware shape: a leaf signed by an absent authority" do
    test "carries the bridge id in its common name" do
      {der, _} = Hue.Certificates.bridge_certificate("00178800AABBCCDD")

      assert Transport.common_name(der) == "00178800AABBCCDD"
    end

    test "is issued by an authority that is never sent" do
      {ca_der, _} = Hue.Certificates.bridge_certificate("issuing_ca")

      assert Transport.common_name(ca_der) == "root-bridge"
    end

    test "is accepted on unknown_ca when the fingerprint matches" do
      {der, fingerprint} = Hue.Certificates.bridge_certificate("00178800AABBCCDD")
      otp = Hue.Certificates.otp_certificate("00178800AABBCCDD")

      assert {:valid, ^fingerprint} =
               Transport.verify_pinned(otp, der, {:bad_cert, :unknown_ca}, fingerprint)
    end

    test "fails closed on unknown_ca when the fingerprint does not" do
      {der, _} = Hue.Certificates.bridge_certificate("00178800AABBCCDD")
      otp = Hue.Certificates.otp_certificate("00178800AABBCCDD")
      {_other, other_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")

      assert {:fail, :certificate_changed} =
               Transport.verify_pinned(otp, der, {:bad_cert, :unknown_ca}, other_fingerprint)
    end
  end

  test "common_name/1 reads a decoded certificate as well as DER" do
    record = Hue.Certificates.otp_certificate("00AABBCCDDEEFF00")

    assert Transport.common_name(record) == "00AABBCCDDEEFF00"
  end

  test "common_name/1 is nil for a subject that carries none" do
    {der, _} = Hue.Certificates.bridge_certificate("without_common_name")

    assert Transport.common_name(der) == nil
  end

  describe "against a real TLS handshake" do
    @describetag :capture_log

    setup do
      %{connect: &:ssl.connect(~c"127.0.0.1", &1, &2 ++ [active: false], 5000)}
    end

    test "OTP hands verify_pinned the exact bytes that crossed the wire", %{connect: connect} do
      {der, fingerprint} = Hue.Certificates.bridge_certificate()
      port = Hue.Certificates.start_bridge_listener()
      test_process = self()

      capture = fn _otp, wire_der, event, state ->
        send(test_process, {:wire, wire_der, event})
        {:valid, state}
      end

      assert {:ok, socket} =
               connect.(port,
                 verify: :verify_peer,
                 cacerts: [],
                 depth: 0,
                 verify_fun: {capture, fingerprint}
               )

      :ssl.close(socket)

      assert_receive {:wire, ^der, {:bad_cert, :selfsigned_peer}}
    end

    test "the pinned options accept the bridge that matches", %{connect: connect} do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()
      port = Hue.Certificates.start_bridge_listener()

      assert {:ok, socket} = connect.(port, Transport.ssl_options(fingerprint: fingerprint))

      :ssl.close(socket)
    end

    test "the pinned options refuse a bridge whose certificate changed", %{connect: connect} do
      {_other, wrong_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")
      port = Hue.Certificates.start_bridge_listener()

      assert {:error, {:tls_alert, {:handshake_failure, message}}} =
               connect.(port, Transport.ssl_options(fingerprint: wrong_fingerprint))

      assert to_string(message) =~ "certificate_changed"
    end

    test "the real hardware shape connects when pinned", %{connect: connect} do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate("00178800AABBCCDD")
      port = Hue.Certificates.start_bridge_listener("00178800AABBCCDD")

      assert {:ok, socket} = connect.(port, Transport.ssl_options(fingerprint: fingerprint))

      :ssl.close(socket)
    end

    test "the real hardware shape is refused when the pin does not match", %{connect: connect} do
      {_other, wrong_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")
      port = Hue.Certificates.start_bridge_listener("00178800AABBCCDD")

      assert {:error, {:tls_alert, {:handshake_failure, message}}} =
               connect.(port, Transport.ssl_options(fingerprint: wrong_fingerprint))

      assert to_string(message) =~ "certificate_changed"
    end

    # Documents why the :valid_peer branch cannot be reached through
    # ssl_options/1, and why customize_hostname_check does not do what its name
    # suggests: a SAN-less certificate reached by IP loses its reference ids
    # before the match fun is consulted.
    test "a trusted CA still cannot produce valid_peer over IP", %{connect: connect} do
      {ca_der, _} = Hue.Certificates.bridge_certificate("issuing_ca")
      port = Hue.Certificates.start_bridge_listener("00178800AABBCCDD")
      test_process = self()

      capture = fn _otp, _der, event, state ->
        send(test_process, {:event, event})
        {:valid, state}
      end

      assert {:ok, socket} =
               connect.(port,
                 verify: :verify_peer,
                 cacerts: [ca_der],
                 depth: 2,
                 verify_fun: {capture, :state},
                 customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
               )

      :ssl.close(socket)

      assert_receive {:event, {:bad_cert, :hostname_check_failed}}
      refute_received {:event, :valid_peer}
    end
  end
end
