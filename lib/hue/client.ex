defmodule Hue.Client do
  @moduledoc """
  A configured connection to one bridge.

  Holds a `Req.Request`, which is deliberate: consumers inject `plug:` for test
  stubs and set their own timeout and retry policy, so this library invents no
  configuration system of its own.

  ## Never set `:connect_options` on the request

  The pinned TLS options live at
  `req.options[:connect_options][:transport_opts]`, and `Req.merge/2`
  **replaces** `:connect_options` wholesale rather than merging into it. So

      Req.request(client.req, connect_options: [timeout: 1_000])

  discards `:transport_opts` along with it and connects unverified, silently.
  `Hue.new/2` guards its own construction and cannot guard this. Pass
  `:connect_options` to `Hue.new/2` instead, where they are merged and a
  `:transport_opts` among them is refused. Nothing in this library may forward
  a caller's `:connect_options` onto a request either.

  For the same reason a caller cannot bring their own Finch pool:
  `finch: [name: MyFinch]` raises `cannot set both :finch and :connect_options`,
  because the pinned options are what the pool is keyed on and built from.

  ## What the redaction covers

  `Inspect` prints the application key as `[REDACTED]`, which keeps it out of
  ordinary inspect output — Logger, IEx, and the formatting of exceptions that
  carry a client. That is the whole of the guarantee. `inspect(client,
  structs: false)` prints the raw struct, and an `erl_crash.dump` writes heap
  terms with no involvement from `Inspect` at all.
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
