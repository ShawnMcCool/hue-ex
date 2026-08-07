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

  ## A stream drop and a server crash are not the same failure, on purpose

  Losing the eventstream (Task 8) leaves the cache serving its last known
  state, stale but trustworthy — reconnecting is an expected condition on a
  home network, not evidence the cached data is wrong. A `Hue.Bridge.Server`
  crash is different: it is a bug, and the ETS table dies with the process
  that owned it (the table is not named-and-heir-protected — nothing survives
  the crash to keep it alive). The replacement server starts clean and
  resyncs, so readers briefly see `:not_started` rather than the last state a
  now-dead process wrote.

  That is the correct trade, not an oversight. State written by a process that
  then crashed is exactly the state you should not keep serving — a crash
  means something about the sync was already wrong, not merely delayed. An
  heir process could preserve the table across the crash, but that buys
  continuity at the price of possibly-corrupt state, in exchange for
  surviving a case (a crash) that should not happen in the first place. Clean
  restart plus resync is the honest response; only a stream drop earns "stale
  beats nothing."

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

  # A flapping bridge (503s, timeouts) never reaches this budget: sync/1
  # handles those without crashing, via its own Process.send_after retry.
  # This budget is for genuine bugs in the server or its children — the
  # signal that something is structurally broken, not merely offline — so it
  # stays tight rather than tolerant.
  @max_restarts 3
  @max_seconds 60

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
    Supervisor.init(children,
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
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

  @doc """
  Resolves a room or zone target to the `grouped_light` that acts for it.

  A thin delegation to `Hue.Bridge.Graph.grouped_light/3`, kept beside
  `resolve/3` rather than left for `Hue.Room` and `Hue.Zone` (Task 14) to
  reach `Graph` directly. `table/1` is `@doc false` — an internal seam, not
  public API — so anything outside this module that needs the graph walk
  would otherwise have to go around that boundary to get it. One entry point
  for the public surface; everything else stays private.
  """
  @spec grouped_light(atom(), :room | :zone, String.t()) :: {:ok, map()} | {:error, Error.t()}
  def grouped_light(name \\ @default_name, type, target),
    do: Graph.grouped_light(table(name), type, target)

  @doc "Every resource of one type."
  @spec list(atom(), atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(name \\ @default_name, type), do: Cache.list(table(name), type)

  @doc "The name a rid is known by, or `nil`."
  @spec name_of(atom(), atom(), String.t()) :: String.t() | nil
  def name_of(name \\ @default_name, type, rid), do: Cache.name_of(table(name), type, rid)

  @doc """
  Subscribes the calling process to this bridge's events.

  Delivers `{:hue, %Hue.Event{}}`. The subscription is removed automatically
  when the calling process dies — `Registry` monitors it — so a LiveView that
  crashes leaves nothing behind.

  ## Filters

      Hue.Bridge.subscribe(bridge)                 # everything
      Hue.Bridge.subscribe(bridge, type: :button)   # just switches
      Hue.Bridge.subscribe(bridge, name: "Iris")    # one light, by its device's name
      Hue.Bridge.subscribe(bridge, rid: rid)        # one resource, by identity

  Filtering happens at the registry rather than in your `handle_info`. A
  process waiting on button presses is not in the dispatch list for a light
  event at all, so it is not woken when a scene runs and nineteen lights
  change.

  Subscribing again with the **same** filter is a no-op: you get one
  subscription, not two. The registry is `:duplicate`, so without that check a
  second `subscribe/2` adds a second entry and doubles every matching event
  **permanently** — and a single `unsubscribe/2` then removes both, leaving no
  way back to single delivery short of unsubscribing and starting again.

  The case it protects is one process subscribing more than once: a callback
  that re-runs whatever set the subscription up, or several components sharing
  a process and each asking for the same events. A process that subscribes and
  then dies is *not* that case — `Registry` monitors it and removes the entry
  regardless.

  Subscribing with **different** filters is a genuinely different subscription
  each time — an event matching both delivers twice, because that is what you
  asked for.

  ## A note on names

  An event is matched against the name the resource had **before** the event
  was applied. For everything except a rename these are the same. For a
  rename, the event is delivered to subscribers of the old name and
  subsequent events to the new — which is what a subscriber who asked about
  "Iris" would expect to see.
  """
  @spec subscribe(atom(), keyword()) :: :ok | {:error, Error.t()}
  def subscribe(name \\ @default_name, filter \\ []) do
    # subscription_key/1 is called outside the try: an unrecognised filter is
    # a caller bug (see Hue.Error's "never used for an argument that could
    # not have been valid") and must raise, never be caught by the guard
    # below meant for "no bridge is running." A function-level `rescue`
    # would catch both — subscription_key/1 raises the same ArgumentError
    # `Registry.lookup/2` does for a name with no registry — and silently
    # misreport a caller's malformed filter as :not_started even against a
    # live bridge.
    key = subscription_key(filter)

    try do
      if already_subscribed?(registry(name), key) do
        :ok
      else
        # This registry is `:duplicate`, which never answers
        # `{:error, {:already_registered, pid}}` — every `register/3` call
        # succeeds and adds its own entry, even from a process that is
        # already registered under this exact key. The idempotence
        # `mount/3` calling this twice needs has to be checked for above,
        # not read off this call's return value.
        {:ok, _owner} = Registry.register(registry(name), key, nil)
        :ok
      end
    rescue
      ArgumentError -> {:error, %Error{reason: :not_started}}
    end
  end

  # `self()` in a `:duplicate` registry's own entry list for this key, not
  # merely "someone is registered under this key" — a second process
  # subscribing with the same filter is a second, distinct subscription and
  # must still be delivered to.
  defp already_subscribed?(registry, key) do
    registry
    |> Registry.lookup(key)
    |> Enum.any?(fn {pid, _value} -> pid == self() end)
  end

  @doc "Removes a subscription registered with the same filter."
  @spec unsubscribe(atom(), keyword()) :: :ok
  def unsubscribe(name \\ @default_name, filter \\ []) do
    key = subscription_key(filter)

    try do
      Registry.unregister(registry(name), key)
    rescue
      ArgumentError -> :ok
    end
  end

  defp subscription_key([]), do: :all
  defp subscription_key(type: type), do: {:type, type}
  defp subscription_key(name: name), do: {:name, name}
  defp subscription_key(rid: rid), do: {:rid, rid}

  defp subscription_key(filter) do
    raise ArgumentError,
          "expected one of type:, name:, or rid:, or no filter at all, got: #{inspect(filter)}"
  end

  @doc false
  def table(name), do: Module.concat(name, Cache)
  @doc false
  def server(name), do: Module.concat(name, Server)
  @doc false
  def registry(name), do: Module.concat(name, Registry)
  @doc false
  def tasks(name), do: Module.concat(name, Tasks)
end
