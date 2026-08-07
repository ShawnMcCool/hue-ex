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

  test "the real fixture names every room, zone, scene, and smart scene" do
    entries = Names.entries(Hue.Fixtures.full_state()["data"])

    assert Enum.count(entries, &match?({{:name, :room, _}, _}, &1)) == 6
    assert Enum.count(entries, &match?({{:name, :zone, _}, _}, &1)) == 3
    assert Enum.count(entries, &match?({{:name, :scene, _}, _}, &1)) == 34
    assert Enum.count(entries, &match?({{:name, :smart_scene, _}, _}, &1)) == 2
  end
end
