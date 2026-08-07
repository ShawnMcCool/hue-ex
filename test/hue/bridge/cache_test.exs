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

  test "a reseed still prunes orphaned names", %{table: table} do
    Cache.seed(table, [light("light-1"), device("Desk Lamp", "device-1", "light-1")])

    Cache.seed(table, [light("light-1")])

    assert {:error, %Error{reason: :not_found}} = Cache.fetch_by_name(table, :light, "Desk Lamp")
  end

  test "a reseed does not disturb the lifecycle facts", %{table: table} do
    Cache.seed(table, [light("light-1")])
    Cache.put_status(table, :live)

    Cache.seed(table, [light("light-2")])

    assert Cache.status(table) == :live
    assert {:ok, %{"id" => "light-2"}} = Cache.fetch(table, :light, "light-2")
    assert {:error, %Error{reason: :not_found}} = Cache.fetch(table, :light, "light-1")
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

  # `add` and `update` share one clause in Cache.apply_event/2 deliberately:
  # both mean "this is what the resource looks like now," and an update for a
  # rid the cache has never seen (e.g. a resource created before this bridge
  # finished its first sync) must insert exactly like an explicit add. Keep
  # both tests below — they pin that unification, not two copies of one fact.
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

  test "an event with an unrecognised envelope type is a no-op", %{table: table} do
    Cache.seed(table, [light("light-1")])

    Cache.apply_event(table, %Event{
      type: "some_future_envelope_type",
      resource_type: :light,
      rid: "light-1",
      data: %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}
    })

    assert {:ok, cached} = Cache.fetch(table, :light, "light-1")
    assert cached["on"] == %{"on" => false}
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
