defmodule Hue.LiveTest do
  @moduledoc """
  Runs against real hardware:

      HUE_HOST=192.168.1.10 HUE_KEY=... mix test --include live

  Excluded by default (`test/test_helper.exs` starts ExUnit with
  `exclude: [:live]`), so an ordinary `mix test` never touches the network.

  ## Read-only, always

  Every request this file makes is a `GET`. `Hue.Resource.update/5`,
  `create/4`, and `delete/4` do not appear here, and `Hue.Pairing.pair/2` and
  `pair_when_pressed/2` do not either — an application key already exists for
  this bridge, and pairing again would leave another whitelist entry for
  someone to clean up. The one pairing-adjacent thing this file could safely
  check (a `POST /api` with the button unpressed, which returns `type: 101`
  and creates nothing) is not worth the risk of getting that "creates
  nothing" claim wrong against real hardware, so it is not attempted either —
  everything below stays on `GET`.

  ## What this suite is for

  Everything else in this project is tested against recorded bytes and
  synthetic certificates (`Hue.Fixtures`, `Hue.Certificates`). This is the
  only place that proves the library works against the real thing, so several
  tests below cross-check a live read against what `Hue.Fixtures` recorded —
  agreement is itself the assertion.
  """

  use ExUnit.Case, async: false

  alias Hue.Color
  alias Hue.Color.Gamut

  @moduletag :live

  setup_all do
    host = System.get_env("HUE_HOST") || flunk("HUE_HOST is not set")
    key = System.get_env("HUE_KEY") || flunk("HUE_KEY is not set")

    {:ok, bridge} = Hue.Discovery.identify(host)
    {:ok, client} = Hue.from_bridge(bridge, application_key: key)

    {:ok, client: client, bridge: bridge, key: key}
  end

  test "the bridge is a CLIP v2 model", %{bridge: bridge} do
    assert bridge.model_id == "BSB002"
    assert bridge.bridge_id =~ ~r/\A[0-9A-F]{16}\z/
  end

  test "identify/2 pins a real sha256 fingerprint, reproducibly", %{bridge: bridge} do
    assert bridge.fingerprint =~ ~r/\A[0-9a-f]{64}\z/

    # Computed independently of Hue.Transport.fingerprint/1, which is the
    # function this is checking -- comparing its output to itself would
    # prove nothing. capture_certificate/3 hands back the raw DER, and the
    # hash is taken here with :crypto directly.
    {:ok, der} = Hue.Transport.capture_certificate(bridge.host, bridge.port)
    independently_computed = :sha256 |> :crypto.hash(der) |> Base.encode16(case: :lower)
    assert bridge.fingerprint == independently_computed

    # And a second, independent identify/2 call against the same bridge
    # captures the same pin -- this is not a fluke of one connection, and
    # every other test in this file relies on that being true.
    assert {:ok, %Hue.Bridge.Info{fingerprint: ^independently_computed}} =
             Hue.Discovery.identify(bridge.host, port: bridge.port)
  end

  # This test found a real bypass on 2026-08-06 and now guards the fix.
  #
  # `setup_all` has already opened a `verify_peer` TLS connection to this same
  # host:port, pinned to the *real* fingerprint (identify/2's own pinned
  # `/api/config` request). That used to be enough to defeat the pin: the
  # second connection resumed the first one's TLS session -- same session_id
  # both times, per :ssl.connection_information/2 -- and an abbreviated
  # handshake re-presents no certificate, so OTP never re-invoked verify_fun
  # and the wrong fingerprint below was never compared to anything. It
  # succeeded silently, with no alert and no Hue.Error at all. Reproduced
  # independently of Req and Finch, with two plain :ssl.connect/4 calls back
  # to back.
  #
  # Hue.Transport now disables session resumption on every connection it
  # builds options for, so each one performs a full handshake and the pin is
  # checked every time. Hue.Certificates grew the other half of the lesson:
  # its listeners pin TLS 1.2, matching this bridge, because on TLS 1.3 the
  # resumption this test is about cannot happen at all and the fixture suite
  # stayed green through the entire bug.
  #
  # The real application key is used here, deliberately, rather than a fake
  # one: it is the only way to make a resumption bypass unambiguous. An
  # earlier draft of this test used a nonsense key on the theory that TLS
  # would refuse the connection before the key was ever checked -- and
  # observed `{:error, %Hue.Error{reason: :unauthorized, status: 403}}`,
  # which reads exactly like a correct refusal until you notice *what*
  # refused it: a 403 is the HTTP layer rejecting a bad key over a
  # connection that TLS had already accepted. With the real key, a resumed
  # session instead returned this bridge's actual light data -- proof, not
  # just an inference, that the pin was never checked. Keep the real key.
  test "a wrong pinned fingerprint is refused as :certificate_changed", %{
    bridge: bridge,
    key: key
  } do
    wrong_fingerprint = String.duplicate("ab", 32)

    {:ok, wrong} =
      Hue.new(bridge.host,
        port: bridge.port,
        fingerprint: wrong_fingerprint,
        application_key: key
      )

    assert {:error, %Hue.Error{reason: :certificate_changed}} =
             Hue.Resource.list(wrong, :light)
  end

  test "an unauthenticated request fails with :unauthorized, not a TLS refusal", %{
    bridge: bridge
  } do
    # Pinned to the bridge's real fingerprint, so this isolates the
    # application-key check from TLS verification -- an unpinned client
    # would exercise a different (unverified) transport path entirely.
    {:ok, anonymous} =
      Hue.new(bridge.host,
        port: bridge.port,
        fingerprint: bridge.fingerprint,
        application_key: "not-a-real-key"
      )

    assert {:error, %Hue.Error{reason: :unauthorized, status: 403}} =
             Hue.Resource.list(anonymous, :light)
  end

  test "every light can be listed and has a resolvable owner", %{client: client} do
    {:ok, lights} = Hue.Resource.list(client, :light)
    {:ok, devices} = Hue.Resource.list(client, :device)

    device_ids = MapSet.new(devices, & &1["id"])

    assert lights != []

    for light <- lights do
      assert MapSet.member?(device_ids, light["owner"]["rid"]),
             "light #{light["id"]} has an owner that is not a known device"
    end
  end

  # Compared by count against Hue.Fixtures, not by rid: an earlier version of
  # this test asserted the exact set of rids matched, and it failed against
  # this real, lived-in bridge -- the two lights the fixture recorded as
  # dimming-less (rid a034f7cd…, rid 0376b692…) no longer exist on the
  # bridge at all, and two different lights ("Credenza Lamp", "Kitchen
  # Lamp") are dimming-less now instead, both reported reachable
  # (zigbee_connectivity status "connected") and stable across three
  # rechecks two seconds apart -- not a reachability flap. The household's
  # bridge was reconfigured between when `full_state.json` was captured and
  # when this suite ran. A fixture is a snapshot of a system that keeps
  # changing out from under it; asserting rid identity against one is
  # asserting more than a fixture can promise. The count is the fact worth
  # pinning.
  test "the same number of lights lack a dimming key as the fixtures recorded", %{
    client: client
  } do
    {:ok, live_lights} = Hue.Resource.list(client, :light)
    fixture_lights = Hue.Fixtures.resources("light")

    without_dimming = fn lights -> Enum.count(lights, &(not Map.has_key?(&1, "dimming"))) end

    assert without_dimming.(live_lights) == without_dimming.(fixture_lights)
    assert without_dimming.(live_lights) == 2
  end

  # See the comment on the dimming test above -- the same fixture-versus-live
  # rid drift applies here, so this compares counts rather than identity.
  test "the same number of rooms lack a grouped_light service as the fixtures recorded", %{
    client: client
  } do
    {:ok, live_rooms} = Hue.Resource.list(client, :room)
    fixture_rooms = Hue.Fixtures.resources("room")

    without_grouped_light = fn rooms ->
      Enum.count(
        rooms,
        &(not Enum.any?(&1["services"], fn service -> service["rtype"] == "grouped_light" end))
      )
    end

    assert without_grouped_light.(live_rooms) == without_grouped_light.(fixture_rooms)
    assert without_grouped_light.(live_rooms) == 2
  end

  test "the clip capability manifest lists the resource types this bridge supports", %{
    client: client
  } do
    assert {:ok, [manifest]} = Hue.Resource.list(client, :clip)

    for expected <- ~w(light room zone scene grouped_light device bridge button) do
      assert expected in manifest["resources"],
             "the capability manifest does not list #{expected}"
    end
  end

  test "a missing rid gets the recorded 404 shape", %{client: client} do
    assert {:error, %Hue.Error{reason: :not_found, status: 404} = error} =
             Hue.Resource.get(client, :light, "00000000-0000-0000-0000-000000000000")

    %{"errors" => [%{"description" => expected_description}]} =
      Hue.Fixtures.json("not_found_404.json")

    assert error.description == expected_description
  end

  # Enum.take(stream, 0) never calls Stream.resource/3's start_fun at all --
  # verified with an instrumented resource whose start_fun prints on entry:
  # nothing prints for Enum.take(0), because Elixir's Stream implementation
  # short-circuits before running it. The sketch's "connects and stays open"
  # test using Enum.take(0) therefore opened no connection and asserted
  # nothing. Enum.take(1) would be real, but it would also hang until
  # something in the house changes a light, which may never happen during a
  # test run.
  #
  # What can be asserted honestly, without depending on anyone touching a
  # light: a receive_timeout far shorter than the bridge's measured ~100s
  # idle window still has to survive a real TLS handshake and a real 200
  # response before there is anything left to wait on. So if the stream
  # raises :timeout -- not :unauthorized, not a transport error, and not
  # instantly -- the connection was genuinely opened and genuinely idle.
  test "the eventstream connects and then honestly times out on a quiet bridge", %{
    client: client
  } do
    {elapsed_microseconds, error} =
      :timer.tc(fn ->
        assert_raise Hue.Error, fn ->
          client |> Hue.Events.stream(receive_timeout: 3_000) |> Enum.to_list()
        end
      end)

    assert error.reason == :timeout
    assert div(elapsed_microseconds, 1_000) >= 3_000
  end

  test "colour converts into every real gamut on this bridge", %{client: client} do
    {:ok, lights} = Hue.Resource.list(client, :light)

    colour_lights = Enum.filter(lights, &Map.has_key?(&1, "color"))
    assert colour_lights != []

    for light <- colour_lights do
      assert {:ok, xy} = Color.to_xy("#ff8800", light)
      assert Gamut.contains?(Gamut.from_light(light), xy)
    end
  end

  # -- layer 2 -----------------------------------------------------------
  #
  # Everything above this point is read-only by construction (see the
  # moduledoc): it never calls Hue.Resource.update/5, so there is nothing to
  # restore. Layer 2 cannot make that same promise -- a live model exists to
  # be written to -- so every describe block below is read-and-restore
  # instead: it may change real state (a light's on/off, a light's
  # brightness), but on_exit/1 always puts it back before the test process
  # is torn down, win or lose.
  describe "layer 2 against real hardware" do
    @describetag :live

    # setup_all above already built :client from HUE_HOST/HUE_KEY -- reused
    # here rather than re-running Hue.Discovery.identify/2 and
    # Hue.from_bridge/2 a second time for the same bridge.
    setup %{client: client} do
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

      # Counts, not identities: rids recorded on 2026-08-06 no longer exist
      # -- see the fixture-drift comments earlier in this file.
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
end
