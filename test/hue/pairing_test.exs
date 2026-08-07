defmodule Hue.PairingTest do
  use ExUnit.Case, async: true

  alias Hue.Error
  alias Hue.Pairing

  setup do
    bridge = %Hue.Bridge.Info{host: "192.0.2.10", bridge_id: "0011223344556677"}
    {:ok, bridge: bridge}
  end

  test "pair/2 returns both keys on success", %{bridge: bridge} do
    plug =
      fn conn ->
        assert conn.request_path == "/api"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["generateclientkey"] == true
        assert decoded["devicetype"] =~ "#"

        Req.Test.json(conn, [
          %{"success" => %{"username" => "APP-KEY-40", "clientkey" => "CLIENT-KEY-32"}}
        ])
      end

    Req.Test.stub(__MODULE__, plug)

    assert {:ok, %{application_key: "APP-KEY-40", clientkey: "CLIENT-KEY-32"}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "the unpressed link button is a typed error, not a crash", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, Hue.Fixtures.raw("pairing_link_button_not_pressed.json"))
    end)

    assert {:error, %Error{reason: :link_button_not_pressed, type: 101}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "device_type/1 is within Hue's 40-character limit" do
    assert byte_size(Pairing.device_type("fae")) <= 40
    assert Pairing.device_type("fae") =~ ~r/\Ahue_ex#/
  end

  test "device_type/1 stays within the byte limit for a multi-byte app name" do
    # Each "é" is two bytes, so a naive grapheme slice at 40 graphemes would
    # overshoot 40 bytes. Confirms the byte-safe truncation actually holds.
    app = String.duplicate("é", 40)

    device_type = Pairing.device_type(app)

    assert byte_size(device_type) <= 40
    # And no grapheme was split in half, which would produce invalid UTF-8.
    assert String.valid?(device_type)
  end

  test "pair/2 defaults the request to the bridge's port, omitting it when 443" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.port == 443
      Req.Test.json(conn, [%{"success" => %{"username" => "u", "clientkey" => "c"}}])
    end)

    assert {:ok, _} =
             Pairing.pair(%Hue.Bridge.Info{host: "192.0.2.10"}, plug: {Req.Test, __MODULE__})
  end

  test "pair/2 is a typed error, not a crash, for a non-200 response", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    assert {:error, %Error{status: 404}} = Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "pair/2 turns a transport failure into a typed error", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %Error{reason: :econnrefused}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__}, retry: false)
  end

  test "pair/2 falls back rather than raising on a malformed body", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"unexpected" => "shape"})
    end)

    assert {:error, %Error{reason: :unexpected_response}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "pair/2 falls back rather than raising on an empty list body", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [])
    end)

    assert {:error, %Error{reason: :unexpected_response}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  # An "error" key alone is not enough to hand the body to
  # Hue.Error.from_pairing/1 — it also requires a "type". This is the
  # plausible-firmware case: a future or unusual bridge response that carries
  # a description but no numeric type must not crash the caller.
  test "pair/2 falls back rather than raising on an error with no type", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [%{"error" => %{"description" => "something went wrong"}}])
    end)

    assert {:error, %Error{reason: :unexpected_response}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "pair/2 falls back rather than raising on a non-map error value", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, [%{"error" => "oops"}])
    end)

    assert {:error, %Error{reason: :unexpected_response}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "pair/2 falls back rather than raising on an error-shaped bare map", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"error" => %{"type" => 101}})
    end)

    assert {:error, %Error{reason: :unexpected_response}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "pair/2 does not silently drop TLS pinning when a caller supplies connect_options", %{
    bridge: bridge
  } do
    assert_raise ArgumentError, ~r/transport_opts/, fn ->
      Pairing.pair(bridge,
        plug: {Req.Test, __MODULE__},
        connect_options: [transport_opts: [verify: :verify_none]]
      )
    end
  end

  test "pair/2 rejects an option Req itself does not recognise", %{bridge: bridge} do
    assert_raise ArgumentError, fn ->
      Pairing.pair(bridge, plug: {Req.Test, __MODULE__}, totally_bogus_option: true)
    end
  end

  describe "pair_when_pressed/2" do
    test "succeeds after an initial link-button-not-pressed failure", %{bridge: bridge} do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        count = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

        if count == 1 do
          Plug.Conn.send_resp(
            conn,
            200,
            Hue.Fixtures.raw("pairing_link_button_not_pressed.json")
          )
        else
          Req.Test.json(conn, [%{"success" => %{"username" => "u", "clientkey" => "c"}}])
        end
      end)

      assert {:ok, %{application_key: "u", clientkey: "c"}} =
               Pairing.pair_when_pressed(bridge,
                 plug: {Req.Test, __MODULE__},
                 timeout: 500,
                 poll_interval: 5
               )

      assert Agent.get(attempts, & &1) == 2
    end

    test "gives up and returns the last error once the timeout elapses", %{bridge: bridge} do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, Hue.Fixtures.raw("pairing_link_button_not_pressed.json"))
      end)

      assert {:error, %Error{reason: :link_button_not_pressed}} =
               Pairing.pair_when_pressed(bridge,
                 plug: {Req.Test, __MODULE__},
                 timeout: 20,
                 poll_interval: 5
               )
    end

    test "returns immediately on a non-recoverable error, without polling", %{bridge: bridge} do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(attempts, &(&1 + 1))
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, %Error{reason: :unexpected_response}} =
               Pairing.pair_when_pressed(bridge,
                 plug: {Req.Test, __MODULE__},
                 timeout: 500,
                 poll_interval: 5
               )

      assert Agent.get(attempts, & &1) == 1
    end
  end

  describe "telemetry" do
    # Mirrors Hue.ResourceTest's "emits start and stop around a read": the
    # ref proves the message came from this handler, but not which test's
    # request produced it, since the span fires for every [:hue, :pairing]
    # call anywhere in this async suite. Matching the expected content
    # inside the receive pattern itself keeps the assertion specific to this
    # call rather than any concurrently running one.
    test "emits start and stop around pair/2", %{bridge: bridge} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:hue, :pairing, :start],
          [:hue, :pairing, :stop]
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, [
          %{"success" => %{"username" => "APP-KEY-40", "clientkey" => "CLIENT-KEY-32"}}
        ])
      end)

      assert {:ok, _keys} = Pairing.pair(bridge, plug: {Req.Test, __MODULE__})

      assert_received {[:hue, :pairing, :start], ^ref, %{monotonic_time: _},
                       %{method: :post, path: "/api"}}

      assert_received {[:hue, :pairing, :stop], ^ref, %{duration: _},
                       %{method: :post, path: "/api", result: :ok}}
    end

    test "emits stop with result: :error on a bridge error", %{bridge: bridge} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:hue, :pairing, :stop]])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, Hue.Fixtures.raw("pairing_link_button_not_pressed.json"))
      end)

      Pairing.pair(bridge, plug: {Req.Test, __MODULE__})

      assert_received {[:hue, :pairing, :stop], ^ref, _measurements,
                       %{method: :post, path: "/api", result: :error}}
    end
  end
end
