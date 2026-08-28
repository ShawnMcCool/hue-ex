defmodule Hue.TransportTest do
  use ExUnit.Case, async: true

  alias Hue.Transport

  # A real SHA-256 digest, because a fingerprint is now required to be one.
  @pin "21cdf48f5217f21923a498576d01c31d800424dafef70efc259f1e05134f3274"

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
    options = Transport.ssl_options(fingerprint: @pin)

    assert options[:verify] == :verify_peer
    assert {fun, @pin} = options[:verify_fun]
    assert is_function(fun, 4)
  end

  test "ssl_options/1 disables verification only when explicitly asked" do
    assert Transport.ssl_options(verify: :none)[:verify] == :verify_none
  end

  test "ssl_options/1 is unverified before a fingerprint exists to pin to" do
    assert Transport.ssl_options()[:verify] == :verify_none
  end

  test "ssl_options/1 supplies no CA store, because trust comes from the pin" do
    assert Transport.ssl_options(fingerprint: @pin)[:cacerts] == []
  end

  # "I made a typo" must not be spelled the same as "verify nothing".
  describe "ssl_options/1 refuses to degrade silently" do
    test "a misspelled option raises rather than disabling verification" do
      assert_raise ArgumentError, ~r/unknown option/, fn ->
        Transport.ssl_options(finegrprint: @pin)
      end
    end

    test "verify: :none alongside a fingerprint raises rather than discarding the pin" do
      assert_raise ArgumentError, ~r/contradicts/, fn ->
        Transport.ssl_options(verify: :none, fingerprint: @pin)
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

    test "a fingerprint that is not hex raises, as the message promises" do
      assert_raise ArgumentError, ~r/hex string/, fn ->
        Transport.ssl_options(fingerprint: "not-hex-at-all")
      end
    end

    test "a non-list argument raises ArgumentError rather than FunctionClauseError" do
      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Transport.ssl_options(%{fingerprint: @pin})
      end
    end

    # A keyword list reads its first match, so the second of these is dropped.
    # Which one is dropped is exactly the question a pin must not be vague about.
    test "an option given twice raises rather than using the first quietly" do
      assert_raise ArgumentError, ~r/more than once/, fn ->
        Transport.ssl_options(fingerprint: @pin, fingerprint: String.reverse(@pin))
      end
    end

    test "an option given twice is not reported as an unknown option" do
      message =
        assert_raise ArgumentError, fn ->
          Transport.ssl_options(fingerprint: @pin, fingerprint: @pin)
        end

      refute Exception.message(message) =~ "unknown option"
    end
  end

  # openssl prints `21:CD:F4:…`. Comparing that to fingerprint/1's output byte
  # for byte fails, and this library reports that failure as
  # :certificate_changed — "you are being intercepted". A transcription format
  # must not be spelled the same as an attack.
  describe "normalize_fingerprint/1 accepts every form a pin is plausibly pasted in" do
    test "lowercase hex, which is what fingerprint/1 emits" do
      assert Transport.normalize_fingerprint(@pin) == @pin
    end

    test "uppercase hex" do
      assert Transport.normalize_fingerprint(String.upcase(@pin)) == @pin
    end

    test "the colon-separated uppercase form openssl prints" do
      openssl = @pin |> String.upcase() |> colon_separated()

      assert Transport.normalize_fingerprint(openssl) == @pin
    end

    test "the colon-separated lowercase form" do
      assert Transport.normalize_fingerprint(colon_separated(@pin)) == @pin
    end

    test "any of those with surrounding whitespace" do
      assert Transport.normalize_fingerprint("  #{String.upcase(@pin)}\n") == @pin
    end

    test "and the pinned options carry the normalised form, whichever was given" do
      openssl = @pin |> String.upcase() |> colon_separated()

      assert {_fun, @pin} = Transport.ssl_options(fingerprint: openssl)[:verify_fun]
    end
  end

  describe "normalize_fingerprint/1 requires a whole digest" do
    test "a short hex string raises, rather than pinning to a prefix" do
      assert_raise ArgumentError, ~r/64-character hex string/, fn ->
        Transport.normalize_fingerprint("abc")
      end

      assert_raise ArgumentError, ~r/64-character hex string/, fn ->
        Transport.normalize_fingerprint(String.slice(@pin, 0..62))
      end
    end

    test "a long hex string raises" do
      assert_raise ArgumentError, ~r/64-character hex string/, fn ->
        Transport.normalize_fingerprint(@pin <> "a")
      end
    end

    test "a non-string raises ArgumentError rather than FunctionClauseError" do
      assert_raise ArgumentError, ~r/hex string/, fn ->
        Transport.normalize_fingerprint(:abcd)
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

    # A resumed session presents no certificate, so verify_fun never runs and
    # the pin is never consulted. Every other handshake test here uses a
    # one-shot listener on a fresh port, so no session ever survives for there
    # to be anything to resume — which is exactly why this bypass reached real
    # hardware unnoticed. These two need a listener that stays up.
    test "a wrong pin cannot ride in on a session an earlier connection established" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()
      {_other, wrong_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")
      port = Hue.Certificates.start_bridge_https_listener()

      assert {:ok, first} = tls_connect(port, fingerprint)
      :ssl.close(first)

      assert {:error, {:tls_alert, {:handshake_failure, message}}} =
               tls_connect(port, wrong_fingerprint)

      assert to_string(message) =~ "certificate_changed"
    end

    test "two pinned connections to one bridge negotiate two distinct sessions" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()
      port = Hue.Certificates.start_bridge_https_listener()

      assert session_id(port, fingerprint) != session_id(port, fingerprint)
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

    # Documents why customize_hostname_check does not do what its name suggests:
    # the match fun is only consulted against identifiers the certificate
    # presents. Reached by IP, a SAN-less certificate presents none — and since
    # OTP 28.5 removed the CN-id fallback, it presents none for any kind of
    # reference id — so hostname_check_failed pre-empts valid_peer. The
    # hostname check is one of the two things gating the :valid_peer branch;
    # chain length is the other, covered by the tests below.
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

    # The :valid_peer branch is gated by chain length and the hostname check,
    # not by the empty CA store: path validation promotes an untrusted chain's
    # head to the anchor and recurses over the remainder, so one certificate
    # leaves nothing to validate. These two tests are why that branch must not
    # be deleted.
    test "one certificate produces no peer event at all" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()
      port = Hue.Certificates.start_bridge_listener()

      assert observe_events(port, fingerprint) == [{:bad_cert, :selfsigned_peer}]
    end

    test "a chain reached by name produces valid_peer, and the pin fails it closed" do
      # Pinned to the issuer, so validation gets past the chain head and reaches
      # the leaf. The leaf carries a subjectAltName because it must: OTP 28.5
      # removed the CN-id fallback, and a SAN-less leaf fails the hostname
      # check closed before :valid_peer can fire. The leaf is not what was
      # pinned, and this branch is what catches that.
      {_ca_der, ca_fingerprint} = Hue.Certificates.bridge_certificate("with_san_issuing_ca")
      port = Hue.Certificates.start_bridge_listener("with_san", chain: "with_san_issuing_ca")

      assert :valid_peer in observe_events(port, ca_fingerprint, ~c"localhost")

      assert {:fail, :certificate_changed} =
               Transport.verify_pinned(
                 Hue.Certificates.otp_certificate("with_san"),
                 Hue.Certificates.der("with_san"),
                 :valid_peer,
                 ca_fingerprint
               )
    end
  end

  describe "capture_certificate/3" do
    @describetag :capture_log

    test "returns the exact bytes the server presented" do
      {der, fingerprint} = Hue.Certificates.bridge_certificate()
      port = Hue.Certificates.start_bridge_listener()

      assert {:ok, captured} = Transport.capture_certificate("127.0.0.1", port)

      assert captured == der
      assert Transport.fingerprint(captured) == fingerprint
      assert Transport.common_name(captured) == "0011223344556677"
    end

    test "captures a certificate signed by an authority it has never heard of" do
      {der, fingerprint} = Hue.Certificates.bridge_certificate("00178800AABBCCDD")
      port = Hue.Certificates.start_bridge_listener("00178800AABBCCDD")

      assert {:ok, ^der} = Transport.capture_certificate("127.0.0.1", port)
      assert Transport.fingerprint(der) == fingerprint
    end

    test "the pin it produces is the one ssl_options/1 then accepts" do
      port = Hue.Certificates.start_bridge_https_listener()

      assert {:ok, der} = Transport.capture_certificate("127.0.0.1", port)

      {:ok, client} =
        Hue.new("127.0.0.1", port: port, fingerprint: Transport.fingerprint(der), retry: false)

      assert {:ok, %Req.Response{status: 200}} =
               Req.request(Req.merge(client.req, method: :get, url: client.base_url))
    end

    test "reports a refused connection rather than raising" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert {:error, reason} = Transport.capture_certificate("127.0.0.1", port, timeout: 1_000)
      assert reason in [:econnrefused, :timeout]
    end

    test "it does not weaken what ssl_options/1 hands out" do
      # The capture path uses the no-fingerprint branch as-is, so nothing about
      # the pinned branch can drift as a side effect of capturing.
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()

      assert Transport.ssl_options() ==
               [verify: :verify_none, reuse_sessions: false, session_tickets: :disabled]

      assert Keyword.fetch!(Transport.ssl_options(fingerprint: fingerprint), :verify) ==
               :verify_peer
    end
  end

  defp tls_connect(port, fingerprint) do
    :ssl.connect(
      ~c"127.0.0.1",
      port,
      Transport.ssl_options(fingerprint: fingerprint) ++ [active: false],
      5000
    )
  end

  defp session_id(port, fingerprint) do
    {:ok, socket} = tls_connect(port, fingerprint)
    {:ok, information} = :ssl.connection_information(socket, [:session_id])
    :ssl.close(socket)
    information[:session_id]
  end

  # Connects with ssl_options/1's exact output, wrapping verify_fun only to
  # record events; it still delegates to verify_pinned/4 unchanged, so what is
  # observed is what the real options do.
  defp observe_events(port, fingerprint, host \\ ~c"127.0.0.1") do
    test_process = self()

    options =
      Keyword.update!(
        Transport.ssl_options(fingerprint: fingerprint),
        :verify_fun,
        fn {_fun, state} ->
          {fn certificate, der, event, pinned ->
             send(test_process, {:observed, event})
             Transport.verify_pinned(certificate, der, event, pinned)
           end, state}
        end
      )

    case :ssl.connect(host, port, options ++ [active: false], 5000) do
      {:ok, socket} -> :ssl.close(socket)
      {:error, _reason} -> :ok
    end

    collect_observed([])
  end

  # `21cdf4…` -> `21:cd:f4:…`, the layout openssl prints a digest in.
  defp colon_separated(fingerprint) do
    fingerprint |> String.graphemes() |> Enum.chunk_every(2) |> Enum.map_join(":", &Enum.join/1)
  end

  defp collect_observed(acc) do
    receive do
      {:observed, event} -> collect_observed([event | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end
end
