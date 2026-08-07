defmodule Hue.LightTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Light

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
      Module.concat(Hue.LightTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

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

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", body}, @receive_timeout
    assert body == %{"on" => %{"on" => true}}
  end

  test "set/3 combines several options into one body", %{name: name} do
    assert :ok = Light.set(name, "Iris", on: true, brightness: 40, transition: 400)

    assert_receive {:hue_stub, :put, _path, body}, @receive_timeout

    assert body == %{
             "on" => %{"on" => true},
             "dimming" => %{"brightness" => 40.0},
             "dynamics" => %{"duration" => 400}
           }
  end

  test "set/3 converts a colour through the light's own gamut", %{name: name} do
    assert :ok = Light.set(name, "Iris", color: "#ff8800")

    assert_receive {:hue_stub, :put, _path, %{"color" => %{"xy" => %{"x" => _, "y" => _}}}},
                   @receive_timeout
  end

  test "brightness on a light with no dimming is refused before any request", %{name: name} do
    assert {:error, %Error{reason: :not_dimmable, rid: "light-2"}} =
             Light.set(name, "Hallway", brightness: 40)

    refute_receive {:hue_stub, :put, _, _}, @refute_window
  end

  test "colour on a light with no colour is refused before any request", %{name: name} do
    assert {:error, %Error{reason: :not_color_capable}} =
             Light.set(name, "Hallway", color: "#ff8800")

    refute_receive {:hue_stub, :put, _, _}, @refute_window
  end

  test "set/3 on an unknown target is :not_found and sends nothing", %{name: name} do
    assert {:error, %Error{reason: :not_found}} = Light.set(name, "Nowhere", on: true)

    refute_receive {:hue_stub, :put, _, _}, @refute_window
  end

  test "a malformed option raises rather than returning an error", %{name: name} do
    assert_raise ArgumentError, ~r/brightness/, fn ->
      Light.set(name, "Iris", brightness: "loud")
    end
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
