defmodule Hue.Bridge do
  @moduledoc """
  A live model of one bridge: an ETS-backed cache seeded by a full fetch and
  kept current by the eventstream.

  ## It never starts itself

  This is a `child_spec/1` you place in your own supervision tree, the way
  Finch, Redix, and Postgrex are. A library that starts processes on
  application boot has decided something that belongs to its consumer.

      children = [
        {Hue.Bridge, name: MyApp.Hue, client: client}
      ]

  ## Reads bypass the process

  `fetch/3`, `list/2`, and `fetch_by_name/3` are `:ets.lookup` calls executed in
  **your** process. They do not message the server, do not serialise against
  each other, and do not queue behind an eventstream frame being merged. This is
  the difference between a cache and a cache-shaped bottleneck.

  Writes are the opposite, and deliberately so — see `Hue.Light.set/3`.

  ## Status

  `status/1` reports `:connecting`, `:syncing`, `:live`, `{:error, reason}`, or
  `:not_started` when nothing is running under that name. Note that `:live` and
  readability are different questions: a bridge that synced and then lost its
  stream keeps serving its last known state while reporting the error, because
  state that is seconds stale beats no state at all.

  ## Options

    * `:name` — the name this bridge is addressed by. Defaults to `Hue.Bridge`.
    * `:client` — a `Hue.Client` from `Hue.new/2` or `Hue.from_bridge/2`. Required.
    * `:retry_after` — milliseconds between failed sync attempts. Defaults to 5 seconds.
  """

  use Supervisor

  alias Hue.Bridge.Cache
  alias Hue.Bridge.Graph
  alias Hue.Error

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

  @default_name __MODULE__

  @doc """
  Builds this bridge's child spec, `:id`ed by its `:name` rather than the
  module.

  `use Supervisor` generates a default `child_spec/1` whose `:id` is
  `__MODULE__` — fine for a singleton, but multiple bridges are multiple named
  children in one consumer's tree, and two children both `:id`ed `Hue.Bridge`
  collide the moment the second one is added. Keying `:id` on `:name` instead
  is what makes

      children = [
        {Hue.Bridge, name: MyApp.LivingRoomHue, client: client_a},
        {Hue.Bridge, name: MyApp.OfficeHue, client: client_b}
      ]

  start both, with no special casing anywhere else in this module.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(options) do
    name = Keyword.get(options, :name, @default_name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [options]},
      type: :supervisor
    }
  end

  @doc "Starts a bridge. See the moduledoc for options."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options) do
    name = Keyword.get(options, :name, @default_name)
    Supervisor.start_link(__MODULE__, Keyword.put(options, :name, name), name: name)
  end

  @impl Supervisor
  def init(options) do
    name = Keyword.fetch!(options, :name)

    children = [
      {Registry, keys: :duplicate, name: registry(name)},
      {Task.Supervisor, name: tasks(name)},
      {Hue.Bridge.Server,
       options
       |> Keyword.put(:server_name, server(name))
       |> Keyword.put(:table, table(name))}
    ]

    # :rest_for_one, because the server holds the names of the registry and the
    # task supervisor. If either restarts, the server's assumptions about them
    # are stale and it must restart too. The reverse is not true.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 60)
  end

  @doc "What the bridge's connection is currently doing."
  @spec status(atom()) :: Cache.status() | :not_started
  def status(name \\ @default_name), do: Cache.status(table(name))

  @doc "Fetches one resource by rid."
  @spec fetch(atom(), atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def fetch(name \\ @default_name, type, rid), do: Cache.fetch(table(name), type, rid)

  @doc "Fetches one resource by the name a user sees in the Hue app."
  @spec fetch_by_name(atom(), atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def fetch_by_name(name \\ @default_name, type, target),
    do: Cache.fetch_by_name(table(name), type, target)

  @doc "Resolves a name-or-rid target to the resource it names."
  @spec resolve(atom(), atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(name \\ @default_name, type, target), do: Graph.resolve(table(name), type, target)

  @doc "Every resource of one type."
  @spec list(atom(), atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(name \\ @default_name, type), do: Cache.list(table(name), type)

  @doc "The name a rid is known by, or `nil`."
  @spec name_of(atom(), atom(), String.t()) :: String.t() | nil
  def name_of(name \\ @default_name, type, rid), do: Cache.name_of(table(name), type, rid)

  @doc false
  def table(name), do: Module.concat(name, Cache)
  @doc false
  def server(name), do: Module.concat(name, Server)
  @doc false
  def registry(name), do: Module.concat(name, Registry)
  @doc false
  def tasks(name), do: Module.concat(name, Tasks)
end
