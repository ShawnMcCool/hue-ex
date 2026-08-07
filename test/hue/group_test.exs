defmodule Hue.GroupTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Room
  alias Hue.Scene
  alias Hue.Zone

  # See Hue.BridgeWritesTest's own @receive_timeout comment: assert_receive on
  # a message that crosses a real process boundary (the stub's plug, a
  # spawned task) loses the 100 ms default under the full suite's
  # concurrency. One shared attribute so every assertion added here inherits
  # the margin rather than the mistake.
  @receive_timeout 1_000
  # A bounded window, not a bare refute_receive: proving nothing arrives
  # needs time to not-arrive in. See Hue.BridgeSubscriptionsTest's own note.
  @refute_window 200

  setup context do
    name =
      Module.concat(Hue.GroupTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

    resources = [
      %{
        "type" => "room",
        "id" => "room-1",
        "metadata" => %{"name" => "Living Room"},
        "services" => [%{"rid" => "gl-1", "rtype" => "grouped_light"}]
      },
      %{
        "type" => "room",
        "id" => "room-2",
        "metadata" => %{"name" => "Spare Room"},
        "services" => []
      },
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

    start_supervised!({Bridge, name: name, client: Hue.Stub.client(resources: resources)},
      id: name
    )

    assert_receive {:hue_stub, :eventstream, _stream}, @receive_timeout
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

    assert_receive {:hue_stub, :put, "/clip/v2/resource/grouped_light/gl-1", body},
                   @receive_timeout

    assert body == %{"on" => %{"on" => false}}
  end

  test "a zone write goes to the zone's grouped_light", %{name: name} do
    assert :ok = Zone.set(name, "Downstairs", on: true)

    assert_receive {:hue_stub, :put, "/clip/v2/resource/grouped_light/gl-2", _body},
                   @receive_timeout
  end

  test "a room can be dimmed when its grouped_light reports dimming", %{name: name} do
    assert :ok = Room.set(name, "Living Room", brightness: 25)

    assert_receive {:hue_stub, :put, _path, %{"dimming" => %{"brightness" => 25.0}}},
                   @receive_timeout
  end

  test "an empty room is :no_grouped_light and sends nothing", %{name: name} do
    assert {:error, %Error{reason: :no_grouped_light, rid: "room-2"}} =
             Room.set(name, "Spare Room", on: true)

    refute_receive {:hue_stub, :put, _, _}, @refute_window
  end

  test "dimming a group whose grouped_light has no dimming is :not_dimmable", %{name: name} do
    assert {:error, %Error{reason: :not_dimmable, rid: "gl-2"}} =
             Zone.set(name, "Downstairs", brightness: 25)

    refute_receive {:hue_stub, :put, _, _}, @refute_window
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

    assert_receive {:hue_stub, :put, "/clip/v2/resource/scene/scene-1", body}, @receive_timeout
    assert body == %{"recall" => %{"action" => "active"}}
  end

  test "a scene recall can carry a duration", %{name: name} do
    assert :ok = Scene.recall(name, "Relax", duration: 2_000)

    assert_receive {:hue_stub, :put, _path, body}, @receive_timeout
    assert body == %{"recall" => %{"action" => "active", "duration" => 2_000}}
  end

  test "recalling a scene that does not exist is :not_found", %{name: name} do
    assert {:error, %Error{reason: :not_found}} = Scene.recall(name, "Nowhere")
  end

  test "a negative scene duration raises", %{name: name} do
    assert_raise ArgumentError, ~r/duration/, fn -> Scene.recall(name, "Relax", duration: -1) end
  end
end
