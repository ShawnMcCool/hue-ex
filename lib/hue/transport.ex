defmodule Hue.Transport do
  @moduledoc """
  TLS for Hue bridges, which cannot be verified the ordinary way.

  A bridge presents a certificate whose common name is its bridge id, with **no
  subjectAltName**, signed by a Signify root that is neither sent on the wire nor
  publicly downloadable. Hostname verification therefore cannot succeed — there
  is no name to match — and there is no certificate authority to bundle.

  This module pins instead: the first connection records the certificate's
  SHA-256 fingerprint, and every connection afterwards requires the same one.
  That is the SSH host-key model. It does not detect an attacker present during
  the very first contact, and the README says so — but it detects every
  interception after it, which is more than any other Hue client does.

  A changed fingerprint means either a factory-reset bridge or an interception,
  and those are indistinguishable from here, so it fails closed.

  ## Learning the fingerprint

  `ssl_options/1` with no `:fingerprint` returns unverified options. That is the
  first-contact connection, and the only one that should ever run without a pin:
  connect, read the certificate, store `fingerprint/1` of it against the bridge
  id from `common_name/1`, and pin every connection after that.
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

  @typedoc "A certificate as DER bytes, or as the record OTP's `:ssl` passes to a `verify_fun`."
  @type certificate :: binary() | tuple()

  @doc "The SHA-256 fingerprint of a certificate, lowercase hex."
  @spec fingerprint(certificate()) :: String.t()
  def fingerprint(certificate) do
    :sha256 |> :crypto.hash(der(certificate)) |> Base.encode16(case: :lower)
  end

  @doc """
  The common name of a certificate, which on a bridge is its bridge id.

  Returns `nil` for a certificate whose subject carries no common name.
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
  The `:ssl` `verify_fun` callback.

  Accepts an unknown or self-signed issuer only when the certificate's
  fingerprint matches the pin. The pin is also enforced on a peer certificate
  that verified normally — hostname checking is disabled for these connections,
  so a chain that merely validates proves nothing about *which* host answered.
  """
  @spec verify_pinned(certificate(), term(), String.t()) ::
          {:valid, String.t()} | {:unknown, String.t()} | {:fail, term()}
  def verify_pinned(certificate, event, pinned) do
    case event do
      {:bad_cert, reason} when reason in [:unknown_ca, :selfsigned_peer] ->
        match_pin(certificate, pinned)

      {:bad_cert, reason} ->
        {:fail, reason}

      {:extension, _extension} ->
        {:unknown, pinned}

      :valid_peer ->
        match_pin(certificate, pinned)

      :valid ->
        {:valid, pinned}
    end
  end

  @doc """
  Builds `:ssl` options.

  ## Options

    * `:fingerprint` — pin to this certificate. The normal path.
    * `:verify` — pass `:none` to disable verification entirely. This is what
      every other Hue client does; it is never the default here.

  With neither, verification is off: that is first contact, before a fingerprint
  exists to pin to.

  No CA store is supplied. Trust comes from the pin, and handing the connection
  the system roots as well would only widen what `:ssl` is willing to accept.

  `depth: 0` is load-bearing rather than incidental. A bridge sends exactly one
  certificate — its leaf — so the certificate `:ssl` reports as unverifiable is
  always the one the pin describes. Refusing longer chains keeps that true: a
  bridge that someday sends an intermediate fails loudly here instead of quietly
  comparing the pin against the wrong certificate.
  """
  @spec ssl_options(keyword()) :: keyword()
  def ssl_options(options \\ []) do
    fingerprint = options[:fingerprint]

    if options[:verify] == :none or is_nil(fingerprint) do
      [verify: :verify_none]
    else
      [
        verify: :verify_peer,
        cacerts: [],
        depth: 0,
        verify_fun: {&__MODULE__.verify_pinned/3, fingerprint},
        customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
      ]
    end
  end

  defp match_pin(certificate, pinned) do
    if fingerprint(certificate) == pinned do
      {:valid, pinned}
    else
      {:fail, :certificate_changed}
    end
  end

  defp der(certificate) when is_binary(certificate), do: certificate

  defp der(certificate) when Record.is_record(certificate, :OTPCertificate) do
    :public_key.pkix_encode(:OTPCertificate, certificate, :otp)
  end

  defp decode(certificate) when is_binary(certificate) do
    :public_key.pkix_decode_cert(certificate, :otp)
  end

  defp decode(certificate) when Record.is_record(certificate, :OTPCertificate), do: certificate

  # A DirectoryString reaches us tagged with the ASN.1 string type it was encoded
  # as. Which one varies by issuer: OpenSSL writes utf8String and returns a
  # binary, a PKIX-masked issuer writes printableString and returns a charlist,
  # and an attribute constrained to one type (countryName) arrives untagged.
  defp directory_string({tag, value})
       when tag in [:utf8String, :printableString, :teletexString, :universalString, :bmpString],
       do: to_string(value)

  defp directory_string(value) when is_binary(value), do: value
  defp directory_string(value) when is_list(value), do: to_string(value)
  defp directory_string(_value), do: nil
end
