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
          | :not_dimmable
          | :not_color_capable
          | :no_grouped_light
          | :timeout
          | :econnrefused
          | :closed
          | :nxdomain
          | :unknown
          | atom()

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
