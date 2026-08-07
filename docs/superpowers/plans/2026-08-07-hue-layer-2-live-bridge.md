# Hue Layer 2 — the live bridge model: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Hue.Bridge` — an opt-in, supervised, always-current model of a Hue bridge, plus the name-addressable `Hue.Light` / `Hue.Room` / `Hue.Zone` / `Hue.Scene` API that sits on it.

**Architecture:** A supervisor (`Hue.Bridge`) owning a `Registry`, a `Task.Supervisor`, and one `Hue.Bridge.Server` GenServer. The server owns a named ETS table keyed `{type, rid}`, seeded by one full fetch and kept current by the CLIP v2 eventstream. **Reads bypass the process entirely** — `:ets.lookup` in the calling process — which is what keeps the GenServer from becoming the bottleneck a naive cache process becomes. **Writes go through the process**, because that is the only place coalescing and Hue's per-type rate limits can live; the HTTP PUT itself runs in a supervised task so network latency never stalls event ingestion.

**Tech Stack:** Elixir ~> 1.17, `req ~> 0.7`, `server_sent_events ~> 1.1`, `telemetry ~> 1.0`, `color ~> 0.13`, ETS, `Registry`, `Task.Supervisor`. Tests use function plugs (`plug: fn conn -> … end`) rather than `Req.Test` stubs — see "Testing seam" below.

**Spec:** `docs/superpowers/specs/2026-08-06-hue-library-design.md`, sections "Architecture", "`Hue.Bridge` internals", "The write path", "Error model", "Telemetry", "Testing".

---

## Testing seam — read this before writing any test

Layer 1's tests use `Req.Test.stub(__MODULE__, fun)`. **That does not work here.** `Req.Test` stubs are owned by the process that installs them (NimbleOwnership), and every request in layer 2 is made by the bridge's own processes — the server or a task it spawned — not by the test process. `Req.Test.allow/3` can be made to work, but it depends on `$callers` propagation through `Task.Supervisor`, which is an assumption this library should not build its whole test suite on.

`Hue.new/2` passes any unknown option straight to `Req.new/1`, and Req accepts a **bare function** as `:plug`. A function plug runs in whichever process makes the request and closes over whatever the test wants. There is no ownership involved, so tests stay `async: true` and no process needs allowing.

Task 6 builds `Hue.Stub` for this. Every layer-2 test uses it.

## Naming and process identity

`Hue.Bridge.start_link/1` takes `:name` (default `Hue.Bridge`). Three names are derived from it with `Module.concat/2`:

| Derived name | What it is |
|---|---|
| `Module.concat(name, Server)` | the GenServer |
| `Module.concat(name, Registry)` | the subscription registry |
| `Module.concat(name, Cache)` | the named ETS table |

Deriving names creates atoms, which is normally a red flag — but these are created once per configured bridge at startup, from a name the consumer wrote in their own supervision tree, not from network input. This is what Phoenix does for endpoint-derived names. **Resource type atoms are a different matter and are never created dynamically** — see `Hue.Resource.type/1` in Task 1.

The ETS table being *named* is what lets a reader in any process find it with no call and no lookup table.

## File structure

**Layer 1, modified:**

| File | Change |
|---|---|
| `lib/hue/resource.ex` | add `list_all/2` (the one-request full state) and `type/1` (safe string→atom) |
| `lib/hue/events.ex` | delegate its private type table to `Hue.Resource.type/1` |
| `lib/hue/error.ex` | add `:not_started` and `:not_synced` reasons |

**Layer 2, new:**

| File | Responsibility |
|---|---|
| `lib/hue/bridge/merge.ex` | pure deep-merge of an event delta into a cached resource |
| `lib/hue/bridge/names.ex` | pure — builds both name indexes from a resource list |
| `lib/hue/bridge/cache.ex` | ETS table: creation, seeding, event application, and every read path |
| `lib/hue/bridge/graph.ex` | pure-over-cache target resolution: name-or-rid → rid, room/zone → `grouped_light` |
| `lib/hue/bridge/body.ex` | pure — `set` options → CLIP v2 body, with capability checks |
| `lib/hue/bridge/writes.ex` | pure — the coalescing, rate-paced write queue as a struct |
| `lib/hue/bridge/server.ex` | the GenServer: sync, stream supervision, reconnect, dispatch, write execution |
| `lib/hue/bridge.ex` | *(modify)* the supervisor and the public layer-2 API, alongside the existing `Info` |
| `lib/hue/light.ex` | name-addressable light reads and writes |
| `lib/hue/group.ex` | shared implementation for room and zone (both resolve to a `grouped_light`) |
| `lib/hue/room.ex` | thin public module over `Hue.Group` |
| `lib/hue/zone.ex` | thin public module over `Hue.Group` |
| `lib/hue/scene.ex` | scene recall |

**Test support, new:**

| File | Responsibility |
|---|---|
| `test/support/stub.ex` | `Hue.Stub` — function-plug bridge client, canned + scripted responses, chunked eventstream |

The split follows the spec's own seams. `merge`, `names`, `graph`, `body`, and `writes` are pure and hold the bulk of the correctness; `cache` is the only module that touches ETS; `server` is the only module that owns a process. That ordering is also the task order — every pure module is finished and tested before anything that uses it exists.

---

### Task 1: Layer-1 additions that layer 2 needs

Two small gaps in layer 1. The full-state fetch has no function (`list/3` only reaches one type at a time, and 22 requests to seed a cache is absurd when the bridge answers all 178 resources in one). And `Hue.Events` holds the string→atom resource type table privately, while `Hue.Bridge.Names` needs exactly the same conversion — the table has to move somewhere both can reach, without either of them ever calling `String.to_atom/1` on a name that came off the network.

**Files:**
- Modify: `lib/hue/resource.ex`
- Modify: `lib/hue/events.ex:55-75` (the type tables)
- Modify: `lib/hue/error.ex:30-49` (the `reason` type)
- Test: `test/hue/resource_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `test/hue/resource_test.exs`, inside the existing `defmodule Hue.ResourceTest`:

```elixir
  test "list_all/1 returns every resource on the bridge in one request", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/clip/v2/resource"
      assert Plug.Conn.get_req_header(conn, "hue-application-key") == ["k"]
      Req.Test.json(conn, %{"errors" => [], "data" => Hue.Fixtures.full_state()["data"]})
    end)

    assert {:ok, resources} = Resource.list_all(client)
    assert length(resources) == 178
    assert Enum.count(resources, &(&1["type"] == "light")) == 19
  end

  test "list_all/2 surfaces partial success like list/3 does", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"description" => "partly"}], "data" => []})
    end)

    assert {:ok, [], [%{"description" => "partly"}]} =
             Resource.list_all(client, return: :detailed)
  end

  test "type/1 converts a documented resource type to an atom" do
    assert Resource.type("light") == :light
    assert Resource.type("grouped_light") == :grouped_light
  end

  test "type/1 leaves an unknown type as a string rather than creating an atom" do
    assert Resource.type("type_signify_invents_in_2027") == "type_signify_invents_in_2027"
  end

  test "type/1 passes nil through" do
    assert Resource.type(nil) == nil
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ~/src/hue-ex && mix test test/hue/resource_test.exs`
Expected: FAIL — `function Hue.Resource.list_all/1 is undefined or private` and `function Hue.Resource.type/1 is undefined or private`.

- [ ] **Step 3: Move the type table into `Hue.Resource` and add `list_all/2`**

In `lib/hue/resource.ex`, add the table and both functions. Put the `@resource_type_names` attribute near the top of the module with the other attributes, and the public functions after `list/3`:

```elixir
  # The resource types CLIP v2 documents. Kept as a table rather than reached
  # through String.to_atom/1 so that a name from the network never becomes an
  # atom; see Hue.Event on what happens to the ones that are not here.
  @resource_type_names ~w(
    auth_v1 behavior_instance behavior_script bridge bridge_home button
    camera_motion clip contact device device_mode device_power
    device_software_update entertainment entertainment_configuration geofence
    geofence_client geolocation grouped_light grouped_light_level
    grouped_motion homekit light light_level matter matter_fabric motion
    private_group public_image relative_rotary room scene service_group
    smart_scene tamper taurus_7455 temperature wifi_connectivity
    zgp_connectivity zigbee_bridge_connectivity zigbee_connectivity
    zigbee_device_discovery zone
  )
  @resource_types Map.new(@resource_type_names, &{&1, String.to_atom(&1)})

  @doc """
  Lists every resource on the bridge in one request.

  This is what seeds `Hue.Bridge`'s cache. The reference bridge answers with
  178 resources across 22 types in roughly 154 KB, which is why reconnecting
  refetches everything rather than resuming the eventstream from an id.
  """
  @spec list_all(Client.t(), keyword()) ::
          {:ok, list()} | {:ok, list(), list()} | {:error, Error.t()}
  def list_all(%Client{} = client, options \\ []) do
    request(client, :get, "/resource", nil, nil, options, & &1)
  end

  @doc """
  Converts a resource type from the wire into an atom, when this library knows it.

  An unrecognised type is returned as the string it arrived as. A name from the
  network must never become an atom: the atom table is not garbage collected,
  and a bridge firmware that invents a type should not be able to grow it.
  """
  @spec type(String.t() | nil) :: atom() | String.t() | nil
  def type(name) when is_binary(name), do: Map.get(@resource_types, name, name)
  def type(nil), do: nil
```

- [ ] **Step 4: Point `Hue.Events` at the moved table**

In `lib/hue/events.ex`, delete the `@resource_type_names` and `@resource_types` attributes (lines 62-75 in the current file, including the comment above them — it moved with the table), and replace the two private clauses:

```elixir
  defp resource_type(type) when is_binary(type), do: Map.get(@resource_types, type, type)
  defp resource_type(nil), do: nil
```

with a delegation:

```elixir
  defp resource_type(type), do: Resource.type(type)
```

Add `alias Hue.Resource` to the module's aliases if it is not already there.

- [ ] **Step 5: Add the two new error reasons**

In `lib/hue/error.ex`, extend the `@type reason` union with two layer-2 reasons. Insert them after `:no_grouped_light`:

```elixir
          | :no_grouped_light
          | :not_started
          | :not_synced
```

Then add their documentation to the moduledoc's reason table, alongside the existing entries:

```
  * `:not_started` — no `Hue.Bridge` is running under the name you addressed.
    You asked a live model that does not exist; add its `child_spec/1` to your
    supervision tree.
  * `:not_synced` — the bridge is running but has not completed its first full
    fetch, so the cache cannot answer yet. Transient; `Hue.Bridge.status/1`
    reports `:connecting` or `:syncing` while it lasts.
```

- [ ] **Step 6: Run the full suite**

Run: `cd ~/src/hue-ex && mix test`
Expected: PASS. The `Hue.Events` tests must still pass unchanged — they are what proves the table moved without changing behaviour. If `events_test.exs` fails, the delegation is wrong, not the tests.

- [ ] **Step 7: Verify the type table did not silently narrow**

Run: `cd ~/src/hue-ex && mix run -e 'IO.inspect(Enum.map(~w(light room zone scene grouped_light device button bridge_home), &Hue.Resource.type/1))'`
Expected: `[:light, :room, :zone, :scene, :grouped_light, :device, :button, :bridge_home]` — all atoms, none strings.

- [ ] **Step 8: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/resource.ex lib/hue/events.ex lib/hue/error.ex test/hue/resource_test.exs
git commit -m "Add the full-state fetch and share the resource type table"
```

---

### Task 2: `Hue.Bridge.Merge` — the deep merge

The eventstream's deltas are **partial**. An observed light event carried only `on: {on: true}` plus identity fields — no brightness, no colour, no name. Applying that by replacement would erase most of the cached light. This module is four lines of code protecting the single most consequential invariant in layer 2.

**Files:**
- Create: `lib/hue/bridge/merge.ex`
- Test: `test/hue/bridge/merge_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge/merge_test.exs`:

```elixir
defmodule Hue.Bridge.MergeTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Merge

  test "a nested map merges rather than replacing its siblings" do
    cached = %{
      "dimming" => %{"brightness" => 42.0, "min_dim_level" => 0.2},
      "on" => %{"on" => false}
    }

    delta = %{"dimming" => %{"brightness" => 86.11}}

    assert Merge.merge(cached, delta) == %{
             "dimming" => %{"brightness" => 86.11, "min_dim_level" => 0.2},
             "on" => %{"on" => false}
           }
  end

  test "a list replaces rather than merging" do
    cached = %{"services" => [%{"rid" => "a"}, %{"rid" => "b"}]}
    delta = %{"services" => [%{"rid" => "c"}]}

    assert Merge.merge(cached, delta) == %{"services" => [%{"rid" => "c"}]}
  end

  test "a scalar replaces" do
    assert Merge.merge(%{"mode" => "normal"}, %{"mode" => "streaming"}) ==
             %{"mode" => "streaming"}
  end

  test "a key only the delta has is added" do
    assert Merge.merge(%{"id" => "x"}, %{"color" => %{"xy" => %{"x" => 0.3}}}) ==
             %{"id" => "x", "color" => %{"xy" => %{"x" => 0.3}}}
  end

  test "a key only the cache has survives" do
    assert Merge.merge(%{"id" => "x", "product_data" => %{"model_id" => "LCT001"}}, %{
             "id" => "x"
           }) == %{"id" => "x", "product_data" => %{"model_id" => "LCT001"}}
  end

  test "merging recurses to arbitrary depth" do
    cached = %{"a" => %{"b" => %{"c" => 1, "d" => 2}}}
    delta = %{"a" => %{"b" => %{"c" => 9}}}

    assert Merge.merge(cached, delta) == %{"a" => %{"b" => %{"c" => 9, "d" => 2}}}
  end

  test "a map replacing a scalar takes the map" do
    assert Merge.merge(%{"color" => nil}, %{"color" => %{"xy" => %{"x" => 0.3}}}) ==
             %{"color" => %{"xy" => %{"x" => 0.3}}}
  end

  test "a scalar replacing a map takes the scalar" do
    assert Merge.merge(%{"color" => %{"xy" => %{"x" => 0.3}}}, %{"color" => nil}) ==
             %{"color" => nil}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/merge_test.exs`
Expected: FAIL — `module Hue.Bridge.Merge is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/hue/bridge/merge.ex`:

```elixir
defmodule Hue.Bridge.Merge do
  @moduledoc """
  Applies an eventstream delta to a cached resource.

  Maps recurse; everything else replaces.

  The distinction is load-bearing rather than stylistic. CLIP v2 events are
  partial — an observed light event carried `on: %{"on" => true}` and the two
  identity fields, and nothing else — so replacing the cached resource with the
  delta would erase the light's brightness, colour, and capabilities. Merging
  one level deep is not enough either: a delta carrying
  `%{"dimming" => %{"brightness" => 86.11}}` must leave the `min_dim_level`
  cached beside it alone.

  Lists replace because a list arriving in an event is authoritative. A
  `services` list is the complete set of that device's services, not an
  addition to it, and there is no key to merge list elements on.
  """

  @doc """
  Deep-merges `delta` into `cached`.

      iex> Hue.Bridge.Merge.merge(
      ...>   %{"dimming" => %{"brightness" => 42.0, "min_dim_level" => 0.2}},
      ...>   %{"dimming" => %{"brightness" => 86.11}}
      ...> )
      %{"dimming" => %{"brightness" => 86.11, "min_dim_level" => 0.2}}
  """
  @spec merge(map(), map()) :: map()
  def merge(cached, delta) when is_map(cached) and is_map(delta) do
    Map.merge(cached, delta, fn _key, old, new -> merge_values(old, new) end)
  end

  defp merge_values(old, new) when is_map(old) and is_map(new), do: merge(old, new)
  defp merge_values(_old, new), do: new
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/merge_test.exs`
Expected: PASS, 8 tests.

- [ ] **Step 5: Verify the test actually protects the invariant**

Break the code and watch the right test fail. Temporarily change `merge_values(old, new) when is_map(old) and is_map(new)` to `merge_values(_old, new)` only (delete the recursing clause), then:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/merge_test.exs`
Expected: FAIL on "a nested map merges rather than replacing its siblings" — specifically `min_dim_level` missing. If it passes, the test is not testing what it claims and must be fixed before continuing.

Restore the clause and re-run to confirm PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge/merge.ex test/hue/bridge/merge_test.exs
git commit -m "Deep-merge event deltas so a partial dimming does not erase the light"
```

---

### Task 3: `Hue.Bridge.Names` — both name indexes

A light's name is not on the light. `light.metadata` is deprecated, and the name a user sees in the Hue app lives on the `device` that owns the light, reachable only through that device's `services` list. Rooms, zones, and scenes do carry their own `metadata.name`.

Two indexes come out of one pass, because they are two views of the same fact: `{:name, type, name} => rid` answers `Hue.Light.get(bridge, "Desk Lamp")`, and `{:rid_name, type, rid} => name` answers "does this event concern the light someone subscribed to by name?" during dispatch.

**Files:**
- Create: `lib/hue/bridge/names.ex`
- Test: `test/hue/bridge/names_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge/names_test.exs`:

```elixir
defmodule Hue.Bridge.NamesTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Names

  defp device(name, services) do
    %{
      "type" => "device",
      "id" => "device-#{name}",
      "metadata" => %{"name" => name},
      "services" => services
    }
  end

  defp service(rtype, rid), do: %{"rid" => rid, "rtype" => rtype}

  test "a light is named after the device that owns it" do
    entries = Names.entries([device("Desk Lamp", [service("light", "light-1")])])

    assert {{:name, :light, "Desk Lamp"}, "light-1"} in entries
    assert {{:rid_name, :light, "light-1"}, "Desk Lamp"} in entries
  end

  test "a device names every service it owns, not only its light" do
    entries =
      Names.entries([
        device("Desk Lamp", [service("light", "light-1"), service("zigbee_connectivity", "zc-1")])
      ])

    assert {{:name, :light, "Desk Lamp"}, "light-1"} in entries
    assert {{:name, :zigbee_connectivity, "Desk Lamp"}, "zc-1"} in entries
  end

  test "a device is also indexed under its own type" do
    entries = Names.entries([device("Desk Lamp", [service("light", "light-1")])])

    assert {{:name, :device, "device-Desk Lamp"}, "device-Desk Lamp"} not in entries
    assert {{:name, :device, "Desk Lamp"}, "device-Desk Lamp"} in entries
  end

  test "a room is indexed from its own metadata" do
    room = %{"type" => "room", "id" => "room-1", "metadata" => %{"name" => "Living Room"}}

    entries = Names.entries([room])

    assert {{:name, :room, "Living Room"}, "room-1"} in entries
    assert {{:rid_name, :room, "room-1"}, "Living Room"} in entries
  end

  test "zones, scenes, and smart scenes are indexed from their own metadata" do
    resources = [
      %{"type" => "zone", "id" => "zone-1", "metadata" => %{"name" => "Downstairs"}},
      %{"type" => "scene", "id" => "scene-1", "metadata" => %{"name" => "Relax"}},
      %{"type" => "smart_scene", "id" => "smart-1", "metadata" => %{"name" => "Natural Light"}}
    ]

    entries = Names.entries(resources)

    assert {{:name, :zone, "Downstairs"}, "zone-1"} in entries
    assert {{:name, :scene, "Relax"}, "scene-1"} in entries
    assert {{:name, :smart_scene, "Natural Light"}, "smart-1"} in entries
  end

  test "a light's own deprecated metadata name is not indexed" do
    light = %{"type" => "light", "id" => "light-1", "metadata" => %{"name" => "Stale Name"}}

    assert Names.entries([light]) == []
  end

  test "a grouped_light carries no name of its own and produces nothing" do
    grouped = %{"type" => "grouped_light", "id" => "gl-1", "owner" => %{"rid" => "room-1"}}

    assert Names.entries([grouped]) == []
  end

  test "a resource with no metadata is skipped rather than crashing" do
    assert Names.entries([%{"type" => "bridge", "id" => "bridge-1"}]) == []
  end

  test "a device whose service carries an unknown rtype keeps it as a string" do
    entries = Names.entries([device("Odd", [service("taurus_9999", "x-1")])])

    assert {{:name, "taurus_9999", "Odd"}, "x-1"} in entries
  end

  test "the real fixture names all nineteen lights" do
    entries = Names.entries(Hue.Fixtures.full_state()["data"])

    named_lights = for {{:name, :light, name}, rid} <- entries, do: {name, rid}

    assert length(named_lights) == 19
    assert Enum.all?(named_lights, fn {name, rid} -> is_binary(name) and is_binary(rid) end)
  end

  test "the real fixture names all six rooms and three zones" do
    entries = Names.entries(Hue.Fixtures.full_state()["data"])

    assert Enum.count(entries, &match?({{:name, :room, _}, _}, &1)) == 6
    assert Enum.count(entries, &match?({{:name, :zone, _}, _}, &1)) == 3
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/names_test.exs`
Expected: FAIL — `module Hue.Bridge.Names is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/hue/bridge/names.ex`:

```elixir
defmodule Hue.Bridge.Names do
  @moduledoc """
  Builds the two name indexes `Hue.Bridge` keeps beside its resources.

  ## A light's name is not on the light

  `light.metadata` is deprecated in CLIP v2 and can hold a stale value. The name
  a user sees in the Hue app lives on the `device` that owns the light, and the
  only path from that device to the light is the device's `services` list. So
  naming is a walk, not a field read, and it is a walk this module does once per
  index rebuild rather than once per lookup.

  Rooms, zones, scenes, and smart scenes are different: those are named things
  in their own right, and their `metadata.name` is authoritative.

  `grouped_light` is deliberately unnamed. It is a service of a room or a zone,
  and it is addressed through the room or the zone — see `Hue.Bridge.Graph`.

  ## Two directions, one pass

  Both indexes come out of the same walk because they are two views of one fact:

    * `{:name, type, name} => rid` — what `Hue.Light.get(bridge, "Desk Lamp")` needs.
    * `{:rid_name, type, rid} => name` — what event dispatch needs, to answer
      "does this event concern the light someone subscribed to by name?" without
      re-walking the device graph for every event.
  """

  alias Hue.Resource

  @self_named ~w(room zone scene smart_scene device)

  @doc """
  Returns every index entry implied by `resources`, as `{key, value}` pairs
  ready for `:ets.insert/2`.

  Order is unspecified and duplicates are possible when two devices share a
  name — the later insert wins, which is the same arbitrary-but-stable choice
  the Hue app makes when you name two lights identically.
  """
  @spec entries([map()]) :: [{tuple(), String.t()}]
  def entries(resources) when is_list(resources) do
    Enum.flat_map(resources, &entries_for/1)
  end

  defp entries_for(%{"type" => "device", "id" => rid, "metadata" => %{"name" => name}} = device)
       when is_binary(rid) and is_binary(name) do
    pair(:device, rid, name) ++ service_entries(device, name)
  end

  defp entries_for(%{"type" => type, "id" => rid, "metadata" => %{"name" => name}})
       when is_binary(rid) and is_binary(name) and type in @self_named do
    pair(Resource.type(type), rid, name)
  end

  defp entries_for(_resource), do: []

  defp service_entries(%{"services" => services}, name) when is_list(services) do
    Enum.flat_map(services, fn
      %{"rid" => rid, "rtype" => rtype} when is_binary(rid) and is_binary(rtype) ->
        pair(Resource.type(rtype), rid, name)

      _other ->
        []
    end)
  end

  defp service_entries(_device, _name), do: []

  defp pair(type, rid, name) do
    [{{:name, type, name}, rid}, {{:rid_name, type, rid}, name}]
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/names_test.exs`
Expected: PASS, 11 tests.

- [ ] **Step 5: Verify the fixture assertions are not vacuous**

The two fixture tests are the ones most likely to pass for the wrong reason. Temporarily change `@self_named` to `~w(room zone scene smart_scene)` — dropping `device` — and re-run.

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/names_test.exs`
Expected: FAIL on "a device is also indexed under its own type" but **PASS** on "the real fixture names all nineteen lights", because light names come from `service_entries/2`, not from the device's own entry. That is correct and worth seeing: the two paths are independent.

Now temporarily make `service_entries/2` return `[]` unconditionally and re-run.
Expected: FAIL on "the real fixture names all nineteen lights" with `0` instead of `19`. Restore both and confirm PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge/names.ex test/hue/bridge/names_test.exs
git commit -m "Index names from the owning device, not the deprecated light metadata"
```

---

### Task 4: `Hue.Bridge.Cache` — the ETS table and every read path

The only module that touches ETS. This is where the spec's central performance decision lives: the table is **named**, so a reader in any process finds it with no call and no lookup, and `:protected`, so only the owning server writes.

Two lifecycle facts are kept in the table itself rather than in the server's state, precisely so that reads never need a `GenServer.call`: whether the cache has ever been seeded, and what the connection is currently doing. They are separate on purpose. A bridge that synced once and then lost its stream still serves its last known state — stale data with a `:reconnecting` status beats no data — while a bridge that has never synced refuses reads with `:not_synced`.

**Files:**
- Create: `lib/hue/bridge/cache.ex`
- Test: `test/hue/bridge/cache_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge/cache_test.exs`:

```elixir
defmodule Hue.Bridge.CacheTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Cache
  alias Hue.Error
  alias Hue.Event

  setup context do
    table = Module.concat(Hue.CacheTest, context.test |> to_string() |> String.replace(" ", "_"))
    Cache.new(table)
    {:ok, table: table}
  end

  defp light(rid, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "light",
        "id" => rid,
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0, "min_dim_level" => 0.2}
      },
      extra
    )
  end

  defp device(name, rid, service_rid) do
    %{
      "type" => "device",
      "id" => rid,
      "metadata" => %{"name" => name},
      "services" => [%{"rid" => service_rid, "rtype" => "light"}]
    }
  end

  test "a table that was never created is :not_started, not a crash" do
    assert Cache.status(Hue.CacheTest.NeverCreated) == :not_started

    assert {:error, %Error{reason: :not_started}} =
             Cache.fetch(Hue.CacheTest.NeverCreated, :light, "light-1")
  end

  test "reads are :not_synced until the first seed", %{table: table} do
    assert {:error, %Error{reason: :not_synced}} = Cache.fetch(table, :light, "light-1")
    assert {:error, %Error{reason: :not_synced}} = Cache.list(table, :light)
    assert {:error, %Error{reason: :not_synced}} = Cache.fetch_by_name(table, :light, "Desk Lamp")
  end

  test "seeding makes resources readable by rid", %{table: table} do
    Cache.seed(table, [light("light-1")])

    assert {:ok, %{"id" => "light-1"}} = Cache.fetch(table, :light, "light-1")
  end

  test "a rid that does not exist is :not_found, not :not_synced", %{table: table} do
    Cache.seed(table, [light("light-1")])

    assert {:error, %Error{reason: :not_found, rid: "nope"}} = Cache.fetch(table, :light, "nope")
  end

  test "seeding builds the name index", %{table: table} do
    Cache.seed(table, [light("light-1"), device("Desk Lamp", "device-1", "light-1")])

    assert {:ok, %{"id" => "light-1"}} = Cache.fetch_by_name(table, :light, "Desk Lamp")
    assert Cache.name_of(table, :light, "light-1") == "Desk Lamp"
  end

  test "a name that does not exist is :not_found", %{table: table} do
    Cache.seed(table, [light("light-1")])

    assert {:error, %Error{reason: :not_found}} = Cache.fetch_by_name(table, :light, "Nowhere")
  end

  test "list/2 returns every resource of one type and nothing else", %{table: table} do
    Cache.seed(table, [
      light("light-1"),
      light("light-2"),
      device("Desk Lamp", "device-1", "light-1")
    ])

    assert {:ok, lights} = Cache.list(table, :light)
    assert length(lights) == 2
    assert Enum.all?(lights, &(&1["type"] == "light"))
  end

  test "seeding twice replaces rather than accumulating", %{table: table} do
    Cache.seed(table, [light("light-1"), light("light-2")])
    Cache.seed(table, [light("light-1")])

    assert {:ok, [%{"id" => "light-1"}]} = Cache.list(table, :light)
    assert {:error, %Error{reason: :not_found}} = Cache.fetch(table, :light, "light-2")
  end

  test "an update event deep-merges instead of replacing", %{table: table} do
    Cache.seed(table, [light("light-1")])

    Cache.apply_event(table, %Event{
      type: :update,
      resource_type: :light,
      rid: "light-1",
      data: %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}
    })

    assert {:ok, cached} = Cache.fetch(table, :light, "light-1")
    assert cached["on"] == %{"on" => true}
    assert cached["dimming"] == %{"brightness" => 42.0, "min_dim_level" => 0.2}
  end

  test "an update for a rid the cache has never seen inserts it", %{table: table} do
    Cache.seed(table, [])

    Cache.apply_event(table, %Event{
      type: :update,
      resource_type: :light,
      rid: "light-9",
      data: light("light-9")
    })

    assert {:ok, %{"id" => "light-9"}} = Cache.fetch(table, :light, "light-9")
  end

  test "an add event inserts", %{table: table} do
    Cache.seed(table, [])

    Cache.apply_event(table, %Event{
      type: :add,
      resource_type: :light,
      rid: "light-3",
      data: light("light-3")
    })

    assert {:ok, %{"id" => "light-3"}} = Cache.fetch(table, :light, "light-3")
  end

  test "a delete event removes", %{table: table} do
    Cache.seed(table, [light("light-1")])

    Cache.apply_event(table, %Event{
      type: :delete,
      resource_type: :light,
      rid: "light-1",
      data: %{"type" => "light", "id" => "light-1"}
    })

    assert {:error, %Error{reason: :not_found}} = Cache.fetch(table, :light, "light-1")
  end

  test "an error event changes nothing", %{table: table} do
    Cache.seed(table, [light("light-1")])

    Cache.apply_event(table, %Event{
      type: :error,
      resource_type: :light,
      rid: "light-1",
      data: %{"description" => "something went wrong"}
    })

    assert {:ok, %{"dimming" => %{"brightness" => 42.0}}} = Cache.fetch(table, :light, "light-1")
  end

  test "a rename rebuilds the index and leaves no stale entry", %{table: table} do
    Cache.seed(table, [light("light-1"), device("Desk Lamp", "device-1", "light-1")])

    Cache.apply_event(table, %Event{
      type: :update,
      resource_type: :device,
      rid: "device-1",
      data: %{"type" => "device", "id" => "device-1", "metadata" => %{"name" => "Reading Lamp"}}
    })

    assert {:ok, %{"id" => "light-1"}} = Cache.fetch_by_name(table, :light, "Reading Lamp")
    assert {:error, %Error{reason: :not_found}} = Cache.fetch_by_name(table, :light, "Desk Lamp")
    assert Cache.name_of(table, :light, "light-1") == "Reading Lamp"
  end

  test "deleting a device removes the names it gave its services", %{table: table} do
    Cache.seed(table, [light("light-1"), device("Desk Lamp", "device-1", "light-1")])

    Cache.apply_event(table, %Event{
      type: :delete,
      resource_type: :device,
      rid: "device-1",
      data: %{"type" => "device", "id" => "device-1"}
    })

    assert {:error, %Error{reason: :not_found}} = Cache.fetch_by_name(table, :light, "Desk Lamp")
  end

  test "status is reported independently of whether reads are allowed", %{table: table} do
    assert Cache.status(table) == :connecting

    Cache.put_status(table, :syncing)
    assert Cache.status(table) == :syncing
    assert {:error, %Error{reason: :not_synced}} = Cache.fetch(table, :light, "light-1")

    Cache.seed(table, [light("light-1")])
    Cache.put_status(table, :live)
    assert Cache.status(table) == :live
    assert {:ok, _} = Cache.fetch(table, :light, "light-1")
  end

  test "a synced cache keeps serving reads while the stream is down", %{table: table} do
    Cache.seed(table, [light("light-1")])
    Cache.put_status(table, :live)
    Cache.put_status(table, {:error, :closed})

    assert Cache.status(table) == {:error, :closed}
    assert {:ok, %{"id" => "light-1"}} = Cache.fetch(table, :light, "light-1")
  end

  test "the real fixture seeds and reads back", %{table: table} do
    Cache.seed(table, Hue.Fixtures.full_state()["data"])

    assert {:ok, lights} = Cache.list(table, :light)
    assert length(lights) == 19

    assert {:ok, rooms} = Cache.list(table, :room)
    assert length(rooms) == 6

    assert {:ok, scenes} = Cache.list(table, :scene)
    assert length(scenes) == 34
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/cache_test.exs`
Expected: FAIL — `module Hue.Bridge.Cache is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/hue/bridge/cache.ex`:

```elixir
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
  Replaces the cache's entire contents with `resources` and rebuilds both name
  indexes.

  Replacement rather than merge is what makes reconnect correct: a resource
  deleted while the stream was down disappears here, and there is no path by
  which a stale resource outlives a refetch.
  """
  @spec seed(table(), [map()]) :: :ok
  def seed(table, resources) when is_list(resources) do
    status = status(table)

    :ets.delete_all_objects(table)
    :ets.insert(table, Enum.map(resources, &{{type_of(&1), rid_of(&1)}, &1}))
    :ets.insert(table, Names.entries(resources))
    :ets.insert(table, {@status_key, status})
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
  def apply_event(table, %Event{type: :error}), do: (_ = table) && :ok

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

  def apply_event(table, %Event{}), do: (_ = table) && :ok

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
        [{_key, rid}] -> fetch(table, type, rid)
        [] -> {:error, %Error{reason: :not_found, description: "no #{type} named #{inspect(name)}"}}
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

  defp reindex(table) do
    :ets.match_delete(table, {{:name, :_, :_}, :_})
    :ets.match_delete(table, {{:rid_name, :_, :_}, :_})
    :ets.insert(table, Names.entries(resources(table)))
    :ok
  end

  defp resources(table) do
    :ets.select(table, [{{{:"$1", :"$2"}, :"$3"}, [], [:"$3"]}])
  end

  defp type_of(resource), do: Hue.Resource.type(resource["type"])
  defp rid_of(resource), do: resource["id"]
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/cache_test.exs`
Expected: PASS, 18 tests.

- [ ] **Step 5: Verify the two lifecycle facts are genuinely independent**

This is the design decision most likely to be quietly undone by a later edit, so prove the test catches it. Temporarily rewrite `readable/1` to key off status instead:

```elixir
  defp readable(table) do
    case status(table) do
      :live -> :ok
      :not_started -> {:error, %Error{reason: :not_started}}
      _other -> {:error, %Error{reason: :not_synced}}
    end
  end
```

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/cache_test.exs`
Expected: FAIL on "a synced cache keeps serving reads while the stream is down" — the read returns `:not_synced` instead of the cached light. Restore the original and confirm PASS.

- [ ] **Step 6: Verify the select match spec does not pick up index rows**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/cache_test.exs --only test:"list/2 returns every resource of one type and nothing else"`
Expected: PASS. Then temporarily change the `list/2` match spec to `[{{{type, :_}, :"$2"}, [], [:"$2"]}]` — still correct — and re-run to confirm it stays green; the point is that neither form can reach a three-tuple key. If a future edit widens it to `{:"$1", :"$2"}`, the seeded device rows and the name rows would both leak into `list(table, :light)`.

- [ ] **Step 7: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge/cache.ex test/hue/bridge/cache_test.exs
git commit -m "Cache resources in a named ETS table so reads never touch the server"
```

---

### Task 5: `Hue.Bridge.Graph` — resolving a target to something writable

"Dim the living room" is not one operation. It is: find the `room` named "Living Room", walk its `services`, select the one whose `rtype` is `grouped_light`, and PUT that rid. Layer 1 makes every step of that possible and none of it convenient. This module is the graph walk, and it is pure over the cache — no process, no I/O.

Two rooms on the reference bridge are empty and expose **no `grouped_light` service at all**, which is why `:no_grouped_light` is a real error rather than a defensive one.

**Files:**
- Create: `lib/hue/bridge/graph.ex`
- Test: `test/hue/bridge/graph_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge/graph_test.exs`:

```elixir
defmodule Hue.Bridge.GraphTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Cache
  alias Hue.Bridge.Graph
  alias Hue.Error

  setup context do
    table = Module.concat(Hue.GraphTest, context.test |> to_string() |> String.replace(" ", "_"))
    Cache.new(table)
    {:ok, table: table}
  end

  defp light(rid), do: %{"type" => "light", "id" => rid, "on" => %{"on" => false}}

  defp device(name, rid, service_rid) do
    %{
      "type" => "device",
      "id" => rid,
      "metadata" => %{"name" => name},
      "services" => [%{"rid" => service_rid, "rtype" => "light"}]
    }
  end

  defp room(name, rid, services) do
    %{"type" => "room", "id" => rid, "metadata" => %{"name" => name}, "services" => services}
  end

  test "a name resolves to the resource it names", %{table: table} do
    Cache.seed(table, [light("light-1"), device("Desk Lamp", "device-1", "light-1")])

    assert {:ok, %{"id" => "light-1"}} = Graph.resolve(table, :light, "Desk Lamp")
  end

  test "a rid resolves to itself", %{table: table} do
    Cache.seed(table, [light("light-1")])

    assert {:ok, %{"id" => "light-1"}} = Graph.resolve(table, :light, "light-1")
  end

  test "a rid is tried before a name, so a light named like a rid still works", %{table: table} do
    Cache.seed(table, [light("light-1"), device("light-1", "device-1", "light-2"), light("light-2")])

    assert {:ok, %{"id" => "light-1"}} = Graph.resolve(table, :light, "light-1")
  end

  test "a target that is neither is :not_found", %{table: table} do
    Cache.seed(table, [light("light-1")])

    assert {:error, %Error{reason: :not_found}} = Graph.resolve(table, :light, "Nowhere")
  end

  test "a room resolves to its grouped_light", %{table: table} do
    Cache.seed(table, [
      room("Living Room", "room-1", [
        %{"rid" => "gl-1", "rtype" => "grouped_light"},
        %{"rid" => "other-1", "rtype" => "zigbee_connectivity"}
      ]),
      %{"type" => "grouped_light", "id" => "gl-1", "on" => %{"on" => false}}
    ])

    assert {:ok, %{"id" => "gl-1", "type" => "grouped_light"}} =
             Graph.grouped_light(table, :room, "Living Room")
  end

  test "a zone resolves to its grouped_light", %{table: table} do
    Cache.seed(table, [
      %{
        "type" => "zone",
        "id" => "zone-1",
        "metadata" => %{"name" => "Downstairs"},
        "services" => [%{"rid" => "gl-2", "rtype" => "grouped_light"}]
      },
      %{"type" => "grouped_light", "id" => "gl-2", "on" => %{"on" => false}}
    ])

    assert {:ok, %{"id" => "gl-2"}} = Graph.grouped_light(table, :zone, "Downstairs")
  end

  test "an empty room with no grouped_light service is :no_grouped_light", %{table: table} do
    Cache.seed(table, [room("Spare Room", "room-2", [])])

    assert {:error, %Error{reason: :no_grouped_light, rid: "room-2"}} =
             Graph.grouped_light(table, :room, "Spare Room")
  end

  test "a room whose grouped_light service is not in the cache is :not_found", %{table: table} do
    Cache.seed(table, [
      room("Living Room", "room-1", [%{"rid" => "gl-missing", "rtype" => "grouped_light"}])
    ])

    assert {:error, %Error{reason: :not_found, rid: "gl-missing"}} =
             Graph.grouped_light(table, :room, "Living Room")
  end

  test "a room that does not exist is :not_found, not :no_grouped_light", %{table: table} do
    Cache.seed(table, [])

    assert {:error, %Error{reason: :not_found}} = Graph.grouped_light(table, :room, "Nowhere")
  end

  test "resolution on an unsynced cache is :not_synced", %{table: table} do
    assert {:error, %Error{reason: :not_synced}} = Graph.resolve(table, :light, "Desk Lamp")
    assert {:error, %Error{reason: :not_synced}} = Graph.grouped_light(table, :room, "Living Room")
  end

  test "every room on the real fixture either has a grouped_light or reports it has none",
       %{table: table} do
    Cache.seed(table, Hue.Fixtures.full_state()["data"])

    {:ok, rooms} = Cache.list(table, :room)

    outcomes =
      Enum.map(rooms, fn room ->
        case Graph.grouped_light(table, :room, room["id"]) do
          {:ok, %{"type" => "grouped_light"}} -> :grouped
          {:error, %Error{reason: :no_grouped_light}} -> :empty
        end
      end)

    assert Enum.count(outcomes, &(&1 == :empty)) == 2
    assert Enum.count(outcomes, &(&1 == :grouped)) == 4
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/graph_test.exs`
Expected: FAIL — `module Hue.Bridge.Graph is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/hue/bridge/graph.ex`:

```elixir
defmodule Hue.Bridge.Graph do
  @moduledoc """
  Walks the resource graph to turn a target a human wrote into a resource this
  library can act on.

  ## Targets are names or rids, interchangeably

  Names are what a person has in mind; rids are what survives someone renaming
  a room in the Hue app. Both are accepted everywhere a target is, and **rid is
  tried first** — an exact identity match should never lose to a coincidental
  name collision.

  ## Rooms and zones are not writable

  A room has no `on` state. What responds to a write is the `grouped_light`
  service the room owns, reached through `room.services`. That indirection is
  why "dim the living room" is several lookups rather than one, and why doing
  it per call over layer 1 costs several round trips.

  Two rooms on the reference bridge are empty and expose no `grouped_light`
  service at all, so `:no_grouped_light` is a case that fires in real use rather
  than a defensive branch. It is deliberately distinct from `:not_found`: the
  room exists, and telling the caller it does not would send them looking for
  the wrong problem.
  """

  alias Hue.Bridge.Cache
  alias Hue.Error

  @doc """
  Resolves a name-or-rid to the resource itself.

  Tries the rid first; falls back to the name index.
  """
  @spec resolve(Cache.table(), atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(table, type, target) when is_binary(target) do
    case Cache.fetch(table, type, target) do
      {:ok, resource} -> {:ok, resource}
      {:error, %Error{reason: :not_found}} -> Cache.fetch_by_name(table, type, target)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Resolves a room or zone target to the `grouped_light` that acts for it.

  Returns `:no_grouped_light` when the room or zone exists but owns no such
  service — an empty room, which is a real state on real bridges.
  """
  @spec grouped_light(Cache.table(), :room | :zone, String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def grouped_light(table, type, target) when type in [:room, :zone] and is_binary(target) do
    with {:ok, group} <- resolve(table, type, target),
         {:ok, rid} <- grouped_light_rid(group) do
      Cache.fetch(table, :grouped_light, rid)
    end
  end

  defp grouped_light_rid(%{"services" => services, "id" => rid}) when is_list(services) do
    services
    |> Enum.find(&match?(%{"rtype" => "grouped_light"}, &1))
    |> case do
      %{"rid" => grouped_rid} when is_binary(grouped_rid) -> {:ok, grouped_rid}
      _none -> {:error, %Error{reason: :no_grouped_light, rid: rid}}
    end
  end

  defp grouped_light_rid(%{"id" => rid}) do
    {:error, %Error{reason: :no_grouped_light, rid: rid}}
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/graph_test.exs`
Expected: PASS, 12 tests. The fixture test's `2` empty and `4` grouped is the count recorded from the reference bridge on 2026-08-06; if it disagrees, the fixture changed, not the code.

- [ ] **Step 5: Verify rid-before-name is actually exercised**

Swap the two branches of `resolve/3` so the name index is consulted first, then:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/graph_test.exs`
Expected: FAIL on "a rid is tried before a name, so a light named like a rid still works" — it resolves to `light-2`. Restore and confirm PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge/graph.ex test/hue/bridge/graph_test.exs
git commit -m "Walk rooms and zones to the grouped_light that actually accepts writes"
```

---

### Task 6: `Hue.Stub` — the test seam for a library that owns processes

Read "Testing seam" at the top of this plan before starting. In short: `Req.Test` stubs are owned by the process that installs them, and no layer-2 request is made by the test process, so the whole suite would depend on `$callers` propagating through `Task.Supervisor`. A bare function plug closes over the test pid instead and works from any process, with no ownership and no `async: false`.

The eventstream needs more than a canned response — a test has to push frames one at a time and then drop the connection. The plug handles that by sending its own pid to the test and then waiting to be told what to chunk.

**Files:**
- Create: `test/support/stub.ex`
- Test: `test/hue/stub_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/stub_test.exs`:

```elixir
defmodule Hue.StubTest do
  use ExUnit.Case, async: true

  alias Hue.Error
  alias Hue.Resource

  test "the full-state fetch is answered from the fixture by default" do
    client = Hue.Stub.client()

    assert {:ok, resources} = Resource.list_all(client)
    assert length(resources) == 178
  end

  test "the resources answered can be replaced" do
    client = Hue.Stub.client(resources: [%{"type" => "light", "id" => "light-1"}])

    assert {:ok, [%{"id" => "light-1"}]} = Resource.list_all(client)
  end

  test "the fetch reports itself to the test process" do
    client = Hue.Stub.client()

    {:ok, _} = Resource.list_all(client)

    assert_receive {:hue_stub, :fetch, "/clip/v2/resource"}
  end

  test "a fetch can be made to fail a fixed number of times before succeeding" do
    client = Hue.Stub.client(fetch_failures: 2, fetch_status: 503)

    assert {:error, %Error{reason: :bridge_busy}} = Resource.list_all(client)
    assert {:error, %Error{reason: :bridge_busy}} = Resource.list_all(client)
    assert {:ok, resources} = Resource.list_all(client)
    assert length(resources) == 178
  end

  test "a fetch can be made to fail forever" do
    client = Hue.Stub.client(fetch_status: 403)

    assert {:error, %Error{reason: :unauthorized}} = Resource.list_all(client)
    assert {:error, %Error{reason: :unauthorized}} = Resource.list_all(client)
  end

  test "a write reports its path and body to the test process" do
    client = Hue.Stub.client()

    assert :ok = Resource.update(client, :light, "light-1", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", body}
    assert body == %{"on" => %{"on" => true}}
  end

  test "the eventstream hands its pid to the test, chunks frames, and closes" do
    client = Hue.Stub.client()

    task = Task.async(fn -> client |> Hue.Events.stream() |> Enum.to_list() end)

    assert_receive {:hue_stub, :eventstream, stream}

    send(stream, {:frame, "id: 1:0\ndata: [{\"creationtime\":\"t\",\"id\":\"e1\",\"type\":\"update\",\"data\":[{\"type\":\"light\",\"id\":\"light-1\",\"on\":{\"on\":true}}]}]\n\n"})
    send(stream, :close)

    assert [%Hue.Event{type: :update, resource_type: :light, rid: "light-1"}] =
             Task.await(task)
  end

  test "the eventstream can refuse the connection" do
    client = Hue.Stub.client(eventstream_status: 403)

    assert_raise Error, fn -> client |> Hue.Events.stream() |> Enum.to_list() end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/stub_test.exs`
Expected: FAIL — `module Hue.Stub is not available`.

- [ ] **Step 3: Confirm test support is compiled**

Check `mix.exs` for `elixirc_paths(:test)` including `test/support`. Layer 1 already has `test/support/fixtures.ex` compiled, so this is almost certainly present. If `mix.exs` has no `elixirc_paths/1`, add:

```elixir
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
```

and `elixirc_paths: elixirc_paths(Mix.env())` in `project/0`.

- [ ] **Step 4: Write the implementation**

Create `test/support/stub.ex`:

```elixir
defmodule Hue.Stub do
  @moduledoc """
  A bridge that answers over a function plug, for testing layer 2.

  ## Why not `Req.Test`

  `Req.Test` stubs are owned by the process that installs them. Every request
  layer 2 makes is issued by the bridge's own server or by a task it spawned,
  never by the test process, so a `Req.Test` suite here would rest entirely on
  `$callers` propagating through `Task.Supervisor` — an assumption about another
  library's internals, load-bearing under every test in the layer.

  `Hue.new/2` passes unknown options through to `Req.new/1`, and Req accepts a
  bare function as `:plug`. A function plug runs in whichever process makes the
  request and closes over whatever it was built with. No ownership, no
  allowances, and tests stay `async: true`.

  ## Talking to the stub

  Every request announces itself to the process that called `client/1`:

      {:hue_stub, :fetch, path}
      {:hue_stub, :put, path, decoded_body}
      {:hue_stub, :eventstream, stream_pid}

  The eventstream one carries a pid because a stream is not a canned response.
  Send it `{:frame, iodata}` to push bytes down the connection and `:close` to
  end it cleanly; kill it to simulate a drop.

  ## Options

    * `:resources` — what the full-state fetch answers with. Defaults to the
      recorded fixture, all 178 resources.
    * `:fetch_status` — an HTTP status to fail the full-state fetch with.
    * `:fetch_failures` — how many fetches fail with `:fetch_status` before the
      stub starts succeeding. Omit for "every fetch fails".
    * `:eventstream_status` — an HTTP status to refuse the eventstream with.
  """

  @default_body ~s({"errors":[{"description":"stubbed failure"}],"data":[]})
  @unauthorized_body "<html><body>unauthorized user</body></html>"
  @stream_idle_timeout 5_000

  @doc "Builds a client pointed at the stub. See the moduledoc for options."
  @spec client(keyword()) :: Hue.Client.t()
  def client(options \\ []) do
    test = self()
    resources = Keyword.get_lazy(options, :resources, fn -> Hue.Fixtures.full_state()["data"] end)
    fetch_status = Keyword.get(options, :fetch_status)
    eventstream_status = Keyword.get(options, :eventstream_status)

    # A counter rather than an Agent: it is shared across every process that
    # makes a request, and it needs no supervision or cleanup.
    remaining_failures = :counters.new(1, [:atomics])
    :counters.put(remaining_failures, 1, Keyword.get(options, :fetch_failures, -1))

    {:ok, client} =
      Hue.new("192.0.2.10",
        application_key: "k",
        plug: fn conn ->
          route(conn, %{
            test: test,
            resources: resources,
            fetch_status: fetch_status,
            eventstream_status: eventstream_status,
            remaining_failures: remaining_failures
          })
        end
      )

    client
  end

  defp route(%{request_path: "/eventstream/clip/v2"} = conn, config) do
    case config.eventstream_status do
      nil -> eventstream(conn, config)
      status -> refuse(conn, status)
    end
  end

  defp route(%{method: "GET", request_path: "/clip/v2/resource"} = conn, config) do
    send(config.test, {:hue_stub, :fetch, conn.request_path})

    if failing?(config.remaining_failures, config.fetch_status) do
      refuse(conn, config.fetch_status)
    else
      json(conn, 200, %{"errors" => [], "data" => config.resources})
    end
  end

  defp route(%{method: "PUT"} = conn, config) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(config.test, {:hue_stub, :put, conn.request_path, Jason.decode!(raw)})

    json(conn, 200, %{"errors" => [], "data" => []})
  end

  defp route(conn, config) do
    send(config.test, {:hue_stub, :unhandled, conn.method, conn.request_path})
    json(conn, 404, %{"errors" => [%{"description" => "no stub for this path"}], "data" => []})
  end

  # -1 means "fail forever"; any other value counts down and stops failing at 0.
  defp failing?(_counter, nil), do: false

  defp failing?(counter, _status) do
    case :counters.get(counter, 1) do
      0 -> false
      -1 -> true
      _positive -> :counters.sub(counter, 1, 1) == :ok
    end
  end

  defp eventstream(conn, config) do
    send(config.test, {:hue_stub, :eventstream, self()})

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
    |> chunk_loop()
  end

  defp chunk_loop(conn) do
    receive do
      {:frame, data} ->
        {:ok, conn} = Plug.Conn.chunk(conn, data)
        chunk_loop(conn)

      :close ->
        conn
    after
      @stream_idle_timeout -> conn
    end
  end

  defp refuse(conn, 403) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(403, @unauthorized_body)
  end

  defp refuse(conn, status) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, @default_body)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/stub_test.exs`
Expected: PASS, 8 tests.

If the eventstream test hangs, the cause is almost always that `Hue.Events.stream/2` opens the connection lazily on first enumeration — the `assert_receive` cannot fire until something enumerates, which is why the test wraps it in `Task.async`. Do not "fix" that by enumerating in the test process.

- [ ] **Step 6: Verify the stub does not silently swallow unexpected requests**

Run: `cd ~/src/hue-ex && mix test test/hue/stub_test.exs --only test:"the fetch reports itself to the test process"`
Expected: PASS. Then temporarily delete the `send(config.test, {:hue_stub, :fetch, ...})` line and re-run.
Expected: FAIL on `assert_receive`. Restore.

This matters more than it looks: the layer-2 tests that follow assert on *absence* of requests (a coalesced write must produce one PUT, not twenty), and an announcement that quietly stopped firing would make every one of those assertions vacuous.

- [ ] **Step 7: Commit**

```bash
cd ~/src/hue-ex
git add test/support/stub.ex test/hue/stub_test.exs
git commit -m "Test layer 2 over a function plug, so no request needs an owner"
```

---

### Task 7: `Hue.Bridge` — the supervisor, and a cache that syncs once

The smallest version of layer 2 that works end to end: a supervised bridge that fetches the full state once and serves reads from it. No eventstream yet, no writes yet. Everything after this task adds to a thing that already works.

Three children, and the order encodes their dependency. The `Registry` and the `Task.Supervisor` must exist before the server that uses them, and if either dies the server's references to them are stale — so `:rest_for_one`, not `:one_for_one`.

**`start_link/1` must not block on the bridge.** A bridge that is rebooting cannot be allowed to stop the consuming application from booting, so `init/1` creates the table and returns, and the fetch happens in `handle_continue/2` after `start_link/1` has already returned to the caller.

**Files:**
- Modify: `lib/hue/bridge.ex` (add the supervisor and public API alongside the existing `Info`)
- Create: `lib/hue/bridge/server.ex`
- Test: `test/hue/bridge_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge_test.exs`:

```elixir
defmodule Hue.BridgeTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error

  # Each test gets its own bridge name, which is what makes the whole layer-2
  # suite safely async: the derived server, registry, and ETS table names are
  # all distinct, so no two tests share a process or a table.
  setup context do
    name = Module.concat(Hue.BridgeTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))
    {:ok, name: name}
  end

  defp start(name, client, options \\ []) do
    start_supervised!({Bridge, [name: name, client: client] ++ options}, id: name)
  end

  defp await_live(name, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_live(name, deadline, Bridge.status(name))
  end

  defp await_live(_name, _deadline, :live), do: :ok

  defp await_live(name, deadline, status) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("bridge never reached :live, last status #{inspect(status)}")
    else
      Process.sleep(10)
      await_live(name, deadline, Bridge.status(name))
    end
  end

  test "status is :not_started before anything is running", %{name: name} do
    assert Bridge.status(name) == :not_started
  end

  test "reads before a bridge exists are :not_started, not a crash", %{name: name} do
    assert {:error, %Error{reason: :not_started}} = Bridge.fetch(name, :light, "light-1")
  end

  test "start_link returns without waiting for the bridge", %{name: name} do
    # A stub that never answers the fetch would block a synchronous init.
    client = Hue.Stub.client(fetch_status: 503)

    assert is_pid(start(name, client))
    assert Bridge.status(name) in [:connecting, :syncing, {:error, :bridge_busy}]
  end

  test "the cache is seeded from one full-state request", %{name: name} do
    client = Hue.Stub.client()

    start(name, client)
    await_live(name)

    assert_received {:hue_stub, :fetch, "/clip/v2/resource"}
    refute_received {:hue_stub, :fetch, _}

    assert {:ok, %{"type" => "light"}} = Bridge.fetch(name, :light, first_light_rid())
    assert {:ok, lights} = Bridge.list(name, :light)
    assert length(lights) == 19
  end

  test "reads are :not_synced between start and the first successful fetch", %{name: name} do
    client = Hue.Stub.client(fetch_status: 503)

    start(name, client)

    assert {:error, %Error{reason: :not_synced}} = Bridge.fetch(name, :light, "light-1")
  end

  test "a failed fetch is retried until it succeeds", %{name: name} do
    client = Hue.Stub.client(fetch_failures: 2, fetch_status: 503, resources: [light("light-1")])

    start(name, client, retry_after: 10)
    await_live(name)

    assert {:ok, %{"id" => "light-1"}} = Bridge.fetch(name, :light, "light-1")
  end

  test "a failing bridge reports the reason through status", %{name: name} do
    client = Hue.Stub.client(fetch_status: 403)

    start(name, client, retry_after: 10)

    assert eventually(fn -> Bridge.status(name) == {:error, :unauthorized} end)
  end

  test "lights are readable by the name of the device that owns them", %{name: name} do
    client = Hue.Stub.client()

    start(name, client)
    await_live(name)

    {:ok, lights} = Bridge.list(name, :light)
    rid = hd(lights)["id"]
    device_name = Bridge.name_of(name, :light, rid)

    assert is_binary(device_name)
    assert {:ok, %{"id" => ^rid}} = Bridge.fetch_by_name(name, :light, device_name)
  end

  test "sync emits telemetry carrying the resource count", %{name: name} do
    handler = {__MODULE__, name}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :sync, :stop],
      fn _event, measurements, metadata, _config -> send(test, {:sync, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    start(name, Hue.Stub.client())
    await_live(name)

    assert_receive {:sync, %{duration: duration, resource_count: 178}, %{bridge: ^name}}
    assert duration > 0
  end

  test "two bridges in one test do not share a cache", %{name: name} do
    other = Module.concat(name, Other)

    start(name, Hue.Stub.client(resources: [light("light-1")]))
    start(other, Hue.Stub.client(resources: [light("light-2")]))

    await_live(name)
    await_live(other)

    assert {:ok, [%{"id" => "light-1"}]} = Bridge.list(name, :light)
    assert {:ok, [%{"id" => "light-2"}]} = Bridge.list(other, :light)
  end

  defp light(rid), do: %{"type" => "light", "id" => rid, "on" => %{"on" => false}}

  defp first_light_rid do
    Hue.Fixtures.full_state()["data"]
    |> Enum.find(&(&1["type"] == "light"))
    |> Map.fetch!("id")
  end

  defp eventually(check, remaining \\ 100) do
    cond do
      check.() -> true
      remaining == 0 -> false
      true -> Process.sleep(10) && eventually(check, remaining - 1)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_test.exs`
Expected: FAIL — `function Hue.Bridge.status/1 is undefined or private`.

- [ ] **Step 3: Write the server**

Create `lib/hue/bridge/server.ex`:

```elixir
defmodule Hue.Bridge.Server do
  @moduledoc """
  The process behind `Hue.Bridge`. Owns the ETS table; nothing else writes to it.

  ## What this process is, and is not, on the hot path for

  It is not on the read path at all. `Hue.Bridge.fetch/3` is an `:ets.lookup`
  in the calling process, and this server never hears about it. What the server
  owns is everything that has to be serialised: seeding the cache, merging
  events into it, and — from Task 11 — pacing writes.

  ## Startup is not allowed to depend on the bridge

  `init/1` creates the table and returns. The full fetch runs in
  `handle_continue/2`, which is after `start_link/1` has already returned to the
  supervisor. A bridge that is rebooting, unreachable, or answering 503 delays
  nothing: the consuming application boots, reads report `:not_synced`, and
  `status/1` says why.
  """

  use GenServer

  alias Hue.Bridge.Cache
  alias Hue.Client
  alias Hue.Error
  alias Hue.Resource

  @default_retry_after :timer.seconds(5)

  defstruct [:client, :name, :table, :retry_after]

  @doc false
  def start_link(options) do
    {name, options} = Keyword.pop!(options, :server_name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl GenServer
  def init(options) do
    state = %__MODULE__{
      client: Keyword.fetch!(options, :client),
      name: Keyword.fetch!(options, :name),
      table: Keyword.fetch!(options, :table),
      retry_after: Keyword.get(options, :retry_after, @default_retry_after)
    }

    Cache.new(state.table)

    {:ok, state, {:continue, :sync}}
  end

  @impl GenServer
  def handle_continue(:sync, state) do
    {:noreply, sync(state)}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    {:noreply, sync(state)}
  end

  defp sync(state) do
    Cache.put_status(state.table, :syncing)

    started_at = System.monotonic_time()

    case Resource.list_all(state.client) do
      {:ok, resources} ->
        Cache.seed(state.table, resources)
        Cache.put_status(state.table, :live)

        :telemetry.execute(
          [:hue, :sync, :stop],
          %{duration: System.monotonic_time() - started_at, resource_count: length(resources)},
          %{bridge: state.name}
        )

        state

      {:error, %Error{reason: reason}} ->
        Cache.put_status(state.table, {:error, reason})
        Process.send_after(self(), :sync, state.retry_after)
        state
    end
  end

  @doc false
  @spec client(GenServer.server()) :: Client.t()
  def client(server), do: GenServer.call(server, :client)

  @impl GenServer
  def handle_call(:client, _from, state), do: {:reply, state.client, state}
end
```

- [ ] **Step 4: Write the supervisor and public API**

In `lib/hue/bridge.ex`, keep the existing `Info` submodule exactly as it is and replace the module's `@moduledoc` and add the supervisor around it:

```elixir
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
    # ... unchanged, keep the existing submodule verbatim ...
  end

  @default_name __MODULE__

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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_test.exs`
Expected: PASS, 10 tests.

- [ ] **Step 6: Verify the non-blocking start is real**

This is the property most easily lost to a later "simplification" that moves the fetch into `init/1`. Temporarily change `init/1` to end with `{:ok, sync(state)}` instead of `{:ok, state, {:continue, :sync}}`, then:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_test.exs --only test:"start_link returns without waiting for the bridge"`
Expected: still PASS, because the stub answers 503 immediately rather than hanging — which means **the test as written does not protect the property**. Fix the test before continuing: add a stub option that never answers, or assert on ordering. The simplest honest fix is to assert the status is not yet terminal at the instant `start_link` returns:

```elixir
  test "start_link returns without waiting for the bridge", %{name: name} do
    client = Hue.Stub.client(fetch_status: 503)

    assert is_pid(start(name, client))
    # handle_continue has not run yet at the moment start_link returns, so the
    # table exists with its initial status and no fetch has been attempted.
    assert Bridge.status(name) == :connecting
  end
```

Re-run with the blocking `init/1` still in place.
Expected: FAIL — status is already `{:error, :bridge_busy}`. Restore `handle_continue` and confirm PASS.

- [ ] **Step 7: Run the whole suite**

Run: `cd ~/src/hue-ex && mix test`
Expected: PASS, all offline tests. Layer 1's suite must be untouched.

- [ ] **Step 8: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge.ex lib/hue/bridge/server.ex test/hue/bridge_test.exs
git commit -m "Supervise a bridge that seeds its cache from one full fetch"
```

---

### Task 8: The eventstream, and what happens when it dies

The cache is currently a snapshot. This makes it live.

**Ordering is the whole design.** The naive sequence — fetch, then open the stream — drops every change that happens in the gap. The correct sequence is: open the stream first, **buffer** what it delivers, then fetch, then seed, then replay the buffer on top. A change that arrives during the fetch is applied after the state it modifies, which is the only order that ends correct.

That narrows the window rather than closing it: `Hue.Events.stream/2` connects lazily on first enumeration, so there is a moment between "the task started" and "the socket is open" that this design cannot observe. It is smaller than the fetch it replaces (headers versus 154 KB) and it costs nothing to narrow it this way, so it is worth doing — but the docstring says so rather than claiming a guarantee the code does not deliver.

**Reconnect always refetches.** No `Last-Event-ID`. The full state is one request; resumption buys 154 KB and pays for it with a class of bug where resumption appears to succeed while events were missed.

**A dead stream is the characteristic failure of this library**, because it is silent: every read keeps answering, and every answer is quietly stale. No keepalive arrived within a 100-second observation window beyond the initial `: hi`, so an idle stream is protocol-indistinguishable from a dead one. `[:hue, :stream, :disconnected]` is the only thing that reveals it.

**Files:**
- Modify: `lib/hue/bridge/server.ex`
- Test: `test/hue/bridge_stream_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge_stream_test.exs`:

```elixir
defmodule Hue.BridgeStreamTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge

  setup context do
    name =
      Module.concat(Hue.BridgeStreamTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

    {:ok, name: name}
  end

  defp light(rid, brightness) do
    %{
      "type" => "light",
      "id" => rid,
      "on" => %{"on" => false},
      "dimming" => %{"brightness" => brightness, "min_dim_level" => 0.2}
    }
  end

  defp frame(resources) do
    envelope = %{
      "creationtime" => "2026-08-07T10:00:00Z",
      "id" => "event-1",
      "type" => "update",
      "data" => resources
    }

    "id: 1:0\ndata: #{Jason.encode!([envelope])}\n\n"
  end

  defp start(name, client, options \\ []) do
    start_supervised!({Bridge, [name: name, client: client] ++ options}, id: name)
  end

  defp await_live(name), do: assert_eventually(fn -> Bridge.status(name) == :live end)

  defp assert_eventually(check, remaining \\ 200) do
    cond do
      check.() -> true
      remaining == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && assert_eventually(check, remaining - 1)
    end
  end

  test "an update event reaches the cache", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 42.0)])

    start(name, client)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    send(stream, {:frame, frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])})

    assert_eventually(fn ->
      {:ok, cached} = Bridge.fetch(name, :light, "light-1")
      cached["on"] == %{"on" => true}
    end)
  end

  test "a partial event does not erase the rest of the light", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 42.0)])

    start(name, client)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    send(
      stream,
      {:frame,
       frame([%{"type" => "light", "id" => "light-1", "dimming" => %{"brightness" => 86.11}}])}
    )

    assert_eventually(fn ->
      {:ok, cached} = Bridge.fetch(name, :light, "light-1")
      cached["dimming"] == %{"brightness" => 86.11, "min_dim_level" => 0.2}
    end)
  end

  test "one frame carrying several resources applies all of them", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 10.0), light("light-2", 20.0)])

    start(name, client)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    send(
      stream,
      {:frame,
       frame([
         %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}},
         %{"type" => "light", "id" => "light-2", "on" => %{"on" => true}}
       ])}
    )

    assert_eventually(fn ->
      {:ok, one} = Bridge.fetch(name, :light, "light-1")
      {:ok, two} = Bridge.fetch(name, :light, "light-2")
      one["on"]["on"] and two["on"]["on"]
    end)
  end

  test "the stream is opened before the fetch, so nothing is missed in between", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 42.0)])

    start(name, client)

    # The eventstream announcement must arrive before the fetch announcement.
    assert_receive {:hue_stub, :eventstream, _stream}
    assert_receive {:hue_stub, :fetch, _path}
  end

  test "an event arriving during the sync is replayed on top of the seeded state", %{name: name} do
    # fetch_failures delays the seed, giving the test a window to deliver an
    # event while the bridge is still syncing.
    client =
      Hue.Stub.client(
        resources: [light("light-1", 42.0)],
        fetch_failures: 1,
        fetch_status: 503
      )

    start(name, client, retry_after: 200)
    assert_receive {:hue_stub, :eventstream, stream}
    assert_receive {:hue_stub, :fetch, _}

    send(stream, {:frame, frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])})
    Process.sleep(50)

    await_live(name)

    # The seed says on: false. The buffered event says on: true and must win,
    # because it happened after the state the fetch described.
    assert_eventually(fn ->
      {:ok, cached} = Bridge.fetch(name, :light, "light-1")
      cached["on"] == %{"on" => true}
    end)
  end

  test "a dropped stream is refetched, not resumed", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 42.0)])

    start(name, client, reconnect_after: 10)
    assert_receive {:hue_stub, :eventstream, stream}
    assert_receive {:hue_stub, :fetch, _}
    await_live(name)

    Process.exit(stream, :kill)

    # A second eventstream and a second full fetch, in that order.
    assert_receive {:hue_stub, :eventstream, _}, 1_000
    assert_receive {:hue_stub, :fetch, _}, 1_000
  end

  test "a dropped stream emits disconnected telemetry", %{name: name} do
    handler = {__MODULE__, name, :disconnected}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :stream, :disconnected],
      fn _e, measurements, metadata, _c -> send(test, {:disconnected, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    start(name, Hue.Stub.client(resources: []), reconnect_after: 10)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    Process.exit(stream, :kill)

    assert_receive {:disconnected, _measurements, %{bridge: ^name, reason: :killed}}, 1_000
  end

  test "reaching live emits connected telemetry carrying downtime", %{name: name} do
    handler = {__MODULE__, name, :connected}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :stream, :connected],
      fn _e, measurements, metadata, _c -> send(test, {:connected, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    start(name, Hue.Stub.client(resources: []))

    assert_receive {:connected, %{downtime: 0}, %{bridge: ^name}}, 1_000
  end

  test "the cache keeps answering while the stream is down", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 42.0)])

    start(name, client, reconnect_after: 10_000)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    Process.exit(stream, :kill)

    assert_eventually(fn -> match?({:error, _}, Bridge.status(name)) end)
    assert {:ok, %{"id" => "light-1"}} = Bridge.fetch(name, :light, "light-1")
  end

  test "reconnect backoff grows rather than hammering a flapping bridge", %{name: name} do
    client = Hue.Stub.client(resources: [], eventstream_status: 403)

    start(name, client, reconnect_after: 20, max_reconnect_after: 200)

    assert_receive {:hue_stub, :fetch, _}, 1_000

    # Three refusals, with the gap between them growing. Timing assertions are
    # coarse on purpose: the property is "grows", not "grows to exactly 40ms".
    first = System.monotonic_time(:millisecond)
    assert_eventually(fn -> match?({:error, _}, Bridge.status(name)) end)
    Process.sleep(300)
    elapsed = System.monotonic_time(:millisecond) - first

    assert elapsed >= 300
    assert Bridge.status(name) != :live
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_stream_test.exs`
Expected: FAIL — the first assertion to go is `assert_receive {:hue_stub, :eventstream, stream}`, because nothing opens a stream yet.

- [ ] **Step 3: Rewrite the server around connect → buffer → sync → replay**

Replace the body of `lib/hue/bridge/server.ex` (keep the module name and the `client/1` call):

```elixir
defmodule Hue.Bridge.Server do
  @moduledoc """
  The process behind `Hue.Bridge`. Owns the ETS table; nothing else writes to it.

  ## What this process is, and is not, on the hot path for

  It is not on the read path at all. `Hue.Bridge.fetch/3` is an `:ets.lookup`
  in the calling process, and this server never hears about it. What the server
  owns is everything that has to be serialised: seeding the cache, merging
  events into it, and pacing writes.

  ## Startup is not allowed to depend on the bridge

  `init/1` creates the table and returns. Everything else runs in
  `handle_continue/2`, after `start_link/1` has already returned to the
  supervisor. A bridge that is rebooting, unreachable, or answering 503 delays
  nothing: the consuming application boots, reads report `:not_synced`, and
  `status/1` says why.

  ## The connect sequence, and why it is in this order

      open the stream → buffer what it delivers → fetch → seed → replay buffer → live

  Fetching first and then opening the stream loses every change that happens in
  between. Opening first and replaying the buffer on top of the seed applies
  each change after the state it modifies, which is the only ordering that ends
  correct.

  This narrows the window without closing it. `Hue.Events.stream/2` connects
  lazily on first enumeration, so there is a moment between "the task started"
  and "the socket is open" that this process cannot observe. It is smaller than
  the fetch it replaces — request headers against 154 KB of response — and
  narrowing it costs nothing, but it is a narrowing and not a guarantee.

  ## Reconnect always refetches

  No `Last-Event-ID` resumption. The alternative buys 154 KB on an event that
  should be rare, and pays for it with a class of bug in which resumption
  appears to have succeeded while events were in fact missed.
  """

  use GenServer

  alias Hue.Bridge
  alias Hue.Bridge.Cache
  alias Hue.Client
  alias Hue.Error
  alias Hue.Event
  alias Hue.Resource

  @default_retry_after :timer.seconds(5)
  @default_reconnect_after :timer.seconds(1)
  @default_max_reconnect_after :timer.seconds(60)

  defstruct [
    :client,
    :name,
    :table,
    :retry_after,
    :reconnect_after,
    :max_reconnect_after,
    :stream_task,
    :disconnected_at,
    backoff: nil,
    buffer: [],
    syncing?: true
  ]

  @doc false
  def start_link(options) do
    {name, options} = Keyword.pop!(options, :server_name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl GenServer
  def init(options) do
    state = %__MODULE__{
      client: Keyword.fetch!(options, :client),
      name: Keyword.fetch!(options, :name),
      table: Keyword.fetch!(options, :table),
      retry_after: Keyword.get(options, :retry_after, @default_retry_after),
      reconnect_after: Keyword.get(options, :reconnect_after, @default_reconnect_after),
      max_reconnect_after: Keyword.get(options, :max_reconnect_after, @default_max_reconnect_after)
    }

    Cache.new(state.table)

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    {:noreply, state |> open_stream() |> sync()}
  end

  @impl GenServer
  def handle_info(:sync, state), do: {:noreply, sync(state)}

  def handle_info(:reconnect, state), do: {:noreply, state |> open_stream() |> sync()}

  def handle_info({:hue_event, event}, %{syncing?: true} = state) do
    {:noreply, %{state | buffer: [event | state.buffer]}}
  end

  def handle_info({:hue_event, event}, state) do
    Cache.apply_event(state.table, event)
    {:noreply, state}
  end

  # Task.Supervisor.async_nolink sends this when the stream ends without
  # raising -- the bridge closed the connection cleanly. That is still a
  # disconnect from this process's point of view.
  def handle_info({ref, _result}, %{stream_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, disconnected(state, :closed)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{stream_task: %Task{ref: ref}} = state) do
    {:noreply, disconnected(state, exit_reason(reason))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec client(GenServer.server()) :: Client.t()
  def client(server), do: GenServer.call(server, :client)

  @impl GenServer
  def handle_call(:client, _from, state), do: {:reply, state.client, state}

  # -- connect ---------------------------------------------------------------

  defp open_stream(state) do
    server = self()

    task =
      Task.Supervisor.async_nolink(Bridge.tasks(state.name), fn ->
        state.client
        |> Hue.Events.stream()
        |> Enum.each(&send(server, {:hue_event, &1}))
      end)

    %{state | stream_task: task, syncing?: true, buffer: []}
  end

  defp sync(state) do
    Cache.put_status(state.table, :syncing)
    started_at = System.monotonic_time()

    case Resource.list_all(state.client) do
      {:ok, resources} -> seed(state, resources, started_at)
      {:error, %Error{reason: reason}} -> sync_failed(state, reason)
    end
  end

  defp seed(state, resources, started_at) do
    Cache.seed(state.table, resources)

    # Oldest first: the buffer is built by prepending.
    state.buffer
    |> Enum.reverse()
    |> Enum.each(&Cache.apply_event(state.table, &1))

    Cache.put_status(state.table, :live)

    :telemetry.execute(
      [:hue, :sync, :stop],
      %{duration: System.monotonic_time() - started_at, resource_count: length(resources)},
      %{bridge: state.name}
    )

    :telemetry.execute(
      [:hue, :stream, :connected],
      %{downtime: downtime(state)},
      %{bridge: state.name}
    )

    %{state | syncing?: false, buffer: [], backoff: nil, disconnected_at: nil}
  end

  defp sync_failed(state, reason) do
    Cache.put_status(state.table, {:error, reason})
    Process.send_after(self(), :sync, state.retry_after)
    state
  end

  # -- disconnect ------------------------------------------------------------

  defp disconnected(state, reason) do
    :telemetry.execute(
      [:hue, :stream, :disconnected],
      %{},
      %{bridge: state.name, reason: reason}
    )

    Cache.put_status(state.table, {:error, reason})

    backoff = next_backoff(state)
    Process.send_after(self(), :reconnect, backoff)

    %{
      state
      | stream_task: nil,
        syncing?: true,
        buffer: [],
        backoff: backoff,
        disconnected_at: state.disconnected_at || System.monotonic_time(:millisecond)
    }
  end

  defp next_backoff(%{backoff: nil} = state), do: state.reconnect_after

  defp next_backoff(state), do: min(state.backoff * 2, state.max_reconnect_after)

  defp downtime(%{disconnected_at: nil}), do: 0
  defp downtime(state), do: System.monotonic_time(:millisecond) - state.disconnected_at

  defp exit_reason({%Error{reason: reason}, _stacktrace}), do: reason
  defp exit_reason({reason, _stacktrace}) when is_atom(reason), do: reason
  defp exit_reason(reason) when is_atom(reason), do: reason
  defp exit_reason(_other), do: :unknown
end
```

- [ ] **Step 4: Handle the `Event` alias being unused**

The module aliases `Hue.Event` but does not reference the struct by name yet — Task 9 will. Remove the `alias Hue.Event` line for now rather than leaving a warning; the suite runs with `--warnings-as-errors` in `precommit`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_stream_test.exs`
Expected: PASS, 10 tests.

If "an event arriving during the sync is replayed on top of the seeded state" is flaky, the cause is the 50 ms sleep racing the 200 ms retry, not the implementation. Widen `retry_after` in that test; do not widen the sleep, which would hide a real ordering bug behind a longer wait.

- [ ] **Step 6: Verify the ordering property is actually protected**

Two separate things to break.

First, swap the connect order — `state |> sync() |> open_stream()`:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_stream_test.exs`
Expected: FAIL on "the stream is opened before the fetch, so nothing is missed in between".

Second, restore that and instead replay the buffer **before** seeding (move the `Enum.each` above `Cache.seed/2`):

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_stream_test.exs`
Expected: FAIL on "an event arriving during the sync is replayed on top of the seeded state" — the seed's `on: false` overwrites the event's `on: true`. This is the bug the whole ordering exists to prevent; if the test does not catch it, fix the test.

Restore both and confirm PASS.

- [ ] **Step 7: Verify a clean stream close is treated as a disconnect**

The `{ref, result}` clause is easy to omit, and omitting it means a bridge that closes the stream gracefully never reconnects — the worst failure mode this library has, because everything keeps answering.

Temporarily delete the `handle_info({ref, _result}, ...)` clause, then:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_stream_test.exs --only test:"a dropped stream is refetched, not resumed"`
Expected: still PASS, because that test *kills* the stream rather than closing it. So add a test that closes it cleanly:

```elixir
  test "a cleanly closed stream reconnects too", %{name: name} do
    client = Hue.Stub.client(resources: [])

    start(name, client, reconnect_after: 10)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    send(stream, :close)

    assert_receive {:hue_stub, :eventstream, _}, 1_000
  end
```

Re-run with the clause still deleted.
Expected: FAIL. Restore the clause and confirm PASS.

- [ ] **Step 8: Run the whole suite**

Run: `cd ~/src/hue-ex && mix test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge/server.ex test/hue/bridge_stream_test.exs
git commit -m "Open the stream before the fetch and replay what arrived during it"
```

---

### Task 9: Subscriptions — filtered at the registry, not at the consumer

A consumer waiting on button presses must not wake up for all nineteen lights when a scene runs. That is the whole reason filtering is a registry key rather than a check the subscriber performs after being woken.

`Registry` with `:duplicate` keys gives this directly: register under the key you care about, and the server dispatches to the two or three keys an event matches. A subscriber to `{:type, :button}` is never in the entry list for a light event, so `Registry.dispatch/3` never reaches them.

**Names are resolved before the event is applied**, deliberately. A `delete` removes the resource and its index entries, so resolving afterwards would mean a subscriber who asked for "Iris" never hears that Iris was deleted — the one event they most needed. The cost is that a rename notifies under the old name; that is the correct reading of "which subscription does this event concern", since the subscriber asked about the thing they knew as Iris.

**Files:**
- Modify: `lib/hue/bridge/server.ex` (dispatch after apply)
- Modify: `lib/hue/bridge.ex` (`subscribe/2`, `unsubscribe/2`)
- Test: `test/hue/bridge_subscriptions_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge_subscriptions_test.exs`:

```elixir
defmodule Hue.BridgeSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Event

  setup context do
    name =
      Module.concat(
        Hue.BridgeSubscriptionsTest,
        context.test |> to_string() |> String.replace(~r/\W/, "_")
      )

    resources = [
      %{"type" => "light", "id" => "light-1", "on" => %{"on" => false}},
      %{"type" => "light", "id" => "light-2", "on" => %{"on" => false}},
      %{"type" => "button", "id" => "button-1"},
      %{
        "type" => "device",
        "id" => "device-1",
        "metadata" => %{"name" => "Iris"},
        "services" => [%{"rid" => "light-1", "rtype" => "light"}]
      }
    ]

    client = Hue.Stub.client(resources: resources)
    start_supervised!({Bridge, name: name, client: client}, id: name)

    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    {:ok, name: name, stream: stream}
  end

  defp await_live(name, remaining \\ 200) do
    cond do
      Bridge.status(name) == :live -> :ok
      remaining == 0 -> flunk("bridge never reached :live")
      true -> Process.sleep(10) && await_live(name, remaining - 1)
    end
  end

  defp push(stream, resources) do
    envelope = %{
      "creationtime" => "2026-08-07T10:00:00Z",
      "id" => "event-1",
      "type" => "update",
      "data" => resources
    }

    send(stream, {:frame, "id: 1:0\ndata: #{Jason.encode!([envelope])}\n\n"})
  end

  test "an unfiltered subscription receives everything", %{name: name, stream: stream} do
    :ok = Bridge.subscribe(name)

    push(stream, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])

    assert_receive {:hue, %Event{resource_type: :light, rid: "light-1"}}
  end

  test "a type subscription receives its type", %{name: name, stream: stream} do
    :ok = Bridge.subscribe(name, type: :button)

    push(stream, [%{"type" => "button", "id" => "button-1", "button" => %{"last_event" => "initial_press"}}])

    assert_receive {:hue, %Event{resource_type: :button, rid: "button-1"}}
  end

  test "a type subscription is not woken by other types", %{name: name, stream: stream} do
    :ok = Bridge.subscribe(name, type: :button)

    push(stream, [
      %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}},
      %{"type" => "light", "id" => "light-2", "on" => %{"on" => true}}
    ])

    refute_receive {:hue, _}, 200
  end

  test "a name subscription receives the light that device names", %{name: name, stream: stream} do
    :ok = Bridge.subscribe(name, name: "Iris")

    push(stream, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])

    assert_receive {:hue, %Event{rid: "light-1"}}
  end

  test "a name subscription is not woken by a different light", %{name: name, stream: stream} do
    :ok = Bridge.subscribe(name, name: "Iris")

    push(stream, [%{"type" => "light", "id" => "light-2", "on" => %{"on" => true}}])

    refute_receive {:hue, _}, 200
  end

  test "a rid subscription receives that rid", %{name: name, stream: stream} do
    :ok = Bridge.subscribe(name, rid: "light-2")

    push(stream, [%{"type" => "light", "id" => "light-2", "on" => %{"on" => true}}])

    assert_receive {:hue, %Event{rid: "light-2"}}
  end

  test "a name subscriber still hears the delete that removes the name", %{
    name: name,
    stream: stream
  } do
    :ok = Bridge.subscribe(name, name: "Iris")

    envelope = %{
      "creationtime" => "2026-08-07T10:00:00Z",
      "id" => "event-1",
      "type" => "delete",
      "data" => [%{"type" => "light", "id" => "light-1"}]
    }

    send(stream, {:frame, "id: 1:0\ndata: #{Jason.encode!([envelope])}\n\n"})

    assert_receive {:hue, %Event{type: :delete, rid: "light-1"}}
  end

  test "unsubscribing stops delivery", %{name: name, stream: stream} do
    :ok = Bridge.subscribe(name)
    :ok = Bridge.unsubscribe(name)

    push(stream, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])

    refute_receive {:hue, _}, 200
  end

  test "a dead subscriber is cleaned up without the server noticing", %{
    name: name,
    stream: stream
  } do
    test = self()

    subscriber =
      spawn(fn ->
        :ok = Bridge.subscribe(name)
        send(test, :subscribed)
        Process.sleep(:infinity)
      end)

    assert_receive :subscribed
    Process.exit(subscriber, :kill)
    Process.sleep(20)

    push(stream, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])

    # The server must survive dispatching to a registry the dead pid has left.
    Process.sleep(50)
    assert Bridge.status(name) == :live
  end

  test "subscribing to a bridge that is not running is an error", %{name: _name} do
    assert {:error, %Hue.Error{reason: :not_started}} =
             Bridge.subscribe(Hue.BridgeSubscriptionsTest.Nowhere)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_subscriptions_test.exs`
Expected: FAIL — `function Hue.Bridge.subscribe/1 is undefined or private`.

- [ ] **Step 3: Add dispatch to the server**

In `lib/hue/bridge/server.ex`, restore `alias Hue.Event`, then change the live-event clause to resolve the name first, apply, and dispatch:

```elixir
  def handle_info({:hue_event, event}, state) do
    # Resolved before applying: a delete removes the resource and its index
    # entries, and a subscriber who asked for "Iris" by name most needs to hear
    # the event that removed Iris.
    name = Cache.name_of(state.table, event.resource_type, event.rid)

    Cache.apply_event(state.table, event)
    dispatch(state, event, name)

    {:noreply, state}
  end
```

and add the private dispatcher:

```elixir
  defp dispatch(state, %Event{} = event, resource_name) do
    registry = Bridge.registry(state.name)
    message = {:hue, event}

    keys = [:all, {:type, event.resource_type}, {:rid, event.rid}]
    keys = if resource_name, do: [{:name, resource_name} | keys], else: keys

    Enum.each(keys, fn key ->
      Registry.dispatch(registry, key, fn subscribers ->
        Enum.each(subscribers, fn {pid, _value} -> send(pid, message) end)
      end)
    end)
  end
```

- [ ] **Step 4: Add the public subscription API**

In `lib/hue/bridge.ex`, add:

```elixir
  @doc """
  Subscribes the calling process to this bridge's events.

  Delivers `{:hue, %Hue.Event{}}`. The subscription is removed automatically
  when the calling process dies — `Registry` monitors it — so a LiveView that
  crashes leaves nothing behind.

  ## Filters

      Hue.Bridge.subscribe(bridge)                  # everything
      Hue.Bridge.subscribe(bridge, type: :button)   # just switches
      Hue.Bridge.subscribe(bridge, name: "Iris")    # one light, by its device's name
      Hue.Bridge.subscribe(bridge, rid: rid)        # one resource, by identity

  Filtering happens at the registry rather than in your `handle_info`. A process
  waiting on button presses is not in the dispatch list for a light event at
  all, so it is not woken when a scene runs and nineteen lights change.

  Subscribing twice with different filters delivers twice for an event matching
  both. That is the honest reading of two subscriptions; use one filter if you
  want one message.

  ## A note on names

  An event is matched against the name the resource had **before** the event was
  applied. For everything except a rename these are the same. For a rename, the
  event is delivered to subscribers of the old name and subsequent events to the
  new — which is what a subscriber who asked about "Iris" would expect to see.
  """
  @spec subscribe(atom(), keyword()) :: :ok | {:error, Error.t()}
  def subscribe(name \\ @default_name, filter \\ []) do
    case Registry.register(registry(name), subscription_key(filter), nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  rescue
    ArgumentError -> {:error, %Error{reason: :not_started}}
  end

  @doc "Removes a subscription registered with the same filter."
  @spec unsubscribe(atom(), keyword()) :: :ok
  def unsubscribe(name \\ @default_name, filter \\ []) do
    Registry.unregister(registry(name), subscription_key(filter))
  rescue
    ArgumentError -> :ok
  end

  defp subscription_key([]), do: :all
  defp subscription_key(type: type), do: {:type, type}
  defp subscription_key(name: name), do: {:name, name}
  defp subscription_key(rid: rid), do: {:rid, rid}

  defp subscription_key(filter) do
    raise ArgumentError,
          "expected one of type:, name:, or rid:, or no filter at all, got: #{inspect(filter)}"
  end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_subscriptions_test.exs`
Expected: PASS, 11 tests.

- [ ] **Step 6: Verify filtering is real, not incidental**

The two `refute_receive` tests pass trivially if dispatch is broken altogether, so prove they fail when filtering is removed rather than when dispatch is. Temporarily change `dispatch/3` to always use `keys = [:all]` **and** change `subscription_key/1` to always return `:all`:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_subscriptions_test.exs`
Expected: FAIL on "a type subscription is not woken by other types" and on "a name subscription is not woken by a different light". Restore and confirm PASS.

- [ ] **Step 7: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge.ex lib/hue/bridge/server.ex test/hue/bridge_subscriptions_test.exs
git commit -m "Filter subscriptions at the registry so buttons do not wake for lights"
```

---

### Task 10: `Hue.Bridge.Body` — options to CLIP v2, with capabilities checked first

Two kinds of wrongness, handled differently, and the distinction is the point of this module.

`brightness: "loud"` is a **caller bug**. It cannot be handled at runtime, only fixed in source, so it **raises**.

`color:` sent to a white-only bulb is a **capability mismatch the caller could not have known about** — the bulb is a fact about the user's house, not about the code — so it returns `{:error, %Hue.Error{reason: :not_color_capable}}`.

And because the cache holds every light's capabilities, that check happens **before the request leaves**. That is strictly better than watching the bridge reject it: no round trip, and an error that names the light rather than a CLIP description. The reference bridge's two lights with no `dimming` key at all make `:not_dimmable` a case that fires in real use.

**Files:**
- Create: `lib/hue/bridge/body.ex`
- Test: `test/hue/bridge/body_test.exs`

- [ ] **Step 1: Confirm what `Hue.Color.payload/2` already does**

Before writing anything, check layer 1's behaviour for a light with no `"color"` key — this module must delegate rather than duplicate the check.

Run: `cd ~/src/hue-ex && mix run -e 'IO.inspect(Hue.Color.payload("#ff8800", %{"type" => "light", "id" => "l"}))'`

Record the result. If it is `{:error, %Hue.Error{reason: :not_color_capable}}`, delegate to it. If it is anything else, the capability check belongs in this module and the test below must assert on this module producing it. Do the same for `Hue.Color.mirek_for/2` against a light with no `"color_temperature"`.

- [ ] **Step 2: Write the failing test**

Create `test/hue/bridge/body_test.exs`:

```elixir
defmodule Hue.Bridge.BodyTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Body
  alias Hue.Error

  defp light(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "light",
        "id" => "light-1",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0, "min_dim_level" => 0.2},
        "color" => %{
          "gamut_type" => "C",
          "gamut" => %{
            "red" => %{"x" => 0.6915, "y" => 0.3083},
            "green" => %{"x" => 0.1700, "y" => 0.7000},
            "blue" => %{"x" => 0.1532, "y" => 0.0475}
          }
        },
        "color_temperature" => %{"mirek_schema" => %{"mirek_minimum" => 153, "mirek_maximum" => 500}}
      },
      extra
    )
  end

  defp plain_light, do: %{"type" => "light", "id" => "light-2", "on" => %{"on" => false}}

  test "on translates" do
    assert {:ok, %{"on" => %{"on" => true}}} = Body.build([on: true], light())
    assert {:ok, %{"on" => %{"on" => false}}} = Body.build([on: false], light())
  end

  test "brightness translates to a float under dimming" do
    assert {:ok, %{"dimming" => %{"brightness" => 40.0}}} = Body.build([brightness: 40], light())
    assert {:ok, %{"dimming" => %{"brightness" => 40.5}}} = Body.build([brightness: 40.5], light())
  end

  test "brightness on a light with no dimming key is :not_dimmable" do
    assert {:error, %Error{reason: :not_dimmable, rid: "light-2"}} =
             Body.build([brightness: 40], plain_light())
  end

  test "transition translates to dynamics duration" do
    assert {:ok, %{"dynamics" => %{"duration" => 400}}} = Body.build([transition: 400], light())
  end

  test "color translates through the light's own gamut" do
    assert {:ok, %{"color" => %{"xy" => %{"x" => x, "y" => y}}}} =
             Body.build([color: "#ff8800"], light())

    assert is_float(x) and is_float(y)
  end

  test "color on a light with no color key is :not_color_capable" do
    assert {:error, %Error{reason: :not_color_capable}} =
             Body.build([color: "#ff8800"], plain_light())
  end

  test "kelvin translates to mirek within the light's own schema" do
    assert {:ok, %{"color_temperature" => %{"mirek" => 370}}} =
             Body.build([kelvin: 2700], light())
  end

  test "several options combine into one body" do
    assert {:ok, body} = Body.build([on: true, brightness: 40, transition: 400], light())

    assert body == %{
             "on" => %{"on" => true},
             "dimming" => %{"brightness" => 40.0},
             "dynamics" => %{"duration" => 400}
           }
  end

  test "an empty option list is an empty body" do
    assert {:ok, %{}} = Body.build([], light())
  end

  test "a non-numeric brightness raises rather than returning an error" do
    assert_raise ArgumentError, ~r/brightness/, fn -> Body.build([brightness: "loud"], light()) end
  end

  test "a non-boolean on raises" do
    assert_raise ArgumentError, ~r/on/, fn -> Body.build([on: "yes"], light()) end
  end

  test "a negative transition raises" do
    assert_raise ArgumentError, ~r/transition/, fn -> Body.build([transition: -1], light()) end
  end

  test "an unknown option raises and says what is accepted" do
    assert_raise ArgumentError, ~r/nonsense/, fn -> Body.build([nonsense: 1], light()) end
  end

  test "the first capability failure wins and the rest is not attempted" do
    assert {:error, %Error{reason: :not_dimmable}} =
             Body.build([on: true, brightness: 40], plain_light())
  end

  test "a grouped_light accepts on and brightness like a light does" do
    grouped = %{
      "type" => "grouped_light",
      "id" => "gl-1",
      "on" => %{"on" => false},
      "dimming" => %{"brightness" => 50.0}
    }

    assert {:ok, %{"on" => %{"on" => true}, "dimming" => %{"brightness" => 25.0}}} =
             Body.build([on: true, brightness: 25], grouped)
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/body_test.exs`
Expected: FAIL — `module Hue.Bridge.Body is not available`.

- [ ] **Step 4: Write the implementation**

Create `lib/hue/bridge/body.ex`. If Step 1 found that `Hue.Color` already returns the capability errors, drop the `capable?` guards for `:color` and `:kelvin` and let the delegation produce them:

```elixir
defmodule Hue.Bridge.Body do
  @moduledoc """
  Translates `set` options into a CLIP v2 request body, checking capabilities
  against the cached resource first.

  ## Two kinds of wrongness

  `brightness: "loud"` is a bug in the calling code. There is no runtime
  handling for it — only a source change — so it **raises**, at the call site,
  with a message naming the option.

  `color: "#ff8800"` sent to a white-only bulb is not a bug. It is a mismatch
  between what the code asked for and what is screwed into a lamp in the user's
  house, which the code could not have known, so it **returns**
  `{:error, %Hue.Error{reason: :not_color_capable}}`.

  ## Capabilities are checked before the request leaves

  Because `Hue.Bridge` caches every light's capabilities, this check does not
  need the bridge's opinion. That is strictly better than sending the request
  and interpreting the rejection: no round trip, and an error that names the
  light rather than quoting a CLIP description. The reference bridge has two
  lights with no `dimming` key at all, so `:not_dimmable` is a case real users
  hit, not a defensive branch.
  """

  alias Hue.Color
  alias Hue.Error

  @known_options [:on, :brightness, :color, :kelvin, :transition]

  @doc """
  Builds the request body for `options` against `resource`.

  Returns `{:ok, body}`, or `{:error, %Hue.Error{}}` for a capability the
  resource does not have. Raises `ArgumentError` for a malformed option.
  """
  @spec build(keyword(), map()) :: {:ok, map()} | {:error, Error.t()}
  def build(options, resource) when is_list(options) and is_map(resource) do
    validate_options!(options)

    Enum.reduce_while(options, {:ok, %{}}, fn option, {:ok, body} ->
      case fragment(option, resource) do
        {:ok, fragment} -> {:cont, {:ok, Map.merge(body, fragment)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fragment({:on, value}, _resource) when is_boolean(value) do
    {:ok, %{"on" => %{"on" => value}}}
  end

  defp fragment({:on, value}, _resource) do
    raise ArgumentError, "on: expects a boolean, got: #{inspect(value)}"
  end

  defp fragment({:brightness, value}, resource) when is_number(value) do
    if Map.has_key?(resource, "dimming") do
      {:ok, %{"dimming" => %{"brightness" => value / 1}}}
    else
      {:error, %Error{reason: :not_dimmable, rid: resource["id"]}}
    end
  end

  defp fragment({:brightness, value}, _resource) do
    raise ArgumentError, "brightness: expects a number, got: #{inspect(value)}"
  end

  defp fragment({:transition, value}, _resource) when is_integer(value) and value >= 0 do
    {:ok, %{"dynamics" => %{"duration" => value}}}
  end

  defp fragment({:transition, value}, _resource) do
    raise ArgumentError,
          "transition: expects a non-negative integer of milliseconds, got: #{inspect(value)}"
  end

  defp fragment({:color, value}, resource) do
    Color.payload(value, resource)
  end

  defp fragment({:kelvin, value}, resource) when is_integer(value) and value > 0 do
    case Color.mirek_for(value, resource) do
      {:ok, mirek} -> {:ok, %{"color_temperature" => %{"mirek" => mirek}}}
      {:error, _reason} = error -> error
    end
  end

  defp fragment({:kelvin, value}, _resource) do
    raise ArgumentError, "kelvin: expects a positive integer, got: #{inspect(value)}"
  end

  defp validate_options!(options) do
    case Keyword.keys(options) -- @known_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) #{inspect(unknown)}; accepted: #{inspect(@known_options)}"
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/body_test.exs`
Expected: PASS, 15 tests.

Two are likely to need adjusting to what layer 1 actually does, and adjusting the *test* is correct in both cases — this module must not second-guess `Hue.Color`:
- "color on a light with no color key is `:not_color_capable`" depends on Step 1's finding.
- "kelvin translates to mirek" asserts `370`, which is `round(1_000_000 / 2700)` clamped into 153–500. If `Hue.Color.kelvin_to_mirek/1` rounds differently, take its answer.

- [ ] **Step 6: Verify the raise/return split is genuinely tested**

Change the `brightness` clause so a bad value returns `{:error, %Error{reason: :unknown}}` instead of raising:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/body_test.exs`
Expected: FAIL on "a non-numeric brightness raises rather than returning an error". Restore.

Then change `:not_dimmable` to raise instead of returning:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/body_test.exs`
Expected: FAIL on "brightness on a light with no dimming key is :not_dimmable". Restore and confirm PASS.

- [ ] **Step 7: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge/body.ex test/hue/bridge/body_test.exs
git commit -m "Check capabilities from the cache before a request can leave"
```

---

### Task 11: `Hue.Bridge.Writes` — the coalescing, rate-paced queue

This is why writes go through the process at all. Reads bypass it because nothing about a read needs serialising; writes cannot, because coalescing and Hue's rate limits are both statements about *all* writes together, and there is nowhere else to make them.

Twenty slider drags on one light must collapse to one request carrying the last value. Pacing is per target type — roughly 10/s for lights, 1/s for grouped_lights, per Hue's guidance — so one request leaves per interval per type, not per pending item.

Coalescing merges rather than replaces. Two enqueues of `on: true` then `brightness: 40` are one request carrying both; two enqueues of `brightness: 40` then `brightness: 60` are one request carrying 60. Deep-merging gives both behaviours from one rule.

Pure and process-free, so every timing question is answered by passing `now` in rather than by sleeping in a test.

**Files:**
- Create: `lib/hue/bridge/writes.ex`
- Test: `test/hue/bridge/writes_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge/writes_test.exs`:

```elixir
defmodule Hue.Bridge.WritesTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Writes

  defp light_key(rid), do: {:light, rid}

  test "a queued write is taken back out" do
    {writes, _collapsed} =
      Writes.new() |> Writes.enqueue(light_key("light-1"), %{"on" => %{"on" => true}})

    assert {:ok, {:light, "light-1"}, %{"on" => %{"on" => true}}, _writes} =
             Writes.take(writes, :light, 0)
  end

  test "an empty queue has nothing to take" do
    assert :empty = Writes.take(Writes.new(), :light, 0)
  end

  test "two writes to one target collapse into one request" do
    {writes, 0} =
      Writes.new() |> Writes.enqueue(light_key("light-1"), %{"dimming" => %{"brightness" => 40.0}})

    {writes, 1} =
      Writes.enqueue(writes, light_key("light-1"), %{"dimming" => %{"brightness" => 60.0}})

    assert {:ok, _key, %{"dimming" => %{"brightness" => 60.0}}, writes} =
             Writes.take(writes, :light, 0)

    assert :empty = Writes.take(writes, :light, 0)
  end

  test "collapsing merges different keys rather than discarding them" do
    {writes, 0} = Writes.new() |> Writes.enqueue(light_key("light-1"), %{"on" => %{"on" => true}})

    {writes, 1} =
      Writes.enqueue(writes, light_key("light-1"), %{"dimming" => %{"brightness" => 40.0}})

    assert {:ok, _key, body, _writes} = Writes.take(writes, :light, 0)
    assert body == %{"on" => %{"on" => true}, "dimming" => %{"brightness" => 40.0}}
  end

  test "the collapsed count reports how many writes were absorbed" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
    {writes, 1} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => false}})
    {_writes, 2} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
  end

  test "the collapsed count resets once the write is taken" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
    {writes, 1} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => false}})

    {:ok, _key, _body, writes} = Writes.take(writes, :light, 0)
    {_writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
  end

  test "writes to different targets do not collapse into each other" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
    {writes, 0} = Writes.enqueue(writes, light_key("light-2"), %{"on" => %{"on" => false}})

    {:ok, {:light, "light-1"}, _one, writes} = Writes.take(writes, :light, 0)
    {:ok, {:light, "light-2"}, _two, writes} = Writes.take(writes, :light, 100)
    assert :empty = Writes.take(writes, :light, 200)
  end

  test "targets are taken in the order they were first queued" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("a"), %{"on" => %{"on" => true}})
    {writes, 0} = Writes.enqueue(writes, light_key("b"), %{"on" => %{"on" => true}})
    # Re-queueing a already in the queue must not move it to the back.
    {writes, 1} = Writes.enqueue(writes, light_key("a"), %{"on" => %{"on" => false}})

    {:ok, {:light, "a"}, _, writes} = Writes.take(writes, :light, 0)
    {:ok, {:light, "b"}, _, _writes} = Writes.take(writes, :light, 100)
  end

  test "a type with nothing pending is never due" do
    assert Writes.due_in(Writes.new(), :light, 0) == :never
  end

  test "a type with something pending and no recent send is due now" do
    {writes, 0} = Writes.new() |> Writes.enqueue(light_key("light-1"), %{"on" => %{"on" => true}})

    assert Writes.due_in(writes, :light, 0) == 0
  end

  test "a light waits out the light interval after a send" do
    {writes, 0} = Writes.new() |> Writes.enqueue(light_key("a"), %{"on" => %{"on" => true}})
    {:ok, _key, _body, writes} = Writes.take(writes, :light, 1_000)
    {writes, 0} = Writes.enqueue(writes, light_key("b"), %{"on" => %{"on" => true}})

    assert Writes.due_in(writes, :light, 1_000) == 100
    assert Writes.due_in(writes, :light, 1_050) == 50
    assert Writes.due_in(writes, :light, 1_100) == 0
    assert Writes.due_in(writes, :light, 5_000) == 0
  end

  test "a grouped_light is paced ten times slower than a light" do
    {writes, 0} = Writes.new() |> Writes.enqueue({:grouped_light, "gl-1"}, %{"on" => %{"on" => true}})
    {:ok, _key, _body, writes} = Writes.take(writes, :grouped_light, 1_000)
    {writes, 0} = Writes.enqueue(writes, {:grouped_light, "gl-2"}, %{"on" => %{"on" => true}})

    assert Writes.due_in(writes, :grouped_light, 1_000) == 1_000
    assert Writes.due_in(writes, :grouped_light, 1_999) == 1
  end

  test "pacing is per type, so a light is not delayed by a grouped_light" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, {:grouped_light, "gl-1"}, %{"on" => %{"on" => true}})
    {:ok, _key, _body, writes} = Writes.take(writes, :grouped_light, 1_000)
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})

    assert Writes.due_in(writes, :light, 1_000) == 0
  end

  test "an unknown type falls back to the light interval" do
    {writes, 0} = Writes.new() |> Writes.enqueue({:scene, "scene-1"}, %{"recall" => %{}})
    {:ok, _key, _body, writes} = Writes.take(writes, :scene, 1_000)
    {writes, 0} = Writes.enqueue(writes, {:scene, "scene-2"}, %{"recall" => %{}})

    assert Writes.due_in(writes, :scene, 1_000) == 100
  end

  test "the pending types are reportable" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("a"), %{"on" => %{"on" => true}})
    {writes, 0} = Writes.enqueue(writes, {:grouped_light, "gl-1"}, %{"on" => %{"on" => true}})

    assert Enum.sort(Writes.pending_types(writes)) == [:grouped_light, :light]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/writes_test.exs`
Expected: FAIL — `module Hue.Bridge.Writes is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/hue/bridge/writes.ex`:

```elixir
defmodule Hue.Bridge.Writes do
  @moduledoc """
  The pending-write queue: coalescing, and Hue's per-type rate limits.

  This is the reason writes go through `Hue.Bridge`'s process while reads
  bypass it. Nothing about a read needs serialising. Coalescing and pacing are
  both statements about *all* writes together, and there is nowhere else in the
  design to make them.

  ## Coalescing merges, it does not replace

  Twenty slider drags on one light collapse to one request carrying the last
  value. Two writes setting different things — `on: true`, then
  `brightness: 40` — collapse to one request carrying both. Deep-merging the
  new body over the pending one gives both behaviours from a single rule:
  last-wins per leaf, union across keys.

  ## Pacing is per type

  Roughly 10 writes/second for lights and 1/second for grouped_lights, per
  Hue's own guidance. One request leaves per interval **per type**, not per
  pending item: three lights queued at once go out over 300 ms, and a queued
  grouped_light does not delay them.

  ## No clock

  Every function that cares about time takes `now` as a monotonic millisecond
  argument. The queue holds no timers and reads no clock, so its behaviour
  under a 1-second grouped_light interval is tested by passing `1_000`, not by
  sleeping for a second.
  """

  alias Hue.Bridge.Merge

  @light_interval 100
  @grouped_light_interval 1_000

  @intervals %{light: @light_interval, grouped_light: @grouped_light_interval}

  @type key :: {atom(), String.t()}

  @type t :: %__MODULE__{
          pending: %{key() => map()},
          order: [key()],
          collapsed: %{key() => non_neg_integer()},
          last_sent_at: %{atom() => integer()}
        }

  defstruct pending: %{}, order: [], collapsed: %{}, last_sent_at: %{}

  @doc "An empty queue."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Queues a write, merging it into whatever is already pending for that target.

  Returns the queue and the number of writes that have now been absorbed into
  this one pending body — `0` the first time, `1` the second, and so on. The
  server reports that as `[:hue, :write, :coalesced]`.
  """
  @spec enqueue(t(), key(), map()) :: {t(), non_neg_integer()}
  def enqueue(%__MODULE__{} = writes, key, body) when is_map(body) do
    case Map.fetch(writes.pending, key) do
      {:ok, pending} ->
        collapsed = Map.get(writes.collapsed, key, 0) + 1

        {%{
           writes
           | pending: Map.put(writes.pending, key, Merge.merge(pending, body)),
             collapsed: Map.put(writes.collapsed, key, collapsed)
         }, collapsed}

      :error ->
        {%{
           writes
           | pending: Map.put(writes.pending, key, body),
             order: writes.order ++ [key]
         }, 0}
    end
  end

  @doc """
  Takes the oldest pending write of `type` and records the send at `now`.

  Returns `:empty` when nothing of that type is pending. Does not check whether
  the write is due — that is `due_in/3`'s question, and the server asks it
  before calling this.
  """
  @spec take(t(), atom(), integer()) :: {:ok, key(), map(), t()} | :empty
  def take(%__MODULE__{} = writes, type, now) do
    case Enum.find(writes.order, fn {key_type, _rid} -> key_type == type end) do
      nil ->
        :empty

      key ->
        {body, pending} = Map.pop(writes.pending, key)

        {:ok, key, body,
         %{
           writes
           | pending: pending,
             order: List.delete(writes.order, key),
             collapsed: Map.delete(writes.collapsed, key),
             last_sent_at: Map.put(writes.last_sent_at, type, now)
         }}
    end
  end

  @doc """
  Milliseconds until a write of `type` may be sent, `0` if now, or `:never` if
  nothing of that type is pending.
  """
  @spec due_in(t(), atom(), integer()) :: non_neg_integer() | :never
  def due_in(%__MODULE__{} = writes, type, now) do
    if Enum.any?(writes.order, fn {key_type, _rid} -> key_type == type end) do
      case Map.fetch(writes.last_sent_at, type) do
        :error -> 0
        {:ok, sent_at} -> max(0, interval(type) - (now - sent_at))
      end
    else
      :never
    end
  end

  @doc "Every type with something pending."
  @spec pending_types(t()) :: [atom()]
  def pending_types(%__MODULE__{} = writes) do
    writes.order |> Enum.map(fn {type, _rid} -> type end) |> Enum.uniq()
  end

  # Anything Hue does not document a slower limit for is paced as a light,
  # which is the conservative direction: too slow costs latency, too fast costs
  # 429s and dropped commands.
  defp interval(type), do: Map.get(@intervals, type, @light_interval)
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/writes_test.exs`
Expected: PASS, 15 tests.

- [ ] **Step 5: Verify coalescing is merge, not replace**

Change `Merge.merge(pending, body)` to just `body`:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/writes_test.exs`
Expected: FAIL on "collapsing merges different keys rather than discarding them" — the `on` is gone. Restore.

Then change `order: writes.order ++ [key]` to `order: [key | writes.order]`:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge/writes_test.exs`
Expected: FAIL on "targets are taken in the order they were first queued". Restore and confirm PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge/writes.ex test/hue/bridge/writes_test.exs
git commit -m "Coalesce pending writes and pace them per target type"
```

---

### Task 12: The write path — queued in the server, sent from a task

The queue from Task 11 becomes real. Three things matter and each is easy to get wrong:

**The PUT does not run in the server.** A write that blocked the GenServer would stall event ingestion for the length of a network round trip — the cache would go stale precisely while something was changing. `Task.Supervisor.async_nolink` sends it, and `async_nolink` specifically so a failed write cannot take the bridge down with it.

**`set` returns `:ok` before the bridge has answered.** Two reasons, and only the second is about performance. The PUT response is not the truth: the state change arrives as an event a moment later, and blocking on the response would pretend otherwise. And nothing can be coalesced if every caller is already waiting on their own request.

**A failed write is not silent.** It has no caller left to return to, so it surfaces as telemetry and as an `error` event to subscribers.

**Files:**
- Modify: `lib/hue/bridge/server.ex`
- Modify: `lib/hue/bridge.ex` (public `write/4`)
- Test: `test/hue/bridge_writes_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge_writes_test.exs`:

```elixir
defmodule Hue.BridgeWritesTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge

  setup context do
    name =
      Module.concat(Hue.BridgeWritesTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

    resources = [
      %{
        "type" => "light",
        "id" => "light-1",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0}
      },
      %{
        "type" => "light",
        "id" => "light-2",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0}
      },
      %{"type" => "grouped_light", "id" => "gl-1", "on" => %{"on" => false}}
    ]

    client = Hue.Stub.client(resources: resources)
    start_supervised!({Bridge, name: name, client: client}, id: name)

    assert_receive {:hue_stub, :eventstream, _stream}
    await_live(name)

    {:ok, name: name}
  end

  defp await_live(name, remaining \\ 200) do
    cond do
      Bridge.status(name) == :live -> :ok
      remaining == 0 -> flunk("bridge never reached :live")
      true -> Process.sleep(10) && await_live(name, remaining - 1)
    end
  end

  test "a write reaches the bridge", %{name: name} do
    assert :ok = Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", body}, 1_000
    assert body == %{"on" => %{"on" => true}}
  end

  test "a write returns before the bridge has answered", %{name: name} do
    # If write/4 blocked on the response, this would not be measurable as fast.
    {microseconds, :ok} =
      :timer.tc(fn -> Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}}) end)

    assert microseconds < 50_000
    assert_receive {:hue_stub, :put, _path, _body}, 1_000
  end

  test "twenty writes to one light collapse to far fewer requests", %{name: name} do
    for brightness <- 1..20 do
      Bridge.write(name, :light, "light-1", %{"dimming" => %{"brightness" => brightness / 1}})
    end

    # The last value must arrive, and the count must be nothing like twenty.
    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", _body}, 1_000
    Process.sleep(150)

    puts = drain_puts()
    assert length(puts) <= 2
    assert List.last(puts)["dimming"]["brightness"] == 20.0
  end

  test "coalescing is reported through telemetry", %{name: name} do
    handler = {__MODULE__, name}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :write, :coalesced],
      fn _e, measurements, metadata, _c -> send(test, {:coalesced, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})
    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => false}})

    assert_receive {:coalesced, %{collapsed_count: 1}, %{bridge: ^name, type: :light}}, 1_000
  end

  test "writes to two different lights are both sent", %{name: name} do
    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})
    Bridge.write(name, :light, "light-2", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", _}, 1_000
    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-2", _}, 1_000
  end

  test "a grouped_light write goes to the grouped_light path", %{name: name} do
    Bridge.write(name, :grouped_light, "gl-1", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/grouped_light/gl-1", _}, 1_000
  end

  test "the server keeps serving reads while a write is in flight", %{name: name} do
    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})

    assert {:ok, %{"id" => "light-1"}} = Bridge.fetch(name, :light, "light-1")
    assert Bridge.status(name) == :live
  end

  test "a write to a bridge that is not running is an error" do
    assert {:error, %Hue.Error{reason: :not_started}} =
             Bridge.write(Hue.BridgeWritesTest.Nowhere, :light, "light-1", %{})
  end

  defp drain_puts(acc \\ []) do
    receive do
      {:hue_stub, :put, _path, body} -> drain_puts([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_writes_test.exs`
Expected: FAIL — `function Hue.Bridge.write/4 is undefined or private`.

- [ ] **Step 3: Add the write path to the server**

In `lib/hue/bridge/server.ex`:

Add `alias Hue.Bridge.Writes` and extend the struct with `writes: nil` and `flush_armed: MapSet.new()` and `write_tasks: %{}`. Initialise `writes: Writes.new()` in `init/1`.

Add the cast and the flush loop:

```elixir
  @impl GenServer
  def handle_cast({:write, type, rid, body}, state) do
    {writes, collapsed} = Writes.enqueue(state.writes, {type, rid}, body)

    if collapsed > 0 do
      :telemetry.execute(
        [:hue, :write, :coalesced],
        %{collapsed_count: collapsed},
        %{bridge: state.name, type: type, rid: rid}
      )
    end

    {:noreply, arm_flush(%{state | writes: writes}, type)}
  end

  def handle_info({:flush, type}, state) do
    state = %{state | flush_armed: MapSet.delete(state.flush_armed, type)}

    case Writes.take(state.writes, type, now()) do
      :empty ->
        {:noreply, state}

      {:ok, {^type, rid}, body, writes} ->
        state = %{state | writes: writes}
        {:noreply, state |> send_write(type, rid, body) |> arm_flush(type)}
    end
  end
```

```elixir
  defp arm_flush(state, type) do
    cond do
      MapSet.member?(state.flush_armed, type) ->
        state

      true ->
        case Writes.due_in(state.writes, type, now()) do
          :never ->
            state

          delay ->
            Process.send_after(self(), {:flush, type}, delay)
            %{state | flush_armed: MapSet.put(state.flush_armed, type)}
        end
    end
  end

  defp send_write(state, type, rid, body) do
    client = state.client

    task =
      Task.Supervisor.async_nolink(Bridge.tasks(state.name), fn ->
        Resource.update(client, type, rid, body)
      end)

    %{state | write_tasks: Map.put(state.write_tasks, task.ref, {type, rid})}
  end

  defp now, do: System.monotonic_time(:millisecond)
```

Then extend the task-result handling. The existing `{ref, result}` and `{:DOWN, ...}` clauses match on the *stream* task, so add write-task clauses **before** the catch-all:

```elixir
  def handle_info({ref, result}, %{write_tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {target, tasks} = Map.pop(tasks, ref)

    case result do
      :ok -> :ok
      {:error, error} -> report_write_failure(state, target, error)
      _other -> :ok
    end

    {:noreply, %{state | write_tasks: tasks}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{write_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {target, tasks} = Map.pop(tasks, ref)
    report_write_failure(state, target, %Error{reason: exit_reason(reason)})
    {:noreply, %{state | write_tasks: tasks}}
  end
```

and the reporter, which is the only place a failed write can go — it has no caller left:

```elixir
  # A write has no caller waiting by the time it fails, so the failure has
  # exactly two ways out: telemetry, and an error event to whoever subscribed.
  # Dropping it silently would make a bridge that rejects every write look
  # identical to one that accepts them.
  defp report_write_failure(state, {type, rid}, %Error{} = error) do
    :telemetry.execute(
      [:hue, :write, :failed],
      %{},
      %{bridge: state.name, type: type, rid: rid, reason: error.reason}
    )

    event = %Event{type: :error, resource_type: type, rid: rid, data: error}
    dispatch(state, event, Cache.name_of(state.table, type, rid))
  end
```

- [ ] **Step 4: Add the public `write/4`**

In `lib/hue/bridge.ex`:

```elixir
  @doc """
  Queues a write to one resource.

  Returns `:ok` as soon as the write is queued, **before** the bridge has been
  asked. That is deliberate on two counts. The PUT's response is not the truth —
  the state change arrives as an event a moment later, and blocking on the
  response would pretend otherwise. And nothing can be coalesced if every caller
  is already waiting on their own request.

  Failures surface as `[:hue, :write, :failed]` telemetry and as an `error`
  event to subscribers, because by then there is no caller to return them to.
  Local errors — a capability the light does not have, a malformed option — are
  caught before anything is queued, by `Hue.Light.set/3` and friends.

  Most callers want `Hue.Light.set/3`, `Hue.Room.set/3`, or `Hue.Zone.set/3`.
  This is the unwrapped form, for a resource type those do not cover.
  """
  @spec write(atom(), atom(), String.t(), map()) :: :ok | {:error, Error.t()}
  def write(name \\ @default_name, type, rid, body) when is_map(body) do
    GenServer.cast(server(name), {:write, type, rid, body})
  catch
    :exit, {:noproc, _call} -> {:error, %Error{reason: :not_started}}
  end
```

Note `GenServer.cast/2` to a missing *named* process does not raise — it returns `:ok` and drops the message. So guard explicitly rather than relying on the `catch`:

```elixir
  def write(name \\ @default_name, type, rid, body) when is_map(body) do
    case Process.whereis(server(name)) do
      nil -> {:error, %Error{reason: :not_started}}
      pid -> GenServer.cast(pid, {:write, type, rid, body})
    end
  end
```

Use the second form; delete the first. The `catch` version is the kind of thing that looks defensive and tests green while never firing.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_writes_test.exs`
Expected: PASS, 8 tests.

- [ ] **Step 6: Verify the PUT is genuinely off the server's stack**

Replace `send_write/4`'s task with a direct `Resource.update(client, type, rid, body)` call in the server, then add this test and run it:

```elixir
  test "a slow write does not block reads or event ingestion", %{name: name} do
    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})

    # The stub answers immediately, so this asserts the shape rather than the
    # latency: the call must return while the server is free to answer a call.
    assert Bridge.status(name) == :live
    assert {:ok, _} = Bridge.fetch(name, :light, "light-1")
  end
```

Expected: this passes either way, because the stub is fast — which means **the test does not protect the property**. The honest check is structural, so verify it by reading instead: `send_write/4` must call `Task.Supervisor.async_nolink`, and no `Resource.update/5` call may appear in a `handle_call`, `handle_cast`, or `handle_info` body. Note it in the code comment rather than pretending a test covers it, and restore the task.

- [ ] **Step 7: Verify coalescing actually coalesces**

Change `arm_flush/2` to always `Process.send_after(self(), {:flush, type}, 0)` regardless of `due_in/3`:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_writes_test.exs`
Expected: FAIL on "twenty writes to one light collapse to far fewer requests" — closer to twenty PUTs arrive. Restore and confirm PASS.

- [ ] **Step 8: Run the whole suite**

Run: `cd ~/src/hue-ex && mix test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge.ex lib/hue/bridge/server.ex test/hue/bridge_writes_test.exs
git commit -m "Send writes from a task so a round trip never stalls the cache"
```

---

### Task 13: `Hue.Light` — the API people actually call

Everything so far assembles into three functions. `Hue.Light.set(bridge, "Iris", color: "#ff8800", brightness: 40)` resolves the name through the device graph, checks the capabilities against the cached light, builds the body, and queues the write — none of which touches the network, and all of which would be several round trips done per call over layer 1.

**Files:**
- Create: `lib/hue/light.ex`
- Test: `test/hue/light_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/light_test.exs`:

```elixir
defmodule Hue.LightTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Light

  setup context do
    name = Module.concat(Hue.LightTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

    resources = [
      %{
        "type" => "light",
        "id" => "light-1",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0, "min_dim_level" => 0.2},
        "color" => %{
          "gamut_type" => "C",
          "gamut" => %{
            "red" => %{"x" => 0.6915, "y" => 0.3083},
            "green" => %{"x" => 0.1700, "y" => 0.7000},
            "blue" => %{"x" => 0.1532, "y" => 0.0475}
          }
        }
      },
      %{"type" => "light", "id" => "light-2", "on" => %{"on" => false}},
      %{
        "type" => "device",
        "id" => "device-1",
        "metadata" => %{"name" => "Iris"},
        "services" => [%{"rid" => "light-1", "rtype" => "light"}]
      },
      %{
        "type" => "device",
        "id" => "device-2",
        "metadata" => %{"name" => "Hallway"},
        "services" => [%{"rid" => "light-2", "rtype" => "light"}]
      }
    ]

    start_supervised!({Bridge, name: name, client: Hue.Stub.client(resources: resources)}, id: name)
    assert_receive {:hue_stub, :eventstream, _stream}
    await_live(name)

    {:ok, name: name}
  end

  defp await_live(name, remaining \\ 200) do
    cond do
      Bridge.status(name) == :live -> :ok
      remaining == 0 -> flunk("bridge never reached :live")
      true -> Process.sleep(10) && await_live(name, remaining - 1)
    end
  end

  test "get/2 finds a light by the name of the device that owns it", %{name: name} do
    assert {:ok, %{"id" => "light-1"}} = Light.get(name, "Iris")
  end

  test "get/2 finds a light by rid", %{name: name} do
    assert {:ok, %{"id" => "light-1"}} = Light.get(name, "light-1")
  end

  test "get/2 on an unknown target is :not_found", %{name: name} do
    assert {:error, %Error{reason: :not_found}} = Light.get(name, "Nowhere")
  end

  test "list/1 returns every light", %{name: name} do
    assert {:ok, lights} = Light.list(name)
    assert length(lights) == 2
  end

  test "set/3 writes to the resolved light", %{name: name} do
    assert :ok = Light.set(name, "Iris", on: true)

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", body}, 1_000
    assert body == %{"on" => %{"on" => true}}
  end

  test "set/3 combines several options into one body", %{name: name} do
    assert :ok = Light.set(name, "Iris", on: true, brightness: 40, transition: 400)

    assert_receive {:hue_stub, :put, _path, body}, 1_000

    assert body == %{
             "on" => %{"on" => true},
             "dimming" => %{"brightness" => 40.0},
             "dynamics" => %{"duration" => 400}
           }
  end

  test "set/3 converts a colour through the light's own gamut", %{name: name} do
    assert :ok = Light.set(name, "Iris", color: "#ff8800")

    assert_receive {:hue_stub, :put, _path, %{"color" => %{"xy" => %{"x" => _, "y" => _}}}}, 1_000
  end

  test "brightness on a light with no dimming is refused before any request", %{name: name} do
    assert {:error, %Error{reason: :not_dimmable, rid: "light-2"}} =
             Light.set(name, "Hallway", brightness: 40)

    refute_receive {:hue_stub, :put, _, _}, 200
  end

  test "colour on a light with no colour is refused before any request", %{name: name} do
    assert {:error, %Error{reason: :not_color_capable}} = Light.set(name, "Hallway", color: "#ff8800")

    refute_receive {:hue_stub, :put, _, _}, 200
  end

  test "set/3 on an unknown target is :not_found and sends nothing", %{name: name} do
    assert {:error, %Error{reason: :not_found}} = Light.set(name, "Nowhere", on: true)

    refute_receive {:hue_stub, :put, _, _}, 200
  end

  test "a malformed option raises rather than returning an error", %{name: name} do
    assert_raise ArgumentError, ~r/brightness/, fn -> Light.set(name, "Iris", brightness: "loud") end
  end

  test "set/3 against an unsynced bridge is :not_synced", %{name: _name} do
    unsynced = Hue.LightTest.Unsynced

    start_supervised!(
      {Bridge, name: unsynced, client: Hue.Stub.client(fetch_status: 503), retry_after: 60_000},
      id: unsynced
    )

    assert {:error, %Error{reason: :not_synced}} = Light.set(unsynced, "Iris", on: true)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/light_test.exs`
Expected: FAIL — `module Hue.Light is not available`.

- [ ] **Step 3: Write the implementation**

Create `lib/hue/light.ex`:

```elixir
defmodule Hue.Light do
  @moduledoc """
  Lights, addressed by the name you gave them in the Hue app.

      {:ok, light} = Hue.Light.get(bridge, "Desk Lamp")
      :ok = Hue.Light.set(bridge, "Iris", color: "#ff8800", brightness: 40)
      :ok = Hue.Light.set(bridge, "Overhead", kelvin: 2700, transition: 400)

  Targets are names or rids, interchangeably. Names are what you have in mind;
  rids survive someone renaming the light in the Hue app.

  ## Everything before the request is local

  Resolving "Iris" to a rid, checking that Iris can do colour, and building the
  body all happen against `Hue.Bridge`'s cache. Over layer 1 the same call is
  several round trips — list the devices, find the one named Iris, walk its
  services, read the light to learn its gamut, then write. Here it is a handful
  of `:ets.lookup` calls in your own process, and the only thing that reaches
  the network is the write itself.

  ## Options

    * `:on` — boolean
    * `:brightness` — 0–100; the light must report a `dimming` key
    * `:color` — a hex string like `"#ff8800"`, or `{r, g, b}`; converted through
      this light's own gamut
    * `:kelvin` — a colour temperature, clamped to this light's own mirek schema
    * `:transition` — milliseconds for the light to take getting there

  ## Errors, and which ones raise

  A capability the light does not have returns `{:error, %Hue.Error{}}` — the
  bulb in the socket is a fact about the house, not a bug in the code. A
  malformed option raises, because that is a bug in the code and there is
  nothing to handle at runtime. See `Hue.Bridge.Body`.
  """

  alias Hue.Bridge
  alias Hue.Bridge.Body
  alias Hue.Error

  @doc "Fetches one light by name or rid."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, target) when is_binary(target), do: Bridge.resolve(bridge, :light, target)

  @doc "Every light the bridge knows about."
  @spec list(atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge), do: Bridge.list(bridge, :light)

  @doc """
  Queues a change to one light. See the moduledoc for options.

  Returns `:ok` once queued, not once applied — see `Hue.Bridge.write/4`.
  """
  @spec set(atom(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set(bridge, target, options) when is_binary(target) and is_list(options) do
    with {:ok, light} <- get(bridge, target),
         {:ok, body} <- Body.build(options, light) do
      Bridge.write(bridge, :light, light["id"], body)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/light_test.exs`
Expected: PASS, 12 tests.

- [ ] **Step 5: Verify the capability checks really do prevent the request**

The three `refute_receive` assertions are the ones that prove "caught before the request leaves". Temporarily reorder `set/3` so it writes first and checks after:

```elixir
    with {:ok, light} <- get(bridge, target) do
      Bridge.write(bridge, :light, light["id"], %{})
      Body.build(options, light)
    end
```

Run: `cd ~/src/hue-ex && mix test test/hue/light_test.exs`
Expected: FAIL on all three "refused before any request" / "sends nothing" tests. Restore and confirm PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/light.ex test/hue/light_test.exs
git commit -m "Address lights by name, with capabilities checked before the write"
```

---

### Task 14: `Hue.Room`, `Hue.Zone`, and `Hue.Scene`

Rooms and zones are the same operation against a different resource type: resolve the group, walk to its `grouped_light`, write there. That shared body lives in `Hue.Group`; `Hue.Room` and `Hue.Zone` are the public names, because "call `Hue.Group.set(bridge, :room, …)`" is a worse API than two modules of six lines.

Scenes are not a group at all — recall is a write to the scene itself, and it takes no brightness or colour.

**Files:**
- Create: `lib/hue/group.ex`
- Create: `lib/hue/room.ex`
- Create: `lib/hue/zone.ex`
- Create: `lib/hue/scene.ex`
- Test: `test/hue/group_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/group_test.exs`:

```elixir
defmodule Hue.GroupTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Room
  alias Hue.Scene
  alias Hue.Zone

  setup context do
    name = Module.concat(Hue.GroupTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

    resources = [
      %{
        "type" => "room",
        "id" => "room-1",
        "metadata" => %{"name" => "Living Room"},
        "services" => [%{"rid" => "gl-1", "rtype" => "grouped_light"}]
      },
      %{"type" => "room", "id" => "room-2", "metadata" => %{"name" => "Spare Room"}, "services" => []},
      %{
        "type" => "zone",
        "id" => "zone-1",
        "metadata" => %{"name" => "Downstairs"},
        "services" => [%{"rid" => "gl-2", "rtype" => "grouped_light"}]
      },
      %{
        "type" => "grouped_light",
        "id" => "gl-1",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 50.0}
      },
      %{"type" => "grouped_light", "id" => "gl-2", "on" => %{"on" => false}},
      %{"type" => "scene", "id" => "scene-1", "metadata" => %{"name" => "Relax"}}
    ]

    start_supervised!({Bridge, name: name, client: Hue.Stub.client(resources: resources)}, id: name)
    assert_receive {:hue_stub, :eventstream, _stream}
    await_live(name)

    {:ok, name: name}
  end

  defp await_live(name, remaining \\ 200) do
    cond do
      Bridge.status(name) == :live -> :ok
      remaining == 0 -> flunk("bridge never reached :live")
      true -> Process.sleep(10) && await_live(name, remaining - 1)
    end
  end

  test "a room write goes to the room's grouped_light, not the room", %{name: name} do
    assert :ok = Room.set(name, "Living Room", on: false)

    assert_receive {:hue_stub, :put, "/clip/v2/resource/grouped_light/gl-1", body}, 1_000
    assert body == %{"on" => %{"on" => false}}
  end

  test "a zone write goes to the zone's grouped_light", %{name: name} do
    assert :ok = Zone.set(name, "Downstairs", on: true)

    assert_receive {:hue_stub, :put, "/clip/v2/resource/grouped_light/gl-2", _body}, 1_000
  end

  test "a room can be dimmed when its grouped_light reports dimming", %{name: name} do
    assert :ok = Room.set(name, "Living Room", brightness: 25)

    assert_receive {:hue_stub, :put, _path, %{"dimming" => %{"brightness" => 25.0}}}, 1_000
  end

  test "an empty room is :no_grouped_light and sends nothing", %{name: name} do
    assert {:error, %Error{reason: :no_grouped_light, rid: "room-2"}} =
             Room.set(name, "Spare Room", on: true)

    refute_receive {:hue_stub, :put, _, _}, 200
  end

  test "dimming a group whose grouped_light has no dimming is :not_dimmable", %{name: name} do
    assert {:error, %Error{reason: :not_dimmable, rid: "gl-2"}} =
             Zone.set(name, "Downstairs", brightness: 25)

    refute_receive {:hue_stub, :put, _, _}, 200
  end

  test "a room that does not exist is :not_found", %{name: name} do
    assert {:error, %Error{reason: :not_found}} = Room.set(name, "Nowhere", on: true)
  end

  test "get/2 returns the room itself, not its grouped_light", %{name: name} do
    assert {:ok, %{"type" => "room", "id" => "room-1"}} = Room.get(name, "Living Room")
  end

  test "list/1 returns rooms and zones separately", %{name: name} do
    assert {:ok, rooms} = Room.list(name)
    assert length(rooms) == 2

    assert {:ok, zones} = Zone.list(name)
    assert length(zones) == 1
  end

  test "recalling a scene writes to the scene", %{name: name} do
    assert :ok = Scene.recall(name, "Relax")

    assert_receive {:hue_stub, :put, "/clip/v2/resource/scene/scene-1", body}, 1_000
    assert body == %{"recall" => %{"action" => "active"}}
  end

  test "a scene recall can carry a duration", %{name: name} do
    assert :ok = Scene.recall(name, "Relax", duration: 2_000)

    assert_receive {:hue_stub, :put, _path, body}, 1_000
    assert body == %{"recall" => %{"action" => "active", "duration" => 2_000}}
  end

  test "recalling a scene that does not exist is :not_found", %{name: name} do
    assert {:error, %Error{reason: :not_found}} = Scene.recall(name, "Nowhere")
  end

  test "a negative scene duration raises", %{name: name} do
    assert_raise ArgumentError, ~r/duration/, fn -> Scene.recall(name, "Relax", duration: -1) end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/group_test.exs`
Expected: FAIL — `module Hue.Room is not available`.

- [ ] **Step 3: Write `Hue.Group`**

Create `lib/hue/group.ex`:

```elixir
defmodule Hue.Group do
  @moduledoc false
  # Shared implementation for Hue.Room and Hue.Zone. Both are the same
  # operation against a different resource type: resolve the group, walk to the
  # grouped_light service that acts for it, write there.
  #
  # Not public, because "Hue.Group.set(bridge, :room, target, options)" is a
  # worse API than two six-line modules that say which one you mean.

  alias Hue.Bridge
  alias Hue.Bridge.Body
  alias Hue.Bridge.Graph
  alias Hue.Error

  @spec get(atom(), :room | :zone, String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, type, target), do: Bridge.resolve(bridge, type, target)

  @spec list(atom(), :room | :zone) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge, type), do: Bridge.list(bridge, type)

  @spec set(atom(), :room | :zone, String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set(bridge, type, target, options) do
    with {:ok, grouped} <- Graph.grouped_light(Bridge.table(bridge), type, target),
         {:ok, body} <- Body.build(options, grouped) do
      Bridge.write(bridge, :grouped_light, grouped["id"], body)
    end
  end
end
```

- [ ] **Step 4: Write `Hue.Room` and `Hue.Zone`**

Create `lib/hue/room.ex`:

```elixir
defmodule Hue.Room do
  @moduledoc """
  Rooms, addressed by name.

      :ok = Hue.Room.set(bridge, "Living Room", on: false)

  ## A room is not what accepts the write

  A room has no `on` state of its own. What responds is the `grouped_light`
  service the room owns, and `set/3` walks there for you. `get/2` deliberately
  returns the *room* — that is what you asked for — so if you want the group's
  current brightness, read the `grouped_light` it points at.

  An empty room owns no `grouped_light` at all, and `set/3` returns
  `{:error, %Hue.Error{reason: :no_grouped_light}}` rather than inventing one.
  Two of the six rooms on the reference bridge are in exactly that state.

  Options are `Hue.Light`'s, checked against the group rather than a single
  bulb.
  """

  alias Hue.Error
  alias Hue.Group

  @doc "Fetches one room by name or rid."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, target), do: Group.get(bridge, :room, target)

  @doc "Every room the bridge knows about."
  @spec list(atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge), do: Group.list(bridge, :room)

  @doc "Queues a change to every light in a room. See `Hue.Light` for options."
  @spec set(atom(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set(bridge, target, options), do: Group.set(bridge, :room, target, options)
end
```

Create `lib/hue/zone.ex`, identical but for `:zone`:

```elixir
defmodule Hue.Zone do
  @moduledoc """
  Zones, addressed by name.

      :ok = Hue.Zone.set(bridge, "Downstairs", brightness: 30)

  A zone is a grouping that cuts across rooms — a light belongs to exactly one
  room but to any number of zones. Everything else is `Hue.Room`: the write goes
  to the zone's `grouped_light` service, and a zone owning none returns
  `{:error, %Hue.Error{reason: :no_grouped_light}}`.
  """

  alias Hue.Error
  alias Hue.Group

  @doc "Fetches one zone by name or rid."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, target), do: Group.get(bridge, :zone, target)

  @doc "Every zone the bridge knows about."
  @spec list(atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge), do: Group.list(bridge, :zone)

  @doc "Queues a change to every light in a zone. See `Hue.Light` for options."
  @spec set(atom(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set(bridge, target, options), do: Group.set(bridge, :zone, target, options)
end
```

- [ ] **Step 5: Write `Hue.Scene`**

Create `lib/hue/scene.ex`:

```elixir
defmodule Hue.Scene do
  @moduledoc """
  Scenes, addressed by name.

      :ok = Hue.Scene.recall(bridge, "Relax")
      :ok = Hue.Scene.recall(bridge, "Relax", duration: 2_000)

  A scene is not a group and takes none of `Hue.Light`'s options — its whole
  content is the state it puts its lights into. Recall is a write to the scene
  itself, and the only thing you get to say about it is how long the transition
  should take.
  """

  alias Hue.Bridge
  alias Hue.Error

  @doc "Fetches one scene by name or rid."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, target), do: Bridge.resolve(bridge, :scene, target)

  @doc "Every scene the bridge knows about."
  @spec list(atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge), do: Bridge.list(bridge, :scene)

  @doc """
  Activates a scene.

  `:duration` is milliseconds for the transition into the scene.
  """
  @spec recall(atom(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def recall(bridge, target, options \\ []) do
    recall = Enum.reduce(options, %{"action" => "active"}, &recall_option/2)

    with {:ok, scene} <- get(bridge, target) do
      Bridge.write(bridge, :scene, scene["id"], %{"recall" => recall})
    end
  end

  defp recall_option({:duration, value}, recall) when is_integer(value) and value >= 0 do
    Map.put(recall, "duration", value)
  end

  defp recall_option({:duration, value}, _recall) do
    raise ArgumentError,
          "duration: expects a non-negative integer of milliseconds, got: #{inspect(value)}"
  end

  defp recall_option({key, _value}, _recall) do
    raise ArgumentError, "unknown option #{inspect(key)}; recall accepts only :duration"
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/group_test.exs`
Expected: PASS, 12 tests.

Note the option validation in `recall/3` runs before `get/2`, so a bad duration raises even for a scene that does not exist. That is the right order — a caller bug should not be masked by a missing scene.

- [ ] **Step 7: Verify the group walk is not accidentally writing to the room**

Change `Group.set/4` to write to `type` and `target` directly instead of the grouped_light:

Run: `cd ~/src/hue-ex && mix test test/hue/group_test.exs`
Expected: FAIL on "a room write goes to the room's grouped_light, not the room" — the path is `/clip/v2/resource/room/room-1`. Restore and confirm PASS.

- [ ] **Step 8: Run the whole suite**

Run: `cd ~/src/hue-ex && mix test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/group.ex lib/hue/room.ex lib/hue/zone.ex lib/hue/scene.ex test/hue/group_test.exs
git commit -m "Add rooms, zones, and scenes over the shared group walk"
```

---

### Task 15: `await: true` — for callers that need confirmation

Writes are asynchronous because the PUT's response is not the truth. But some callers genuinely need to know the change landed — a test, a script that dims and then screenshots, an automation that sequences two rooms. `await: true` waits for the event that confirms it.

It waits for the **event**, not the response, because the event is the thing that is true.

Two honest limitations, both documented rather than engineered around: the wait happens in the calling process's mailbox, so it consumes the confirming event even if the caller was independently subscribed to that rid; and it unsubscribes afterwards, which clears a pre-existing rid subscription. Both are avoidable by not using `await: true` from a process that subscribes by rid, which is the normal case.

**Files:**
- Modify: `lib/hue/bridge.ex` (`await_write/5`)
- Modify: `lib/hue/light.ex`, `lib/hue/group.ex`, `lib/hue/scene.ex` (accept `:await`)
- Test: `test/hue/bridge_await_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/hue/bridge_await_test.exs`:

```elixir
defmodule Hue.BridgeAwaitTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Light

  setup context do
    name =
      Module.concat(Hue.BridgeAwaitTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

    resources = [
      %{
        "type" => "light",
        "id" => "light-1",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0}
      },
      %{
        "type" => "device",
        "id" => "device-1",
        "metadata" => %{"name" => "Iris"},
        "services" => [%{"rid" => "light-1", "rtype" => "light"}]
      }
    ]

    start_supervised!({Bridge, name: name, client: Hue.Stub.client(resources: resources)}, id: name)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    {:ok, name: name, stream: stream}
  end

  defp await_live(name, remaining \\ 200) do
    cond do
      Bridge.status(name) == :live -> :ok
      remaining == 0 -> flunk("bridge never reached :live")
      true -> Process.sleep(10) && await_live(name, remaining - 1)
    end
  end

  defp push(stream, resources) do
    envelope = %{
      "creationtime" => "2026-08-07T10:00:00Z",
      "id" => "event-1",
      "type" => "update",
      "data" => resources
    }

    send(stream, {:frame, "id: 1:0\ndata: #{Jason.encode!([envelope])}\n\n"})
  end

  test "await returns once the confirming event arrives", %{name: name, stream: stream} do
    task = Task.async(fn -> Light.set(name, "Iris", on: true, await: true) end)

    assert_receive {:hue_stub, :put, _path, _body}, 1_000
    push(stream, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])

    assert :ok = Task.await(task, 2_000)
  end

  test "await does not return before the event arrives", %{name: name} do
    task = Task.async(fn -> Light.set(name, "Iris", on: true, await: true, await_timeout: 300) end)

    assert_receive {:hue_stub, :put, _path, _body}, 1_000
    assert catch_exit(Task.await(task, 150))

    # Let the task finish so the test does not leak it.
    Task.shutdown(task, :brutal_kill)
  end

  test "await times out rather than blocking forever", %{name: name} do
    assert {:error, %Error{reason: :timeout, rid: "light-1"}} =
             Light.set(name, "Iris", on: true, await: true, await_timeout: 100)
  end

  test "await is not woken by an event for a different light", %{name: name, stream: stream} do
    task = Task.async(fn -> Light.set(name, "Iris", on: true, await: true, await_timeout: 300) end)

    assert_receive {:hue_stub, :put, _path, _body}, 1_000
    push(stream, [%{"type" => "light", "id" => "light-99", "on" => %{"on" => true}}])

    assert {:error, %Error{reason: :timeout}} = Task.await(task, 2_000)
  end

  test "without await, set returns immediately", %{name: name} do
    {microseconds, :ok} = :timer.tc(fn -> Light.set(name, "Iris", on: true) end)
    assert microseconds < 50_000
  end

  test "a local error is returned before any waiting happens", %{name: name} do
    assert {:error, %Error{reason: :not_found}} = Light.set(name, "Nowhere", on: true, await: true)
  end

  test "await is not passed to the bridge as part of the body", %{name: name, stream: stream} do
    task = Task.async(fn -> Light.set(name, "Iris", on: true, await: true) end)

    assert_receive {:hue_stub, :put, _path, body}, 1_000
    assert body == %{"on" => %{"on" => true}}

    push(stream, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    Task.await(task, 2_000)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_await_test.exs`
Expected: FAIL — `unknown option(s) [:await]` raised by `Hue.Bridge.Body.build/2`, because `:await` is not in `@known_options`. That is the right failure: the option must be popped before the body is built.

- [ ] **Step 3: Add `await_write/5` to `Hue.Bridge`**

```elixir
  @default_await_timeout :timer.seconds(5)

  @doc """
  Queues a write and waits for the event that confirms it.

  Waits for the **event**, not the PUT's response, because the event is the
  thing that is true. Returns `:ok` once an event for that rid arrives,
  `{:error, %Hue.Error{}}` if the write failed, or
  `{:error, %Hue.Error{reason: :timeout}}` if nothing arrived in time.

  ## Two limitations worth knowing

  The wait happens in **your** mailbox. If this process was independently
  subscribed to the same rid, this call consumes the confirming event and your
  `handle_info` never sees it. And it unsubscribes afterwards, which clears a
  pre-existing `rid:` subscription for that same rid.

  Neither is a problem for the normal case — a script, a test, or a step in a
  sequence. If a process both subscribes by rid and needs confirmation, use the
  subscription it already has and match the event yourself.
  """
  @spec await_write(atom(), atom(), String.t(), map(), keyword()) :: :ok | {:error, Error.t()}
  def await_write(name, type, rid, body, options \\ []) do
    timeout = Keyword.get(options, :timeout, @default_await_timeout)

    with :ok <- subscribe(name, rid: rid) do
      try do
        with :ok <- write(name, type, rid, body), do: wait_for(rid, timeout)
      after
        unsubscribe(name, rid: rid)
      end
    end
  end

  # Selective receive on the rid: an event for a different resource is left in
  # the mailbox rather than consumed and discarded.
  defp wait_for(rid, timeout) do
    receive do
      {:hue, %Hue.Event{rid: ^rid, type: :error, data: %Error{} = error}} -> {:error, error}
      {:hue, %Hue.Event{rid: ^rid}} -> :ok
    after
      timeout -> {:error, %Error{reason: :timeout, rid: rid}}
    end
  end
```

- [ ] **Step 4: Accept `:await` in the three setters**

The pattern is the same in each: pop the two await options before building the body, then choose the write function. In `lib/hue/light.ex`:

```elixir
  def set(bridge, target, options) when is_binary(target) and is_list(options) do
    {await?, timeout, options} = Hue.Bridge.pop_await(options)

    with {:ok, light} <- get(bridge, target),
         {:ok, body} <- Body.build(options, light) do
      Bridge.put(bridge, :light, light["id"], body, await?, timeout)
    end
  end
```

In `lib/hue/group.ex`:

```elixir
  def set(bridge, type, target, options) do
    {await?, timeout, options} = Bridge.pop_await(options)

    with {:ok, grouped} <- Graph.grouped_light(Bridge.table(bridge), type, target),
         {:ok, body} <- Body.build(options, grouped) do
      Bridge.put(bridge, :grouped_light, grouped["id"], body, await?, timeout)
    end
  end
```

In `lib/hue/scene.ex`, pop before folding the recall options so `:await` never reaches `recall_option/2`:

```elixir
  def recall(bridge, target, options \\ []) do
    {await?, timeout, options} = Bridge.pop_await(options)
    recall = Enum.reduce(options, %{"action" => "active"}, &recall_option/2)

    with {:ok, scene} <- get(bridge, target) do
      Bridge.put(bridge, :scene, scene["id"], %{"recall" => recall}, await?, timeout)
    end
  end
```

And the two shared helpers in `lib/hue/bridge.ex`:

```elixir
  @doc false
  def pop_await(options) do
    {await?, options} = Keyword.pop(options, :await, false)
    {timeout, options} = Keyword.pop(options, :await_timeout, @default_await_timeout)
    {await?, timeout, options}
  end

  @doc false
  def put(name, type, rid, body, false, _timeout), do: write(name, type, rid, body)

  def put(name, type, rid, body, true, timeout),
    do: await_write(name, type, rid, body, timeout: timeout)
```

- [ ] **Step 5: Document `:await` in the three public moduledocs**

Add to `Hue.Light`'s options list, and mention it in `Hue.Room`, `Hue.Zone`, and `Hue.Scene`:

```
    * `:await` — wait for the event confirming the change instead of returning
      as soon as it is queued. See `Hue.Bridge.await_write/5` for what it
      consumes from your mailbox.
    * `:await_timeout` — milliseconds to wait when `await: true`. Defaults to 5 seconds.
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_await_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 7: Verify await genuinely waits**

Change `put/6`'s `true` clause to call `write/4` and return `:ok`:

Run: `cd ~/src/hue-ex && mix test test/hue/bridge_await_test.exs`
Expected: FAIL on "await does not return before the event arrives", on "await times out rather than blocking forever", and on "await is not woken by an event for a different light". Restore and confirm PASS.

- [ ] **Step 8: Run the whole suite**

Run: `cd ~/src/hue-ex && mix test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
cd ~/src/hue-ex
git add lib/hue/bridge.ex lib/hue/light.ex lib/hue/group.ex lib/hue/scene.ex test/hue/bridge_await_test.exs
git commit -m "Wait for the confirming event, not the response, when asked to"
```

---

### Task 16: Real hardware, docs, and the version

Layer 2 has never touched a bridge. Every test so far runs against a function plug, which means every test so far has agreed with this library's own model of the protocol — including wherever that model is wrong. Layer 1 found five distinct classes of bug this way, one of which (TLS session resumption bypassing the certificate pin) **only** real hardware could expose.

The live suite is read-and-restore: it may change state, but it must put it back.

**Files:**
- Modify: `test/live/live_test.exs`
- Modify: `README.md`
- Modify: `mix.exs` (version)
- Modify: `docs/superpowers/specs/2026-08-06-hue-library-design.md` (record what implementation changed)

- [ ] **Step 1: Add the live layer-2 suite**

Append to `test/live/live_test.exs`, following the existing `@tag :live` style:

```elixir
  describe "layer 2 against real hardware" do
    @describetag :live

    setup do
      client = live_client()
      name = Hue.LiveTest.Bridge

      start_supervised!({Hue.Bridge, name: name, client: client})

      assert eventually(fn -> Hue.Bridge.status(name) == :live end, 15_000),
             "bridge never synced; status was #{inspect(Hue.Bridge.status(name))}"

      {:ok, bridge: name}
    end

    test "the cache holds the same resource counts the fixture recorded", %{bridge: bridge} do
      {:ok, lights} = Hue.Light.list(bridge)
      {:ok, rooms} = Hue.Room.list(bridge)
      {:ok, zones} = Hue.Zone.list(bridge)

      # Counts, not identities: rids recorded on 2026-08-06 no longer exist.
      assert length(lights) == 19
      assert length(rooms) == 6
      assert length(zones) == 3
    end

    test "every light resolves by the name of the device that owns it", %{bridge: bridge} do
      {:ok, lights} = Hue.Light.list(bridge)

      for light <- lights do
        name = Hue.Bridge.name_of(bridge, :light, light["id"])
        assert is_binary(name), "light #{light["id"]} has no name from its owning device"
        assert {:ok, %{"id" => rid}} = Hue.Light.get(bridge, name)
        assert rid == light["id"]
      end
    end

    test "two rooms really do have no grouped_light", %{bridge: bridge} do
      {:ok, rooms} = Hue.Room.list(bridge)

      empty =
        Enum.count(rooms, fn room ->
          match?(
            {:error, %Hue.Error{reason: :no_grouped_light}},
            Hue.Room.set(bridge, room["id"], on: true)
          )
        end)

      assert empty == 2
    end

    test "the two non-dimmable lights are refused before the request leaves", %{bridge: bridge} do
      {:ok, lights} = Hue.Light.list(bridge)
      undimmable = Enum.reject(lights, &Map.has_key?(&1, "dimming"))

      assert length(undimmable) == 2

      for light <- undimmable do
        assert {:error, %Hue.Error{reason: :not_dimmable}} =
                 Hue.Light.set(bridge, light["id"], brightness: 50)
      end
    end

    @tag timeout: 30_000
    test "a real write produces a real event", %{bridge: bridge} do
      {:ok, lights} = Hue.Light.list(bridge)
      light = Enum.find(lights, &Map.has_key?(&1, "dimming"))
      original = light["on"]["on"]

      :ok = Hue.Bridge.subscribe(bridge, rid: light["id"])

      on_exit(fn -> Hue.Light.set(bridge, light["id"], on: original) end)

      :ok = Hue.Light.set(bridge, light["id"], on: !original)

      assert_receive {:hue, %Hue.Event{rid: _rid}}, 10_000

      # The cache must reflect it without anyone asking the bridge again.
      assert eventually(fn ->
               {:ok, cached} = Hue.Light.get(bridge, light["id"])
               cached["on"]["on"] == !original
             end)
    end

    @tag timeout: 30_000
    test "twenty rapid writes do not produce twenty requests", %{bridge: bridge} do
      {:ok, lights} = Hue.Light.list(bridge)
      light = Enum.find(lights, &Map.has_key?(&1, "dimming"))
      original = light["dimming"]["brightness"]

      on_exit(fn -> Hue.Light.set(bridge, light["id"], brightness: original) end)

      for brightness <- 30..49 do
        Hue.Light.set(bridge, light["id"], brightness: brightness / 1)
      end

      # A bridge that received twenty writes in a burst would answer some with
      # 429. Reaching the last value without one is the observable property.
      assert eventually(
               fn ->
                 {:ok, cached} = Hue.Light.get(bridge, light["id"])
                 round(cached["dimming"]["brightness"]) == 49
               end,
               10_000
             )
    end
  end
```

Add the `eventually/2` helper if the existing live file has none:

```elixir
  defp eventually(check, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(check, deadline)
  end

  defp do_eventually(check, deadline) do
    cond do
      check.() -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(100) && do_eventually(check, deadline)
    end
  end
```

- [ ] **Step 2: Re-pair with the bridge**

The application key from the layer-1 session was left in a session-scoped scratchpad that has since been garbage-collected. Pair again — it is a link-button press and one call.

Press the link button on the bridge, then within 30 seconds:

```bash
cd ~/src/hue-ex
mix run -e '
  {:ok, bridges} = Hue.Discovery.discover()
  bridge = hd(bridges)
  {:ok, credentials} = Hue.Pairing.pair_when_pressed(bridge, "hue-ex#layer2")
  IO.puts("HUE_HOST=#{bridge.host}")
  IO.puts("HUE_KEY=#{credentials.application_key}")
'
```

**Put the key somewhere durable this time** — `~/.config/hue-ex/credentials` or a password manager. Do not leave it in a scratchpad. It is a bearer credential for every light in the house.

- [ ] **Step 3: Run the live suite**

Run: `cd ~/src/hue-ex && HUE_HOST=192.168.178.146 HUE_KEY=<key> mix test --include live`
Expected: PASS.

**Treat every failure here as a finding about the protocol, not about the tests.** Layer 1's experience is that hardware disagrees with synthetic fixtures in ways no fixture test can predict. In particular, watch for:
- events arriving with a shape `Hue.Events.decode/1` drops silently (check the logs for "dropped");
- one action fanning out to a `grouped_light` update on `bridge_home` — expected, and it must not corrupt the cache;
- the bridge answering 429 despite the pacing, which would mean the intervals in `Hue.Bridge.Writes` are too aggressive.

Record whatever is found in the spec, in the same "Discovered during implementation" style layer 1 used for TLS resumption.

- [ ] **Step 4: Write the README's layer-2 section**

Add after the existing layer-1 quickstart:

````markdown
## Layer 2 — the live model

Layer 1 is a protocol client: every call is a request. That is the right shape
for a script and the wrong shape for an application, because "dim the living
room" over layer 1 means listing rooms, finding one by name, walking its
services, and then writing — several round trips, every time.

`Hue.Bridge` keeps a live model instead. It fetches the full state once, follows
the eventstream, and answers reads from ETS.

```elixir
children = [
  {Hue.Bridge, name: MyApp.Hue, client: client}
]
```

It never starts itself. You place it in your supervision tree, the way you place
Finch or Redix.

```elixir
{:ok, light} = Hue.Light.get(MyApp.Hue, "Desk Lamp")
:ok = Hue.Light.set(MyApp.Hue, "Iris", color: "#ff8800", brightness: 40)
:ok = Hue.Room.set(MyApp.Hue, "Living Room", on: false)
:ok = Hue.Scene.recall(MyApp.Hue, "Relax")
```

Targets are names or rids, interchangeably.

### Reads do not touch the process

`Hue.Light.get/2` is an `:ets.lookup` in your process. It does not message the
bridge, does not serialise against other readers, and does not queue behind an
eventstream frame being merged.

Writes are the opposite, deliberately: they go through the process because that
is the only place coalescing and Hue's rate limits can live. Twenty slider drags
on one light become one request carrying the last value.

`set` returns `:ok` once the write is queued, not once it is applied — the PUT's
response is not the truth, and the state change arrives as an event a moment
later. Pass `await: true` when you need confirmation.

### Subscribing

```elixir
Hue.Bridge.subscribe(MyApp.Hue, type: :button)

def handle_info({:hue, %Hue.Event{} = event}, state), do: ...
```

Filtering happens at the registry. A process waiting on button presses is not
woken when a scene changes nineteen lights.

### The failure that is silent

A dead eventstream does not announce itself. Every read keeps answering, and
every answer is quietly stale — the bridge sends no keepalive, so an idle stream
is indistinguishable from a dead one at the protocol level. `Hue.Bridge` detects
it at the transport layer and reconnects with backoff, refetching the full state
each time rather than resuming from an event id.

Attach to `[:hue, :stream, :disconnected]` if you want to know. It is the single
most useful thing to monitor about this library.
````

- [ ] **Step 5: Document the telemetry events**

Add a `## Telemetry` section to the README listing all of them, layer 1 and 2 together:

```
[:hue, :request, :start | :stop | :exception]   duration, type, rid, status
[:hue, :sync, :stop]                            duration, resource_count
[:hue, :stream, :connected]                     downtime
[:hue, :stream, :disconnected]                  reason
[:hue, :write, :coalesced]                      collapsed_count
[:hue, :write, :failed]                         reason
```

- [ ] **Step 6: Bump the version**

In `mix.exs`, `@version "0.2.0"`. A minor bump: layer 2 is entirely additive, and layer 1's only changes (`Hue.Resource.list_all/2`, `Hue.Resource.type/1`, two new error reasons) are additions too.

- [ ] **Step 7: Run precommit**

Run: `cd ~/src/hue-ex && mix precommit`
Expected: PASS — `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `credo --strict`, `dialyzer`, `test`.

Dialyzer is the one likely to complain, most often about `Hue.Bridge.status/1`'s union including `:not_started` where the `Cache.status/0` type does not. Widen the type rather than adding a `no_return` exemption.

- [ ] **Step 8: Update the spec with what implementation found**

The spec is the record of the design, and layer 1's most valuable sections are the ones written *after* the code disagreed with the plan. Add a "Discovered during implementation (layer 2)" subsection to `### Hue.Bridge internals` covering anything the live run in Step 3 turned up, plus the ordering decision this plan settled:

> **Connect ordering.** The stream is opened before the full fetch and its
> events are buffered until the seed completes, then replayed on top. Fetching
> first loses every change that happens in the gap. This narrows the window
> without closing it: `Hue.Events.stream/2` connects lazily on first
> enumeration, so the moment between "task started" and "socket open" is not
> observable from the server.

Also correct the spec's two known-stale claims while here:
- It references `Hue.Client.trust_new_certificate/1`, which was never implemented — re-trusting is re-running `Hue.Discovery.identify/2`.
- Its architecture diagram lists `Hue.Bridge` alone for layer 2; the built shape is a supervisor over `Registry`, `Task.Supervisor`, and `Hue.Bridge.Server`, with `Cache`, `Graph`, `Body`, `Writes`, `Merge`, and `Names` beneath.

- [ ] **Step 9: Commit and merge**

```bash
cd ~/src/hue-ex
git add -A
git commit -m "Prove layer 2 against the real bridge, and document it"
git tag -a v0.2.0 -m "Layer 2: the live bridge model"
```

---

## Self-review

Run this against the spec before declaring the plan done, and again after implementation.

**Spec coverage.** Every clause of "`Hue.Bridge` internals", "The write path", and the layer-2 half of "Architecture" maps to a task:

| Spec clause | Task |
|---|---|
| ETS `:protected`, `read_concurrency`, keyed `{type, rid}` | 4 |
| name index rebuilt on `metadata.name` change | 3, 4 |
| reads bypass the process | 4, 7 |
| writes go through it | 11, 12 |
| startup never blocks; `status/1` | 7 |
| reconnect always refetches, no `Last-Event-ID` | 8 |
| merge maps, replace lists; add/update/delete/error | 2, 4 |
| `Registry` subscriptions with type/name filters | 9 |
| multiple bridges are multiple named children | 7 |
| option → body translation | 10 |
| raise on caller bug, return on capability mismatch | 10 |
| capability errors caught before the request leaves | 10, 13 |
| async by default, coalescing, per-type pacing | 11, 12 |
| `await: true` | 15 |
| `Hue.Light` / `Room` / `Zone` / `Scene`, names or rids | 13, 14 |
| telemetry: sync, stream, write | 7, 8, 12 |
| `@tag :live` suite | 16 |

**Not covered, and deliberately.** The spec's `Hue.Color` section and error model were built in layer 1 and are consumed, not rebuilt. Entertainment streaming stays out of scope.

**Type consistency to re-check after implementation.** `Cache.status/0` and `Hue.Bridge.status/1` must agree, including `:not_started`. `Writes.key/0` is `{atom(), String.t()}` everywhere. `Bridge.put/6`'s arity is fixed by Task 15 and used by three callers — grep for it.

**Known risk.** Task 12's step 6 admits a property the tests cannot cover: that the PUT runs off the server's stack. It is verified structurally, by reading. If a later change moves `Resource.update/5` into a `handle_*` callback, nothing will fail. That is stated rather than papered over.
