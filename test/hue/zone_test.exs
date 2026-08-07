defmodule Hue.ZoneTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Zone

  # See Hue.GroupTest's own @receive_timeout comment: assert_receive on a
  # message that crosses a real process boundary (the stub's plug, a spawned
  # task) loses the 100 ms default under the full suite's concurrency.
  @receive_timeout 1_000

  # Hue.GroupTest exercises Zone only through cases shared with Room --
  # "zone write goes to grouped_light" and a not_dimmable failure -- so a
  # Zone-only regression (get/2 returning the wrong thing, a dimmable zone
  # write breaking, or a missing zone reporting the wrong reason) would not
  # be caught there. This file is Zone's own account.
  setup context do
    name =
      Module.concat(Hue.ZoneTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

    resources = [
      %{
        "type" => "zone",
        "id" => "zone-1",
        "metadata" => %{"name" => "Downstairs"},
        "services" => [%{"rid" => "gl-1", "rtype" => "grouped_light"}]
      },
      %{
        "type" => "grouped_light",
        "id" => "gl-1",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 50.0}
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

  test "get/2 returns the zone itself, not its grouped_light", %{name: name} do
    assert {:ok, %{"type" => "zone", "id" => "zone-1"}} = Zone.get(name, "Downstairs")
  end

  test "a zone can be dimmed when its grouped_light reports dimming", %{name: name} do
    assert :ok = Zone.set(name, "Downstairs", brightness: 30)

    assert_receive {:hue_stub, :put, "/clip/v2/resource/grouped_light/gl-1", body},
                   @receive_timeout

    assert body == %{"dimming" => %{"brightness" => 30.0}}
  end

  test "a zone that does not exist is :not_found", %{name: name} do
    assert {:error, %Error{reason: :not_found}} = Zone.set(name, "Nowhere", on: true)
    assert {:error, %Error{reason: :not_found}} = Zone.get(name, "Nowhere")
  end
end
