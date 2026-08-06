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

  ## Learning the fingerprint

  `ssl_options/1` with no `:fingerprint` returns unverified options. That is the
  first-contact connection, and the only one that should ever run without a pin:
  connect, read the certificate with `:ssl.peercert/1`, store `fingerprint/1` of
  it against the bridge id from `common_name/1`, and pin every connection after
  that.
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
  A peer that verified normally is also held to the pin: a chain that validates
  proves the certificate came from some trusted authority, not that it came from
  *this* bridge. That branch is unreachable under the options `ssl_options/1`
  builds, which trust no authority at all, but it is what stops a pin from being
  bypassed if a CA store is ever introduced alongside one.

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

    * `:fingerprint` — pin to this certificate. The normal path.
    * `:verify` — pass `:none` to disable verification entirely. This is what
      every other Hue client does; it is never the default here.

  With neither, verification is off: that is first contact, before a fingerprint
  exists to pin to. Anything else raises. In a library whose job is to verify,
  a typo in an option name must not quietly mean "verify nothing", so unknown
  keys and the contradictory `verify: :none` alongside a `:fingerprint` are
  rejected rather than resolved.

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
  def ssl_options(options \\ []) when is_list(options) do
    validate_options!(options)
    fingerprint = options[:fingerprint]

    if is_nil(fingerprint) do
      [verify: :verify_none]
    else
      [
        verify: :verify_peer,
        cacerts: [],
        depth: 0,
        verify_fun: {&__MODULE__.verify_pinned/4, fingerprint},
        customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
      ]
    end
  end

  defp validate_options!(options) do
    case Keyword.keys(options) -- @known_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown option(s) #{inspect(unknown)} for Hue.Transport"
    end

    validate_verify!(Keyword.fetch(options, :verify), options[:fingerprint])
    validate_fingerprint!(options[:fingerprint])
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

  defp validate_fingerprint!(nil), do: :ok
  defp validate_fingerprint!(fingerprint) when is_binary(fingerprint), do: :ok

  defp validate_fingerprint!(other) do
    raise ArgumentError, "fingerprint must be a hex string, got #{inspect(other)}"
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
