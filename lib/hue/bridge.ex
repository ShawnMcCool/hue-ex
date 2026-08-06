defmodule Hue.Bridge do
  @moduledoc "Namespace for bridge identity. Layer 1 defines only `Hue.Bridge.Info`."

  defmodule Info do
    @moduledoc """
    An identified bridge: where it is, which one it is, and the certificate that
    was pinned when it was first trusted.

    `discovered_by` records which method found it — useful because mDNS silently
    finds nothing on routed networks, and telling those cases apart matters when
    a user reports "it can't find my bridge".
    """

    @type t :: %__MODULE__{
            host: String.t(),
            port: pos_integer(),
            bridge_id: String.t() | nil,
            model_id: String.t() | nil,
            fingerprint: String.t() | nil,
            discovered_by: :mdns | :cloud | :manual | nil
          }

    defstruct [:host, :bridge_id, :model_id, :fingerprint, :discovered_by, port: 443]
  end
end
