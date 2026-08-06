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

  # KNOWN TO FAIL against real hardware -- reported prominently in Task 12's
  # write-up rather than patched here. Left asserting the documented
  # behaviour, not the observed one: the gap is in Hue.Transport, not in what
  # this suite should claim is true.
  #
  # `setup_all` already opened a `verify_peer` TLS connection to this same
  # host:port, pinned to the *real* fingerprint (identify/2's own pinned
  # `/api/config` request). Verified 2026-08-06 against this bridge,
  # independent of Req/Finch entirely (plain :ssl.connect/4, twice, back to
  # back, no HTTP involved): the second connection resumes the first one's
  # TLS session -- same session_id both times, per :ssl.connection_information/2
  # -- and OTP's :ssl does not re-invoke verify_fun for an abbreviated
  # handshake, because no certificate is re-presented for it to check. So a
  # *second* verify_peer connection to a host this process already holds a
  # session with can succeed under a fingerprint that does not match what is
  # actually pinned -- silently, with no alert and no Hue.Error at all.
  #
  # Confirmed this is specific to two verify_peer connections in a row: an
  # unverified (verify_none) connection followed by a wrongly-pinned one is
  # refused correctly, so Hue.Discovery.identify/2's own capture-then-verify
  # sequence is not affected by this. What is affected is exactly the case
  # this test sets up -- a wrongly-pinned client built after a correctly
  # pinned one has already talked to the bridge -- which is also the shape
  # `Hue.new/2`'s moduledoc documents as failing closed. It does not, here.
  # This is not this library's fixtures catching up; the fixture-based
  # pinning tests each spin up a fresh one-shot listener on its own ephemeral
  # port (see Hue.Certificates), so no session ever survives from one test to
  # the next for there to be anything to resume.
  #
  # The real application key is used here, deliberately, rather than a fake
  # one: it is the only way to make a resumption bypass unambiguous. An
  # earlier draft of this test used a nonsense key on the theory that TLS
  # would refuse the connection before the key was ever checked -- and
  # observed `{:error, %Hue.Error{reason: :unauthorized, status: 403}}`,
  # which reads exactly like a correct refusal until you notice *what*
  # refused it: a 403 is the HTTP layer rejecting a bad key over a
  # connection that TLS had already accepted. With the real key, the same
  # resumed session instead returns this bridge's actual light data --
  # proof, not just an inference, that the pin was never checked.
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
end
