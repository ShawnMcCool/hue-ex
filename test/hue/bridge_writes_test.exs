defmodule Hue.BridgeWritesTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Event

  # See Hue.BridgeStreamTest's own @receive_timeout comment: assert_receive on
  # a message that crosses a real process boundary (the stub's plug, a
  # spawned task) loses the 100 ms default under the full suite's
  # concurrency. One shared attribute so every assertion added here inherits
  # the margin rather than the mistake.
  @receive_timeout 1_000

  setup context do
    name =
      Module.concat(
        Hue.BridgeWritesTest,
        context.test |> to_string() |> String.replace(~r/\W/, "_")
      )

    resources = [
      %{
        "type" => "light",
        "id" => "light-1",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0}
      },
      %{
        "type" => "light",
        "id" => "light-2",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0}
      },
      %{"type" => "grouped_light", "id" => "gl-1", "on" => %{"on" => false}}
    ]

    client = Hue.Stub.client(resources: resources)
    start_supervised!({Bridge, name: name, client: client}, id: name)

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

  test "a write reaches the bridge", %{name: name} do
    assert :ok = Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", body}, @receive_timeout
    assert body == %{"on" => %{"on" => true}}
  end

  test "a write returns before the bridge has answered", %{name: name} do
    # If write/4 blocked on the response, this would not be measurable as fast.
    {microseconds, :ok} =
      :timer.tc(fn -> Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}}) end)

    assert microseconds < 50_000
    assert_receive {:hue_stub, :put, _path, _body}, @receive_timeout
  end

  test "twenty writes to one light collapse to far fewer requests", %{name: name} do
    for brightness <- 1..20 do
      Bridge.write(name, :light, "light-1", %{"dimming" => %{"brightness" => brightness / 1}})
    end

    # How many requests this splits into is not fixed. `arm_flush/2` arms the
    # first flush at `due_in/3 == 0` for a target no write has been sent for
    # yet, and `Process.send_after(self(), msg, 0)` is still an asynchronous
    # timer message, not a synchronous send — whether it reaches the
    # server's mailbox before or after this same test process finishes
    # casting all twenty writes (itself uninterrupted, since none of them
    # block) is a scheduling race, not something this test controls. Fully
    # coalescing before the first flush fires (one PUT) and firing partway
    # through (two or three) are both correct outcomes; twenty is the only
    # wrong one. `assert_receive` captures the first PUT directly rather
    # than discarding it — draining only what is left after a consumed
    # message found nothing on a full-coalesce run, which is what broke this
    # test the first time it was written.
    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", first_body},
                   @receive_timeout

    Process.sleep(150)
    puts = [first_body | drain_puts()]

    assert length(puts) <= 3
    assert List.last(puts)["dimming"]["brightness"] == 20.0
  end

  test "coalescing is reported through telemetry", %{name: name} do
    handler = {__MODULE__, name, :coalesced}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :write, :coalesced],
      fn _e, measurements, metadata, _c -> send(test, {:coalesced, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})
    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => false}})

    assert_receive {:coalesced, %{collapsed_count: 1}, %{bridge: ^name, type: :light}},
                   @receive_timeout
  end

  test "writes to two different lights are both sent", %{name: name} do
    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})
    Bridge.write(name, :light, "light-2", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", _}, @receive_timeout
    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-2", _}, @receive_timeout
  end

  test "a grouped_light write goes to the grouped_light path", %{name: name} do
    Bridge.write(name, :grouped_light, "gl-1", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/grouped_light/gl-1", _}, @receive_timeout
  end

  test "the server keeps serving reads while a write is in flight", %{name: name} do
    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})

    assert {:ok, %{"id" => "light-1"}} = Bridge.fetch(name, :light, "light-1")
    assert Bridge.status(name) == :live
  end

  test "a write to a bridge that is not running is an error" do
    assert {:error, %Hue.Error{reason: :not_started}} =
             Bridge.write(Hue.BridgeWritesTest.Nowhere, :light, "light-1", %{})
  end

  # -- pacing, measured rather than assumed ------------------------------

  # Task 8's backoff bug grew from nothing and was invisible to every
  # property assertion that only checked *whether* reconnection happened;
  # measuring the actual gap was what caught it. The same discipline applies
  # here: this does not assert that `Writes.due_in/3` was consulted before
  # `Writes.take/3` (an implementation detail two `assert_receive`s cannot
  # establish an order between anyway, since `assert_receive` scans the
  # mailbox rather than dequeuing), it measures the wall-clock gap between
  # two real PUTs landing at the stub.
  test "writes to two lights are paced roughly 100ms apart, measured directly", %{name: name} do
    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})
    Bridge.write(name, :light, "light-2", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", _}, @receive_timeout
    first_at = System.monotonic_time(:millisecond)

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-2", _}, @receive_timeout
    second_at = System.monotonic_time(:millisecond)

    # Hue.Bridge.Writes' light interval is 100ms. A generous lower bound
    # (rather than asserting ~100ms exactly) keeps this from flaking under
    # scheduler jitter while still failing hard if pacing collapsed to ~0.
    assert second_at - first_at >= 80
  end

  # -- no starvation across a burst of distinct targets --------------------

  test "a burst of writes to five different lights all eventually get sent" do
    name = Hue.BridgeWritesTest.Burst

    resources =
      for n <- 1..5 do
        %{"type" => "light", "id" => "light-#{n}", "on" => %{"on" => false}}
      end

    client = Hue.Stub.client(resources: resources)
    start_supervised!({Bridge, name: name, client: client}, id: name)
    assert_receive {:hue_stub, :eventstream, _stream}, @receive_timeout
    await_live(name)

    for n <- 1..5 do
      Bridge.write(name, :light, "light-#{n}", %{"on" => %{"on" => true}})
    end

    rids =
      for _ <- 1..5 do
        assert_receive {:hue_stub, :put, "/clip/v2/resource/light/" <> rid, _}, @receive_timeout
        rid
      end

    assert Enum.sort(rids) == Enum.map(1..5, &"light-#{&1}")
  end

  # -- Writes.due_in/3 can return :never ------------------------------------

  test "a completed flush with nothing else queued does not crash the server", %{name: name} do
    server_pid = Process.whereis(Bridge.server(name))

    # After this write is taken and sent, arm_flush/2 asks Writes.due_in/3
    # again for :light and gets :never back -- nothing of that type is
    # pending any more. Process.send_after/3 raises ArgumentError on :never,
    # and dialyzer does not catch a probe that passes due_in/3's result
    # straight through (success typing only rejects calls that can never
    # succeed, and the union includes non_neg_integer()). If arm_flush/2 did
    # that, this is exactly where the server would crash -- immediately after
    # its first ever write of a type, which every other single-write test in
    # this file would also have hit.
    assert :ok = Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})
    assert_receive {:hue_stub, :put, _path, _body}, @receive_timeout

    Process.sleep(50)
    assert Process.whereis(Bridge.server(name)) == server_pid
    assert Bridge.status(name) == :live

    # And the server still does its job afterwards -- a crash-and-restart
    # would also leave the pid different, caught above, but confirm the
    # write path itself still functions rather than merely "is still alive".
    assert :ok = Bridge.write(name, :light, "light-1", %{"on" => %{"on" => false}})
    assert_receive {:hue_stub, :put, _path, %{"on" => %{"on" => false}}}, @receive_timeout
  end

  # -- a failed write is not silent -----------------------------------------

  test "a failed write surfaces as telemetry and an error event to subscribers" do
    name = Hue.BridgeWritesTest.FailingWrite
    resources = [%{"type" => "light", "id" => "light-1", "on" => %{"on" => false}}]
    client = Hue.Stub.client(resources: resources, put_status: 429)

    start_supervised!({Bridge, name: name, client: client}, id: name)
    assert_receive {:hue_stub, :eventstream, _stream}, @receive_timeout
    await_live(name)

    handler = {__MODULE__, name, :write_failed}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :write, :failed],
      fn _e, measurements, metadata, _c ->
        send(test, {:write_failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Bridge.subscribe(name)

    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})

    assert_receive {:write_failed, %{},
                    %{bridge: ^name, type: :light, rid: "light-1", reason: :rate_limited}},
                   @receive_timeout

    assert_receive {:hue,
                    %Event{
                      type: :error,
                      resource_type: :light,
                      rid: "light-1",
                      data: %Error{reason: :rate_limited}
                    }},
                   @receive_timeout
  end

  # A write the bridge answers with HTTP 200 but a non-empty `errors`
  # alongside `data` is not a transport failure — `Resource.update/5` in its
  # default `:simple` mode would report it as a plain `:ok`, because
  # `Resource.interpret/2` matches on `data` alone and discards `errors`.
  # `send_write/4` asks for `return: :detailed` specifically so this is
  # visible here rather than silently treated as success.
  test "a partially rejected write surfaces as telemetry and an error event carrying the bridge's description" do
    name = Hue.BridgeWritesTest.PartialWrite
    resources = [%{"type" => "light", "id" => "light-1", "on" => %{"on" => false}}]

    client =
      Hue.Stub.client(
        resources: resources,
        put_errors: [%{"description" => "brightness out of range"}]
      )

    start_supervised!({Bridge, name: name, client: client}, id: name)
    assert_receive {:hue_stub, :eventstream, _stream}, @receive_timeout
    await_live(name)

    handler = {__MODULE__, name, :partial_write_failed}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :write, :failed],
      fn _e, measurements, metadata, _c ->
        send(test, {:write_failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Bridge.subscribe(name)

    Bridge.write(name, :light, "light-1", %{"dimming" => %{"brightness" => 150}})

    assert_receive {:write_failed, %{},
                    %{bridge: ^name, type: :light, rid: "light-1", reason: :unexpected_response}},
                   @receive_timeout

    assert_receive {:hue,
                    %Event{
                      type: :error,
                      resource_type: :light,
                      rid: "light-1",
                      data: %Error{
                        reason: :unexpected_response,
                        description: "brightness out of range"
                      }
                    }},
                   @receive_timeout
  end

  test "a write the bridge fully accepts is not reported as a failure" do
    name = Hue.BridgeWritesTest.CleanWrite
    resources = [%{"type" => "light", "id" => "light-1", "on" => %{"on" => false}}]
    client = Hue.Stub.client(resources: resources)

    start_supervised!({Bridge, name: name, client: client}, id: name)
    assert_receive {:hue_stub, :eventstream, _stream}, @receive_timeout
    await_live(name)

    handler = {__MODULE__, name, :clean_write_failed}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :write, :failed],
      fn _e, measurements, metadata, _c ->
        send(test, {:write_failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Bridge.subscribe(name)

    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", _body}, @receive_timeout

    # A bounded window, not a bare refute_receive: proving nothing arrives
    # needs time for it to have arrived in, or the assertion is vacuous.
    refute_receive {:write_failed, _measurements, _metadata}, 200
    refute_receive {:hue, %Event{type: :error}}, 200
  end

  # -- the PUT is genuinely off the server's stack --------------------------

  # The plan this task follows from admits its own version of this test
  # cannot distinguish "off the server's stack" from "the stub answers fast
  # enough that it doesn't matter" -- a stub that answers immediately makes
  # every synchronous alternative look asynchronous too. `:put_hang` (added
  # to Hue.Stub for this) closes that gap the same way Task 7's
  # `:fetch_hang` did: it never answers at all, so anything that actually
  # blocks on it blocks forever, not briefly.
  #
  # Ordering matters and is the part a first draft of this test got wrong.
  # Sending the injected event *immediately after* `Bridge.write/4` returns
  # races the 0ms flush timer: `write/4` only casts, the actual PUT does not
  # start until the later `{:flush, :light}` message is processed, and the
  # injected event can reach the server first regardless of whether the PUT
  # would have blocked it -- which is exactly what happened when this was
  # tried by hand against a deliberately reverted, synchronous `send_write/4`:
  # the test passed anyway, having proven nothing. `Hue.Stub` sends
  # `{:hue_stub, :put, ...}` to this process *before* it hangs, from
  # whichever process made the request, so waiting for that first pins the
  # ordering: the request is now genuinely in flight (and about to hang)
  # before the injected event is sent.
  #
  # With that fix, reverting `send_write/4` to call `Resource.update/5`
  # directly (so the PUT runs inside `handle_info({:flush, ...})` itself)
  # makes this test fail as intended: `{:hue_stub, :put, ...}` arrives from
  # the server's own process just before it parks in the stub's `receive do
  # end`, the injected event queues behind that forever, and
  # `assert_eventually` flunks after ~2s. Confirmed by hand while
  # implementing this task, then restored.
  test "a write that never gets a response does not stall event ingestion" do
    name = Hue.BridgeWritesTest.HangingWrite
    resources = [%{"type" => "light", "id" => "light-1", "on" => %{"on" => false}}]
    client = Hue.Stub.client(resources: resources, put_hang: true)

    start_supervised!({Bridge, name: name, client: client, reconnect_after: 10_000}, id: name)
    assert_receive {:hue_stub, :eventstream, _stream}, @receive_timeout
    await_live(name)

    Bridge.write(name, :light, "light-1", %{"dimming" => %{"brightness" => 1.0}})

    # Proves the PUT is genuinely in flight (and, by construction, about to
    # hang) before the next step -- not merely that write/4 returned.
    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", _body}, @receive_timeout

    # Sent straight to the server's own mailbox, bypassing the network
    # entirely: if handling the hung write had blocked the server, this
    # would queue behind it and never be observed.
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

    assert_eventually(fn ->
      {:ok, cached} = Bridge.fetch(name, :light, "light-1")
      cached["on"] == %{"on" => true}
    end)

    assert Bridge.status(name) == :live
  end

  # -- a queued write does not depend on the eventstream being up ----------

  test "a write is still sent while the stream is disconnected" do
    name = Hue.BridgeWritesTest.WriteWhileDown
    resources = [%{"type" => "light", "id" => "light-1", "on" => %{"on" => false}}]
    client = Hue.Stub.client(resources: resources)

    # A generous reconnect_after keeps the automatic reconnect cycle from
    # racing this test's own assertions -- see Hue.BridgeStreamTest's
    # deliver_and_close/2 comment for the same reasoning.
    start_supervised!({Bridge, name: name, client: client, reconnect_after: 10_000}, id: name)
    assert_receive {:hue_stub, :eventstream, stream}, @receive_timeout
    await_live(name)

    send(stream, :close)

    assert_eventually(fn -> Bridge.status(name) == {:error, :closed} end)

    Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1",
                    %{"on" => %{"on" => true}}},
                   @receive_timeout
  end

  defp assert_eventually(check, remaining \\ 200) do
    cond do
      check.() -> true
      remaining == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && assert_eventually(check, remaining - 1)
    end
  end

  defp drain_puts(acc \\ []) do
    receive do
      {:hue_stub, :put, _path, body} -> drain_puts([body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
