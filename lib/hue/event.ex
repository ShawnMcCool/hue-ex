defmodule Hue.Event do
  @moduledoc """
  One resource change.

  A bridge frame nests two arrays deep — a list of envelopes, each holding a
  list of changed resources — and this struct is the flattened result: one
  struct per changed resource, carrying its envelope's identity.

  ## `data` is a delta, not a resource

  Only the fields that changed arrive, plus identity. An observed light event
  carried `%{"on" => %{"on" => true}}` and nothing else: no brightness, no
  colour, no name. Merge it into known state; never treat it as the whole
  resource, and never conclude from a missing key that the value was cleared.

  ## Two different meanings of "type"

  `type` is the envelope's — what happened to the resource. `resource_type` is
  the resource's — what kind of thing it is. One frame carries both, spelled
  the same way, one array layer apart: `"update"` on the envelope, `"light"` on
  the resource.

  ## Why either can be a string

  Both are turned into atoms only when this library already knows the value.
  Anything else stays the binary the bridge sent, because a bridge — or
  something answering as one — names these, and `String.to_atom/1` on a name
  from the network grows a table that is never collected.

  Unrecognised values are left distinct rather than folded into a single
  `:unknown`: two resource types this library has not heard of are two
  different kinds of thing, and a consumer bucketing by `resource_type` would
  otherwise merge them.
  """

  @typedoc "What happened. `add`, `update`, `delete`, and `error` are what CLIP v2 defines."
  @type envelope_type :: :add | :update | :delete | :error | String.t() | nil

  @typedoc "What kind of resource changed, as an atom when this library knows the type."
  @type resource_type :: atom() | String.t() | nil

  @type t :: %__MODULE__{
          type: envelope_type(),
          resource_type: resource_type(),
          rid: String.t() | nil,
          data: map(),
          owner: map() | nil,
          id: String.t() | nil,
          creationtime: String.t() | nil
        }

  defstruct [:type, :resource_type, :rid, :data, :owner, :id, :creationtime]
end
