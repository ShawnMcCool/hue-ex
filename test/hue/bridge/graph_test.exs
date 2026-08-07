defmodule Hue.Bridge.GraphTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Cache
  alias Hue.Bridge.Graph
  alias Hue.Error
  alias Hue.Event

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
    Cache.seed(table, [
      light("light-1"),
      device("light-1", "device-1", "light-2"),
      light("light-2")
    ])

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

  test "a room that arrives with no services list at all is :no_grouped_light", %{table: table} do
    # A real shape the eventstream can produce: an :update event's data is
    # whatever the delta carried, and for a rid the cache has never fully
    # seen there is no prior cached copy for Merge.merge/2 to fill "services"
    # in from — so the cached resource can end up with no "services" key at
    # all, not merely an empty list. The fixture never produces this (every
    # room and zone the bridge answers with carries "services", even when
    # empty), which is why this clause has no coverage from the fixture test
    # below and needs its own.
    Cache.seed(table, [])

    Cache.apply_event(table, %Event{
      type: :update,
      resource_type: :room,
      rid: "room-3",
      data: %{"type" => "room", "id" => "room-3", "metadata" => %{"name" => "Half-Built Room"}}
    })

    assert {:error, %Error{reason: :no_grouped_light, rid: "room-3"}} =
             Graph.grouped_light(table, :room, "room-3")
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

    assert {:error, %Error{reason: :not_synced}} =
             Graph.grouped_light(table, :room, "Living Room")
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
