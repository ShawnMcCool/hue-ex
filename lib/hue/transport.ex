defmodule Hue.Transport do
  @moduledoc """
  TLS for Hue bridges, which cannot be verified the ordinary way.

  A bridge presents a certificate whose common name is its bridge id, with **no
  subjectAltName**, signed by a Signify root that is neither sent on the wire nor
  publicly downloadable. There is no name to match and no certificate authority
  to bundle, so ordinary verification cannot succeed. Every other Hue client
  responds by turning verification off.

  This module pins instead: the first connection records the certificate's
  SHA-256 fingerprint, and every connection afterwards requires the same one.
  That is the SSH host-key model.

  ## What pinning does and does not protect

  It does **not** protect the very first connection. Whatever answers at that
  moment becomes the trusted certificate, so an attacker already in position
  during first contact is pinned rather than caught. Pair over a network you
  trust. Every interception *after* first contact is detected, which is more than
  an unverified client can say.

  A changed fingerprint means either a factory-reset bridge or an interception,
  and those are indistinguishable from here, so it fails closed.

  ## Session resumption is disabled, deliberately

  Every connection here performs a full handshake. `:ssl` would otherwise cache a
  successful session and resume it for the next connection to the same
  `host:port` — and a resumed session presents **no certificate**, so
  `verify_fun` is never called and the pin is never consulted. That turned a pin
  into a one-shot check: once any connection to a bridge succeeded, a second
  client with a completely wrong fingerprint resumed that session and talked to
  the bridge, with no alert and no error. Verified against real hardware, and
  invisible to a fixture suite because each synthetic listener gets a fresh port
  and so has no session to resume.

  The cost is a full handshake — a few extra round trips and one RSA
  verification — on every connection instead of only the first. Against a
  bridge on the local network that is negligible, and the alternative is a pin
  that stops being enforced after the first connection, which is no pin at all.

  ## Learning the fingerprint

  `ssl_options/1` with no `:fingerprint` returns unverified options. That is the
  first-contact connection, and the only one that should ever run without a pin:
  connect, read the certificate with `:ssl.peercert/1`, store `fingerprint/1` of
  it against the bridge id from `common_name/1`, and pin every connection after
  that.

  `capture_certificate/3` is that connection, packaged. `Hue.Discovery.identify/2`
  makes it once per bridge and pins everything afterwards — including its own
  `/api/config` request — to what came back.
  """

  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  @common_name_oid {2, 5, 4, 3}
  @known_options [:fingerprint, :verify]
  @fingerprint_length 64
  @capture_timeout 5_000

  # A resumed TLS session presents no certificate, so `verify_fun` is never
  # called and the pin is never consulted. Both options are needed because the
  # two protocol versions resume differently: `reuse_sessions` covers TLS 1.2
  # session ids, `session_tickets` covers TLS 1.3 PSK tickets. The latter
  # already defaults to `:disabled` for clients; it is stated anyway so the
  # guarantee survives a change of default.
  @no_resumption [reuse_sessions: false, session_tickets: :disabled]

  @typedoc "A certificate as DER bytes, or as the record OTP's `:ssl` passes to a `verify_fun`."
  @type certificate :: binary() | tuple()

  @doc """
  The SHA-256 fingerprint of a DER-encoded certificate, lowercase hex.

  Takes DER bytes rather than a decoded certificate on purpose. The pin has to
  describe the bytes that crossed the wire, and re-encoding a decoded record to
  recover them would make the pin depend on OTP's encoder reproducing its own
  decoder exactly.
  """
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der) when is_binary(der) do
    :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)
  end

  @doc """
  Folds the forms a fingerprint is plausibly written in into the one
  `fingerprint/1` produces: lowercase, unseparated hex.

  A pin is copied from somewhere, and the obvious source prints something else.
  `openssl x509 -fingerprint -sha256` emits `21:CD:F4:8F:…` — uppercase, colon
  separated. Comparing that to `fingerprint/1`'s output byte for byte fails, and
  `verify_pinned/4` reports that failure as `:certificate_changed`, which this
  module documents as "your bridge was replaced or you are being intercepted".
  A library that fails closed and is authoritative about why must not spell a
  transcription format the same as an attack, so the forms are folded together
  here rather than compared as typed.

  Accepts, all yielding the same pin: lowercase hex, uppercase hex, either with
  `:` separators, and any of those with surrounding whitespace.

  Anything that is not then exactly #{@fingerprint_length} hex characters raises.
  A SHA-256 digest has one length, and a pin shorter than the digest is a pin
  that matches more certificates than the one it was taken from.
  """
  @spec normalize_fingerprint(String.t()) :: String.t()
  def normalize_fingerprint(fingerprint) when is_binary(fingerprint) do
    normalized =
      fingerprint |> String.trim() |> String.replace(":", "") |> String.downcase()

    if String.match?(normalized, ~r/\A[0-9a-f]{#{@fingerprint_length}}\z/) do
      normalized
    else
      raise ArgumentError,
            "fingerprint must be a #{@fingerprint_length}-character hex string, " <>
              "optionally colon-separated, got #{inspect(fingerprint)}"
    end
  end

  def normalize_fingerprint(other) do
    raise ArgumentError, "fingerprint must be a hex string, got #{inspect(other)}"
  end

  @doc """
  The common name of a certificate, which on a bridge is its bridge id.

  Accepts DER bytes or a decoded `OTPCertificate`. Returns `nil` for a
  certificate whose subject carries no common name.
  """
  @spec common_name(certificate()) :: String.t() | nil
  def common_name(certificate) do
    otp_certificate(tbsCertificate: tbs) = decode(certificate)
    otp_tbs_certificate(subject: {:rdnSequence, relative_names}) = tbs

    relative_names
    |> List.flatten()
    |> Enum.find_value(fn
      {:AttributeTypeAndValue, @common_name_oid, value} -> directory_string(value)
      _other -> nil
    end)
  end

  @doc """
  The `:ssl` `verify_fun` callback, in OTP's four-argument form.

  OTP hands this both the decoded certificate and the exact DER bytes it was
  decoded from (`ssl_handshake.erl`, `apply_fun/5`, which dispatches on
  `is_function(Fun, 4)`). The pin is compared against those bytes.

  An unknown or self-signed issuer is accepted only when the fingerprint matches.
  A peer that verified normally is also held to the pin: a validated path proves
  the certificate was issued by an authority the path accepted, not that it came
  from *this* bridge.

  **Do not fold `:valid_peer` in with `:valid`, and do not delete it as dead
  code.** It does not fire while a bridge sends a single certificate, but the
  reason is chain length, not the absence of a CA store: `pkix_path_validation/3`
  handles an untrusted chain by promoting its head to the trust anchor and
  recursing over whatever remains, so a one-certificate chain leaves nothing to
  validate and produces no peer event at all. That holds with or without
  `cacerts`.

  Once the chain is longer and validation gets past its head, the leaf arrives as
  `:valid_peer`, and this branch is the only thing still comparing it to the pin.
  Reaching it also depends on connecting by name rather than by address: for a
  certificate with no subjectAltName an IP reference id is dropped before
  hostname matching, so `:ssl` reports `hostname_check_failed` first, whereas a
  DNS reference id falls back to CN-ids and lets `:valid_peer` through. Neither
  condition is exotic — `Hue.Discovery` returns mDNS `.local` names, and nothing
  here controls what a caller connects to.

  Unrecognised events fail closed rather than raising.
  """
  @spec verify_pinned(tuple(), binary(), term(), String.t()) ::
          {:valid, String.t()} | {:unknown, String.t()} | {:fail, term()}
  def verify_pinned(_certificate, der, event, pinned) do
    case event do
      {:bad_cert, reason} when reason in [:unknown_ca, :selfsigned_peer] ->
        match_pin(der, pinned)

      {:bad_cert, reason} ->
        {:fail, reason}

      {:extension, _extension} ->
        {:unknown, pinned}

      :valid_peer ->
        match_pin(der, pinned)

      :valid ->
        {:valid, pinned}

      _unrecognised ->
        {:fail, :unexpected_verification_event}
    end
  end

  @doc """
  Builds `:ssl` options.

  ## Options

    * `:fingerprint` — pin to this certificate, in any form
      `normalize_fingerprint/1` accepts. The normal path.
    * `:verify` — pass `:none` to disable verification entirely. This is what
      every other Hue client does; it is never the default here.

  With neither, verification is off: that is first contact, before a fingerprint
  exists to pin to. Anything else raises. In a library whose job is to verify,
  a typo in an option name must not quietly mean "verify nothing", so unknown
  keys, a key given twice — only the first of which would be read — and the
  contradictory `verify: :none` alongside a `:fingerprint` are all rejected
  rather than resolved.

  ## Why the pinned options look the way they do

  `cacerts: []` supplies no trust anchors. Trust comes from the pin, and handing
  the connection the system roots as well would only widen what `:ssl` accepts
  before the pin is ever consulted.

  `depth: 0` allows no intermediates. A bridge sends exactly one certificate, so
  this costs nothing today. It is not, however, what keeps the pin aimed at the
  right certificate: OTP walks a chain from the top down, so a two-certificate
  chain reports `unknown_ca` against the **issuer**, and the pin would be
  compared against that issuer regardless of the depth setting. Depth only
  rejects chains of three or more. The practical consequence is worth stating
  plainly: if Signify firmware ever begins sending an intermediate, this code
  reports `:certificate_changed` — which reads as "your bridge was replaced or
  you are being intercepted" — for what is actually a benign update.

  `customize_hostname_check` cannot disable hostname verification here, contrary
  to how it is usually described. For a certificate with no subjectAltName
  reached by IP address, `public_key` drops IP reference ids before the match fun
  is consulted, so the check fails on an empty list and `:ssl` converts
  `valid_peer` into `{:bad_cert, :hostname_check_failed}` before this module sees
  it. It is retained only so that a pinned certificate which *does* chain to a
  supplied authority is still judged by its fingerprint instead of by a name it
  was never issued for.
  """
  @spec ssl_options(keyword()) :: keyword()
  def ssl_options(options \\ []) do
    validate_options!(options)

    case options[:fingerprint] do
      nil -> [verify: :verify_none] ++ @no_resumption
      fingerprint -> pinned_options(normalize_fingerprint(fingerprint))
    end
  end

  @doc """
  **First contact only.** Opens a TLS connection to `host:port` with
  verification off, reads the certificate the server presented, and closes.
  Returns the leaf certificate's DER bytes.

  This is the one call in the library that talks to a bridge without a pin, and
  it exists solely to produce the pin. Feed the result to `fingerprint/1` and
  `common_name/1`, store both, and use `ssl_options/1` with a `:fingerprint`
  from then on. It does not decide anything and it does not remember anything:
  deciding whether the certificate may be trusted is the caller's job, and on
  the first connection there is nothing to decide it against.

  Nothing about the pinned path changes as a result of this function existing.
  It borrows `ssl_options/1`'s no-fingerprint branch rather than assembling
  weaker options of its own, so there is exactly one definition of "unverified"
  in this module and no `verify_fun` anywhere that returns `:valid` without
  comparing a pin.

  Borrowing is also what keeps this correct rather than merely consistent: those
  options disable session resumption, and a capture that resumed a session would
  be handed a cached certificate instead of the one the server is presenting
  now. A function whose entire job is to observe the live certificate must never
  resume.

  It connects separately rather than reaching into the connection Req is about
  to make. Capturing during Req's own handshake would mean installing a
  `verify_fun` that accepts every certificate and records it as a side effect —
  a function whose whole purpose is to trust anything, sitting one keyword away
  from `verify_pinned/4` in a module about verification — and would additionally
  depend on `:ssl` running the callback in the calling process, which is a
  Finch/NimblePool implementation detail rather than a guarantee. The cost is
  one extra connection, once per bridge, ever.

  ## Options

    * `:timeout` — milliseconds to wait for the handshake. Defaults to
      `#{@capture_timeout}`.

  Returns `{:error, reason}` with `:ssl`'s own reason term for a connection or
  handshake that did not complete.
  """
  @spec capture_certificate(String.t(), :inet.port_number(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def capture_certificate(host, port, options \\ [])
      when is_binary(host) and is_integer(port) and port > 0 do
    timeout = Keyword.get(options, :timeout, @capture_timeout)
    connect_options = Keyword.put(ssl_options(), :active, false)

    case :ssl.connect(String.to_charlist(host), port, connect_options, timeout) do
      {:ok, socket} ->
        try do
          :ssl.peercert(socket)
        after
          :ssl.close(socket)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pinned_options(fingerprint) do
    [
      verify: :verify_peer,
      cacerts: [],
      depth: 0,
      verify_fun: {&__MODULE__.verify_pinned/4, fingerprint},
      customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
    ] ++ @no_resumption
  end

  defp validate_options!(options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, "expected a keyword list of options, got #{inspect(options)}"
    end

    keys = Keyword.keys(options)
    validate_known!(Enum.uniq(keys) -- @known_options)
    validate_unique!(keys -- Enum.uniq(keys))
    validate_verify!(Keyword.fetch(options, :verify), options[:fingerprint])
  end

  defp validate_known!([]), do: :ok

  defp validate_known!(unknown) do
    raise ArgumentError, "unknown option(s) #{inspect(unknown)} for Hue.Transport"
  end

  defp validate_unique!([]), do: :ok

  defp validate_unique!(duplicated) do
    raise ArgumentError,
          "option(s) #{inspect(Enum.uniq(duplicated))} given more than once — only the " <>
            "first of each would be read, so the rest would be silently ignored"
  end

  defp validate_verify!(:error, _fingerprint), do: :ok
  defp validate_verify!({:ok, :none}, nil), do: :ok

  defp validate_verify!({:ok, :none}, _fingerprint) do
    raise ArgumentError,
          "verify: :none contradicts a :fingerprint — pass one or the other, not both"
  end

  defp validate_verify!({:ok, other}, _fingerprint) do
    raise ArgumentError, "verify: #{inspect(other)} is not supported — the only value is :none"
  end

  defp match_pin(der, pinned) do
    if fingerprint(der) == pinned do
      {:valid, pinned}
    else
      {:fail, :certificate_changed}
    end
  end

  defp decode(certificate) when is_binary(certificate) do
    :public_key.pkix_decode_cert(certificate, :otp)
  end

  defp decode(certificate) when Record.is_record(certificate, :OTPCertificate), do: certificate

  # A commonName is a DirectoryString, so it reaches us tagged with whichever
  # ASN.1 string type its issuer chose to encode it as: OpenSSL writes
  # utf8String and yields a binary, a PKIX-masked issuer writes printableString
  # and yields a charlist.
  defp directory_string({tag, value})
       when tag in [:utf8String, :printableString, :teletexString, :universalString, :bmpString],
       do: to_string(value)

  defp directory_string(_value), do: nil
end
