defmodule Hue.Error do
  @moduledoc """
  A normalised failure from a Hue bridge.

  Three different wire formats end up here, and a client that assumes one of them
  breaks on the others:

    * **CLIP v2** puts the signal in the HTTP status and the detail in
      `{"errors":[{"description": …}]}`. There are **no numeric error codes** —
      reasons are derived from status, never from the prose.
    * **CLIP v2 auth failure** returns HTTP 403 with a `text/html` body. Decoding
      that as JSON crashes on the single most likely first-run failure.
    * **v1 pairing** returns HTTP 200 carrying
      `[{"error":{"type":101, …}}]` — application errors at 200, with numeric types.

  Match on `:reason`. It is stable across all three.

  ## What this struct does and does not mean

  An `Error` means something outside the process refused the call — the bridge or
  the transport — or that a locally-known capability makes the call impossible.
  It is never used for an argument that could not have been valid: `brightness:
  "loud"` is a caller bug and raises.

  The reason worth handling explicitly is `:unauthorized`. It means no valid
  application key was sent. Get one with `Hue.Pairing.pair/2` after pressing the
  round link button on the bridge.
  """

  @type reason ::
          :unauthorized
          | :link_button_not_pressed
          | :not_found
          | :rate_limited
          | :bridge_busy
          | :unsupported_bridge
          | :certificate_changed
          | :bridge_identity_mismatch
          | :unexpected_verification_event
          | :not_dimmable
          | :not_color_capable
          | :invalid_gamut
          | :no_grouped_light
          | :timeout
          | :econnrefused
          | :closed
          | :nxdomain
          | :unexpected_response
          | :unknown

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          description: String.t() | nil,
          type: integer() | nil,
          rid: String.t() | nil
        }

  defexception [:reason, :status, :description, :type, :rid]

  @statuses %{
    400 => :bad_request,
    401 => :unauthorized,
    403 => :unauthorized,
    404 => :not_found,
    405 => :method_not_allowed,
    409 => :conflict,
    429 => :rate_limited,
    500 => :bridge_error,
    503 => :bridge_busy,
    507 => :insufficient_storage
  }

  @pairing_types %{101 => :link_button_not_pressed}

  # The complete set of terms Hue.Transport.verify_pinned/4 fails with. Kept as
  # strings because that is the form they come back in, and matched exactly so
  # nothing else can be mistaken for them. See from_transport/1.
  @verify_fun_reasons ~w(certificate_changed unexpected_verification_event)

  @doc """
  Builds an error from a CLIP v2 response.

  `content_type` matters: the bridge answers an unauthenticated request with an
  HTML page, so the body is only parsed when it claims to be JSON.
  """
  @spec from_response(pos_integer(), binary(), String.t() | nil, keyword()) :: t()
  def from_response(status, body, content_type, opts \\ []) do
    %__MODULE__{
      reason: Map.get(@statuses, status, :unknown),
      status: status,
      description: describe(body, content_type),
      rid: opts[:rid]
    }
  end

  @doc """
  Builds an error from the v1 pairing envelope, which arrives at HTTP 200.

  Requires the body to be a list whose first element is
  `%{"error" => %{"type" => integer}}` — not merely a list with an `"error"`
  key present. An `"error"` value with no `"type"`, a non-map `"error"`
  value, an empty list, or a body that is not a list at all all raise
  `FunctionClauseError`. Checking for the presence of an `"error"` key is
  necessary but not sufficient before calling this; callers must confirm the
  full shape, not just route on `"error"` versus `"success"`.
  """
  @spec from_pairing(list() | map()) :: t()
  def from_pairing([%{"error" => error} | _]), do: from_pairing(error)

  def from_pairing(%{"type" => type} = error) do
    %__MODULE__{
      reason: Map.get(@pairing_types, type, :unknown),
      status: 200,
      description: error["description"],
      type: type
    }
  end

  @doc "Builds an error for a failure below the application layer."
  @spec transport(atom(), keyword()) :: t()
  def transport(reason, opts \\ []) when is_atom(reason) do
    %__MODULE__{reason: reason, description: opts[:description]}
  end

  @doc """
  Builds an error from whatever Req handed back in an `{:error, _}`.

  Every request path in this library goes through here, because the reason Req
  carries is not always an atom, and the one case where it is not is the most
  security-relevant failure the library can report.

  ## Why the pin needs unwrapping

  When `Hue.Transport.verify_pinned/4` refuses a certificate it returns
  `{:fail, :certificate_changed}`. `:ssl` turns that into a fatal alert, and
  Mint surfaces it as `%Mint.TransportError{reason: {:tls_alert,
  {:handshake_failure, text}}}` — a **tuple**. Handed to `transport/2` that
  raises `FunctionClauseError`; guarded away with `is_atom` it degrades to
  `:unknown`. Either way the one failure `Hue.Transport` documents as "your
  bridge was replaced or you are being intercepted" never reaches a caller in
  a form they can match on.

  OTP appends the refused term to the alert text on a line of its own, so the
  original reason is recoverable, and the two terms this library's `verify_fun`
  can fail with are mapped back to themselves.

  ## Why the match is narrow

  Reporting a benign failure as an interception is the same class of mistake as
  reporting a differently-formatted fingerprint as one. So the trailing line
  must **equal** one of those terms rather than merely contain it, and every
  other alert stays `:unknown` with its text intact. A server-sent
  `protocol_version` or `insufficient_security`, and a `handshake_failure`
  carrying any other term — `hostname_check_failed` and `cert_expired` both
  arrive through this same wrapping — are negotiation or certificate problems,
  not evidence that anything was swapped.

  ## Why it tolerates two spellings of that line

  `ssl_alert.erl` carries two adjacent formatters for the same alert:
  `own_alert_format_depth/1` renders `" ~s\\n ~P"`, putting the refused term
  bare on the last line, while `own_alert_format/1` ten lines above renders
  `" ~s\\n - ~p"`, which inspects the atom and so prints `- :certificate_changed`.
  Which one produced the text handed to this function is not ours to choose, and
  a parser coupled to one of them degrades the other to `:unknown`. So a leading
  `- ` and a leading `:` are stripped, and trailing blank lines are skipped,
  before an equality comparison that is otherwise unchanged.
  """
  @spec from_transport(Exception.t() | %{reason: term()}) :: t()
  def from_transport(%{reason: {:tls_alert, {_type, text}}}) do
    # chardata rather than List.to_string/1: :ssl and Mint both hand back a
    # charlist, measured, but this is the function whose whole job is that the
    # one failure it must never lose does not get lost, and raising on a binary
    # would lose it.
    description = IO.chardata_to_string(text)

    %__MODULE__{reason: refused_term(description), description: description}
  end

  def from_transport(%{reason: reason}) when is_atom(reason) do
    %__MODULE__{reason: reason}
  end

  def from_transport(%{reason: reason}) do
    %__MODULE__{reason: :unknown, description: inspect(reason)}
  end

  def from_transport(exception) do
    %__MODULE__{reason: :unknown, description: Exception.message(exception)}
  end

  defp refused_term(description) do
    refused =
      description
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> List.last("")
      |> unprefix()

    if refused in @verify_fun_reasons do
      String.to_existing_atom(refused)
    else
      :unknown
    end
  end

  # Folds the two formatters' spellings together — and nothing else. This stays
  # a prefix strip rather than becoming a search: a line that merely mentions
  # one of these terms must not be read as one.
  defp unprefix(line) do
    line |> String.trim_leading("- ") |> String.trim_leading(":")
  end

  defp describe(body, "application/json" <> _) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, %{"errors" => [%{"description" => description} | _]}} -> description
      _ -> nil
    end
  end

  defp describe(_body, _content_type), do: nil

  @impl true
  def message(%__MODULE__{} = error) do
    [status_part(error), error.description]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" - ")
  end

  defp status_part(%{reason: reason, status: nil}), do: to_string(reason)
  defp status_part(%{reason: reason, status: status}), do: "#{reason} (HTTP #{status})"
end
