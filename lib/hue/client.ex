defmodule Hue.Client do
  @moduledoc """
  A configured connection to one bridge.

  Holds a `Req.Request`, which is deliberate: consumers inject `plug:` for test
  stubs and set their own timeout and retry policy, so this library invents no
  configuration system of its own.

  The application key is redacted by `Inspect` so it cannot reach logs or crash
  dumps.
  """

  @type t :: %__MODULE__{
          base_url: String.t(),
          application_key: String.t() | nil,
          bridge_id: String.t() | nil,
          fingerprint: String.t() | nil,
          req: Req.Request.t()
        }

  defstruct [:base_url, :application_key, :bridge_id, :fingerprint, :req]
end

defimpl Inspect, for: Hue.Client do
  import Inspect.Algebra

  def inspect(client, opts) do
    fields = [
      base_url: client.base_url,
      bridge_id: client.bridge_id,
      application_key: if(client.application_key, do: "[REDACTED]"),
      fingerprint: client.fingerprint
    ]

    concat(["#Hue.Client<", to_doc(fields, opts), ">"])
  end
end
