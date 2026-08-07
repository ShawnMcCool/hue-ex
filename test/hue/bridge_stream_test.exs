defmodule Hue.BridgeStreamTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Event

  # `Hue.Stub`'s eventstream is a bare function plug (see its moduledoc's "Why
  # not Req.Test"), and a function plug's whole body runs synchronously inside
  # one `Req.request` call: `Plug.Conn.chunk/2` only ever accumulates into the
  # plug's local state, and Req does not turn that into `{ref, {:data, _}}`
  # messages for the stream's consumer until the plug function *returns* — on
  # `:close`, on a kill, or on the stub's own idle timeout. There is no way to
  # push a frame to a consumer while `Hue.Stub`'s eventstream connection stays
  # nominally "open"; measured directly against this suite before landing this
  # helper, a frame sent without a following `:close` was still unobserved
  # 1.5 seconds later.
  #
  # So every test that needs a real frame to reach the cache through the real
  # `Hue.Events.stream/2` pipeline closes the connection right after sending
  # it, which flushes the whole batch at once. That in turn is a clean stream
  # close, which `disconnected/2` treats as a disconnect and schedules a
  # reconnect for — one that would refetch the stub's static `resources` list
  # and silently undo the very update being asserted on if it fired first. A
  # generous `reconnect_after` is what keeps that reconnect from racing the
  # assertion; the assertion itself resolves within milliseconds of the close.
  defp deliver_and_close(stream, iodata) do
    send(stream, {:frame, iodata})
    send(stream, :close)
  end

  setup context do
    name =
      Module.concat(
        Hue.BridgeStreamTest,
        context.test |> to_string() |> String.replace(~r/\W/, "_")
      )

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

    start(name, client, reconnect_after: 10_000)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    )

    assert_eventually(fn ->
      {:ok, cached} = Bridge.fetch(name, :light, "light-1")
      cached["on"] == %{"on" => true}
    end)
  end

  test "a partial event does not erase the rest of the light", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 42.0)])

    start(name, client, reconnect_after: 10_000)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "dimming" => %{"brightness" => 86.11}}])
    )

    assert_eventually(fn ->
      {:ok, cached} = Bridge.fetch(name, :light, "light-1")
      cached["dimming"] == %{"brightness" => 86.11, "min_dim_level" => 0.2}
    end)
  end

  test "one frame carrying several resources applies all of them", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 10.0), light("light-2", 20.0)])

    start(name, client, reconnect_after: 10_000)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    deliver_and_close(
      stream,
      frame([
        %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}},
        %{"type" => "light", "id" => "light-2", "on" => %{"on" => true}}
      ])
    )

    assert_eventually(fn ->
      {:ok, one} = Bridge.fetch(name, :light, "light-1")
      {:ok, two} = Bridge.fetch(name, :light, "light-2")
      one["on"]["on"] and two["on"]["on"]
    end)
  end

  test "the connect sequence opens a stream and issues a fetch", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 42.0)])

    start(name, client)

    assert_receive {:hue_stub, :eventstream, _stream}
    assert_receive {:hue_stub, :fetch, _path}
  end

  test "an event delivered at any point during connect is never lost", %{name: name} do
    client = Hue.Stub.client(resources: [light("light-1", 42.0)])

    start(name, client)

    # This is the behavioural claim behind "open the stream before the
    # fetch": not that the eventstream's request reaches the bridge before
    # the fetch's does on the wire -- `Hue.Events.stream/2` connects lazily on
    # first enumeration in a separately scheduled task, so this process does
    # not control, and the moduledoc does not promise, which request the
    # bridge observes first (see "The connect sequence, and why it is in this
    # order"). What is guaranteed is at the state level: `open_stream/1` sets
    # `syncing?: true` synchronously, before `sync/1` is ever called, so any
    # event delivered to the server from that point on is either buffered (if
    # still syncing) or applied directly (if already live) -- never silently
    # dropped. Sending as early as possible, immediately after `start/2`
    # returns, deliberately races both outcomes without caring which one
    # happens; either way the event must end up visible.
    send(
      Bridge.server(name),
      {:hue_event,
       %Event{
         type: :update,
         resource_type: :light,
         rid: "light-1",
         data: %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}
       }}
    )

    await_live(name)

    assert_eventually(fn ->
      {:ok, cached} = Bridge.fetch(name, :light, "light-1")
      cached["on"] == %{"on" => true}
    end)
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
    assert_receive {:hue_stub, :eventstream, _stream}
    assert_receive {:hue_stub, :fetch, _}

    # Sent straight to the server rather than through the stub's eventstream:
    # `Hue.Stub` cannot deliver a frame while its connection stays open (see
    # `deliver_and_close/2`), but this property is specifically about staying
    # connected *through* a fetch retry, so closing to force delivery would
    # test a different scenario (a stream drop mid-sync) than the one named
    # here. `{:hue_event, event}` is exactly what `open_stream/1`'s task sends
    # for a real decoded event, so this exercises the same `handle_info`
    # clause a real frame would.
    send(
      Bridge.server(name),
      {:hue_event,
       %Event{
         type: :update,
         resource_type: :light,
         rid: "light-1",
         data: %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}
       }}
    )

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

  test "a cleanly closed stream reconnects too", %{name: name} do
    client = Hue.Stub.client(resources: [])

    start(name, client, reconnect_after: 10)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    send(stream, :close)

    assert_receive {:hue_stub, :eventstream, _}, 1_000
  end

  test "a cleanly closed stream reports :closed, not the generic :normal a bare :DOWN would give",
       %{name: name} do
    # `Task.Supervisor.async_nolink` always sends a `:DOWN` message on any
    # task exit, clean or not (`reason: :normal` for a clean one) -- see the
    # `handle_info({ref, _result}, ...)` clause's comment in server.ex. That
    # means reconnection itself does not distinguish a clean close from a
    # missing clause: the test above would pass either way. What the clause
    # actually buys is telemetry precision, so that is what this test pins.
    handler = {__MODULE__, name, :closed_reason}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :stream, :disconnected],
      fn _e, measurements, metadata, _c ->
        send(test, {:disconnected, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    client = Hue.Stub.client(resources: [])

    start(name, client, reconnect_after: 10_000)
    assert_receive {:hue_stub, :eventstream, stream}
    await_live(name)

    send(stream, :close)

    assert_receive {:disconnected, _measurements, %{bridge: ^name, reason: :closed}}, 1_000
  end

  test "a dropped stream emits disconnected telemetry", %{name: name} do
    handler = {__MODULE__, name, :disconnected}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :stream, :disconnected],
      fn _e, measurements, metadata, _c ->
        send(test, {:disconnected, measurements, metadata})
      end,
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

    # The eventstream refuses every time (403) while the fetch keeps
    # succeeding -- exactly the scenario that defeated an earlier version of
    # `next_backoff/1`: `open_stream/1` and `sync/1` run back to back in one
    # reduction, so a successful fetch reset backoff to the base before this
    # server ever got a chance to process the stream task crashing, and every
    # reconnect gap stayed pinned at 20ms instead of growing (measured: eight
    # consecutive gaps, all ~20ms, before the fix).
    #
    # Measuring the actual gaps between reconnect attempts is what catches
    # that regression; a fixed sleep followed by one status check would not,
    # because the live/disconnected flicker a hammering bridge produces is
    # only a few milliseconds wide and unlikely to be sampled at all.
    timestamps =
      for _ <- 1..6 do
        assert_receive {:hue_stub, :fetch, _}, 1_000
        System.monotonic_time(:millisecond)
      end

    gaps = timestamps |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)

    # Generous margins rather than exact multiples of reconnect_after: the
    # property under test is "it grows from the base toward the cap", not
    # "it grows to exactly 40ms on the second attempt".
    assert Enum.at(gaps, 0) < 60
    assert Enum.at(gaps, -1) >= 150
  end
end
