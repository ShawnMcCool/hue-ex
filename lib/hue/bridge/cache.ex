defmodule Hue.Bridge.Cache do
  @moduledoc """
  The ETS table behind `Hue.Bridge`, and every path that reads it.

  ## Why the table is named, and why that matters

  The table is a **named** `:set`, `:protected`, with `read_concurrency: true`.
  Named, so a reader in any process finds it from the bridge's name alone —
  no `GenServer.call`, no lookup table, no message passing. `:protected`, so
  only the owning server can write to it. This is the whole reason `Hue.Bridge`
  is not the bottleneck that a cache-behind-a-GenServer becomes: nineteen
  LiveViews reading nineteen lights do not queue behind each other, and they do
  not queue behind an eventstream frame being merged.

  ## Two lifecycle facts, deliberately separate

  Both live in the table rather than in the server's state, so that reads can
  consult them without a call.

    * **Seeded** — has a full fetch ever completed? Until it has, reads return
      `:not_synced`, because an empty table and a bridge with no lights are
      indistinguishable from the outside and answering `{:ok, []}` would be a
      lie.
    * **Status** — what the connection is doing right now: `:connecting`,
      `:syncing`, `:live`, or `{:error, reason}`.

  They are not the same question. A bridge that synced an hour ago and lost its
  eventstream five seconds ago is `{:error, :closed}` **and** still readable:
  the cached state is stale by five seconds, which is far better than refusing
  to answer. `Hue.Bridge.status/1` is how a consumer learns the difference, and
  `[:hue, :stream, :disconnected]` is how it learns without asking.

  ## Never remove before inserting

  `seed/2` and `reindex/1` both replace a whole set of keys — every resource on
  a reseed, both name indexes on a reindex. An earlier version did that by
  deleting first and inserting after (`:ets.delete_all_objects/1`, or
  `:ets.match_delete/2` ahead of the rebuild). Since reads never go through
  this process, that opens a window any concurrent reader can land in: the
  table briefly looks unseeded, or a name that still exists briefly cannot be
  found. On a reconnect that window reproduces the exact lie this module
  promises not to tell — a bridge that synced an hour ago reporting
  `:not_synced`, indistinguishable from a bridge that has never synced.

  The fix is the same shape in both functions: **insert the new state first,
  then delete whatever key the new state does not contain.** A key that
  survives the reseed is overwritten in place and is never briefly absent. A
  key that does not survive is removed only after its replacement — the union
  of everything else — is already in the table, so the deletion is the only
  observable change and it is exactly the one the new state calls for.

  `@seeded_key` and `@status_key` are never candidates for either prune step —
  the match specs that find keys to delete can only match resource keys
  (`{type, rid}`) or index keys (`{:name, type, name}` / `{:rid_name, type,
  rid}`), the same structural guarantee documented under "Key shapes" below.
  No function in this module ever deletes `@seeded_key` or `@status_key` once
  set; `put_status/2` overwrites `@status_key` in place, and nothing removes
  it first.

  ## Key shapes

  | Key | Value |
  |---|---|
  | `{type, rid}` | the resource map |
  | `{:name, type, name}` | rid |
  | `{:rid_name, type, rid}` | name |
  | `:__seeded__` | `true` |
  | `:__status__` | the status term |

  Resource keys are two-tuples and index keys are three-tuples, so a match on
  `{{type, :"$1"}, :"$2"}` selects resources and nothing else.
  """

  alias Hue.Bridge.Merge
  alias Hue.Bridge.Names
  alias Hue.Error
  alias Hue.Event

  @seeded_key :__seeded__
  @status_key :__status__

  @type table :: atom()
  @type status :: :connecting | :syncing | :live | {:error, term()}

  @doc "Creates the table. Called by the owning server, and by nothing else."
  @spec new(table()) :: table()
  def new(table) do
    :ets.new(table, [:set, :named_table, :protected, read_concurrency: true])
    :ets.insert(table, {@status_key, :connecting})
    table
  end

  @doc """
  Replaces the cache's entire resource set with `resources` and rebuilds both
  name indexes, insert-then-prune throughout — see "Never remove before
  inserting" above. `@status_key` is never written here: it was never removed,
  so there is nothing to restore. `@seeded_key` is set last, so the *first*
  seed still gates reads as `:not_synced` right up until the table is actually
  populated; a reseed leaves it `true` throughout, because nothing before this
  final insert ever unset it.
  """
  @spec seed(table(), [map()]) :: :ok
  def seed(table, resources) when is_list(resources) do
    entries = Enum.map(resources, &{{type_of(&1), rid_of(&1)}, &1})
    keys = MapSet.new(entries, &elem(&1, 0))

    :ets.insert(table, entries)
    prune_resources(table, keys)

    reindex(table)

    :ets.insert(table, {@seeded_key, true})

    :ok
  end

  @doc """
  Applies one decoded eventstream event.

  `update` deep-merges (see `Hue.Bridge.Merge`), `add` inserts, `delete`
  removes, and `error` changes nothing — an error envelope describes a failure
  on the bridge, not a state transition, and the server surfaces it through
  telemetry and to subscribers instead.

  ## Why a rename rebuilds the whole index

  An event that changes `metadata.name` or `services` invalidates index entries
  that no longer have any resource pointing at them, and there is no cheap way
  to find them from the delta alone — a device rename orphans one entry per
  service it owns. Rebuilding both indexes from the table costs a walk of ~178
  resources, which is microseconds, and it is unconditionally correct. Renames
  are rare; a subtly stale name index would not be.
  """
  @spec apply_event(table(), Event.t()) :: :ok
  def apply_event(_table, %Event{type: :error}), do: :ok

  def apply_event(table, %Event{type: :delete, resource_type: type, rid: rid}) do
    :ets.delete(table, {type, rid})
    reindex(table)
  end

  def apply_event(table, %Event{type: type_of_change, resource_type: type, rid: rid, data: data})
      when type_of_change in [:add, :update] and is_map(data) do
    merged =
      case :ets.lookup(table, {type, rid}) do
        [{_key, cached}] -> Merge.merge(cached, data)
        [] -> data
      end

    :ets.insert(table, {{type, rid}, merged})

    if reindexing?(data), do: reindex(table), else: :ok
  end

  def apply_event(_table, %Event{}), do: :ok

  @doc "Records what the connection is doing. Purely informational; see the moduledoc."
  @spec put_status(table(), status()) :: :ok
  def put_status(table, status) do
    :ets.insert(table, {@status_key, status})
    :ok
  end

  @doc """
  Reports the connection's status, or `:not_started` when no bridge owns this
  table. Never raises, and never calls a process.
  """
  @spec status(table()) :: status() | :not_started
  def status(table) do
    case :ets.lookup(table, @status_key) do
      [{@status_key, status}] -> status
      [] -> :not_started
    end
  rescue
    ArgumentError -> :not_started
  end

  @doc "Fetches one resource by rid."
  @spec fetch(table(), atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def fetch(table, type, rid) do
    with :ok <- readable(table) do
      case :ets.lookup(table, {type, rid}) do
        [{_key, resource}] -> {:ok, resource}
        [] -> {:error, %Error{reason: :not_found, rid: rid}}
      end
    end
  end

  @doc "Fetches one resource by the name a user sees in the Hue app."
  @spec fetch_by_name(table(), atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def fetch_by_name(table, type, name) do
    with :ok <- readable(table) do
      case :ets.lookup(table, {:name, type, name}) do
        [{_key, rid}] ->
          fetch(table, type, rid)

        [] ->
          {:error, %Error{reason: :not_found, description: "no #{type} named #{inspect(name)}"}}
      end
    end
  end

  @doc """
  The name a rid is known by, or `nil`.

  Used by event dispatch to answer name-filtered subscriptions without
  re-walking the device graph per event. Returns a bare value rather than a
  result tuple because dispatch has nothing useful to do with an error.
  """
  @spec name_of(table(), atom(), String.t()) :: String.t() | nil
  def name_of(table, type, rid) do
    case :ets.lookup(table, {:rid_name, type, rid}) do
      [{_key, name}] -> name
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Every resource of one type."
  @spec list(table(), atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(table, type) do
    with :ok <- readable(table) do
      {:ok, :ets.select(table, [{{{type, :"$1"}, :"$2"}, [], [:"$2"]}])}
    end
  end

  defp readable(table) do
    case :ets.lookup(table, @seeded_key) do
      [{@seeded_key, true}] -> :ok
      [] -> {:error, %Error{reason: :not_synced}}
    end
  rescue
    ArgumentError -> {:error, %Error{reason: :not_started}}
  end

  defp reindexing?(data), do: Map.has_key?(data, "metadata") or Map.has_key?(data, "services")

  # Insert-then-prune — see the moduledoc's "Never remove before inserting".
  # Computing `entries` from the table's current resources and inserting them
  # before deleting anything means an index lookup running concurrently with a
  # reindex either finds the old mapping or the new one, never neither.
  defp reindex(table) do
    entries = Names.entries(resources(table))
    keys = MapSet.new(entries, &elem(&1, 0))

    :ets.insert(table, entries)
    prune_index(table, keys)

    :ok
  end

  defp prune_resources(table, keys) do
    table
    |> resource_keys()
    |> Enum.reject(&MapSet.member?(keys, &1))
    |> Enum.each(&:ets.delete(table, &1))
  end

  defp prune_index(table, keys) do
    table
    |> index_keys()
    |> Enum.reject(&MapSet.member?(keys, &1))
    |> Enum.each(&:ets.delete(table, &1))
  end

  defp resources(table) do
    :ets.select(table, [{{{:"$1", :"$2"}, :"$3"}, [], [:"$3"]}])
  end

  defp resource_keys(table) do
    :ets.select(table, [{{{:"$1", :"$2"}, :_}, [], [{{:"$1", :"$2"}}]}])
  end

  defp index_keys(table) do
    :ets.select(table, [
      {{{:name, :"$1", :"$2"}, :_}, [], [{{:name, :"$1", :"$2"}}]},
      {{{:rid_name, :"$1", :"$2"}, :_}, [], [{{:rid_name, :"$1", :"$2"}}]}
    ])
  end

  defp type_of(resource), do: Hue.Resource.type(resource["type"])
  defp rid_of(resource), do: resource["id"]
end
