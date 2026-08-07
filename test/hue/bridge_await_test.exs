defmodule Hue.BridgeAwaitTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Event
  alias Hue.Light

  # See Hue.BridgeWritesTest's own @receive_timeout comment: assert_receive
  # on a message that crosses a real process boundary (the stub's plug, a
  # spawned task) loses the 100 ms default under the full suite's
  # concurrency. Measured directly here: this file's setup, unguarded, flaked
  # under `mix test` (the full suite) while passing every time run alone.
  # One shared attribute so every assertion in this file inherits the margin.
  @receive_timeout 1_000

  setup context do
    name =
      Module.concat(
        Hue.BridgeAwaitTest,
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
        "type" => "device",
        "id" => "device-1",
        "metadata" => %{"name" => "Iris"},
        "services" => [%{"rid" => "light-1", "rtype" => "light"}]
      }
    ]

    start_supervised!({Bridge, name: name, client: Hue.Stub.client(resources: resources)},
      id: name
    )

    assert_receive {:hue_stub, :eventstream, stream}, @receive_timeout
    await_live(name)

    {:ok, name: name, stream: stream}
  end

  defp await_live(name, remaining \\ 200) do
    cond do
      Bridge.status(name) == :live -> :ok
      remaining == 0 -> flunk("bridge never reached :live")
      true -> Process.sleep(10) && await_live(name, remaining - 1)
    end
  end

  # Corrected from the plan's draft: it sent only `{:frame, ...}`, never
  # `:close`. Hue.Stub's chunk loop (see Hue.BridgeSubscriptionsTest's own
  # note on this) never turns a `Plug.Conn.chunk/2` call into bytes the
  # client observes until the plug function returns -- which only happens on
  # `:close` or the stub's 5-second idle timeout. Without the close, every
  # test below that pushed a frame and then awaited within a shorter budget
  # timed out: the event was queued but genuinely unobserved, not late.
  defp push(stream, resources) do
    envelope = %{
      "creationtime" => "2026-08-07T10:00:00Z",
      "id" => "event-1",
      "type" => "update",
      "data" => resources
    }

    send(stream, {:frame, "id: 1:0\ndata: #{Jason.encode!([envelope])}\n\n"})
    send(stream, :close)
  end

  test "await returns once the confirming event arrives", %{name: name, stream: stream} do
    task = Task.async(fn -> Light.set(name, "Iris", on: true, await: true) end)

    assert_receive {:hue_stub, :put, _path, _body}, @receive_timeout
    push(stream, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])

    assert :ok = Task.await(task, 2_000)
  end

  test "await does not return before the event arrives", %{name: name} do
    task =
      Task.async(fn -> Light.set(name, "Iris", on: true, await: true, await_timeout: 300) end)

    assert_receive {:hue_stub, :put, _path, _body}, @receive_timeout
    assert catch_exit(Task.await(task, 150))

    # Let the task finish so the test does not leak it.
    Task.shutdown(task, :brutal_kill)
  end

  test "await times out rather than blocking forever", %{name: name} do
    assert {:error, %Error{reason: :timeout, rid: "light-1"}} =
             Light.set(name, "Iris", on: true, await: true, await_timeout: 100)
  end

  test "await is not woken by an event for a different light", %{name: name, stream: stream} do
    task =
      Task.async(fn -> Light.set(name, "Iris", on: true, await: true, await_timeout: 300) end)

    assert_receive {:hue_stub, :put, _path, _body}, @receive_timeout
    push(stream, [%{"type" => "light", "id" => "light-99", "on" => %{"on" => true}}])

    assert {:error, %Error{reason: :timeout}} = Task.await(task, 2_000)
  end

  test "without await, set returns immediately", %{name: name} do
    {microseconds, :ok} = :timer.tc(fn -> Light.set(name, "Iris", on: true) end)
    assert microseconds < 50_000
  end

  test "a local error is returned before any waiting happens", %{name: name} do
    assert {:error, %Error{reason: :not_found}} =
             Light.set(name, "Nowhere", on: true, await: true)
  end

  test "await is not passed to the bridge as part of the body", %{name: name, stream: stream} do
    task = Task.async(fn -> Light.set(name, "Iris", on: true, await: true) end)

    assert_receive {:hue_stub, :put, _path, body}, @receive_timeout
    assert body == %{"on" => %{"on" => true}}

    push(stream, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    Task.await(task, 2_000)
  end

  # -- verifying properties the plan asked to confirm rather than assume ----

  # wait_for/2's `receive` is selective on `rid`. Whether an event for a
  # different rid is genuinely left in the mailbox -- not woken-and-discarded
  # -- only shows up when *some* subscription this process holds would have
  # delivered that event to its mailbox in the first place. A `{:rid, rid}`
  # subscription alone (all `await_write/5` sets up on its own) means an
  # event for a different rid is never dispatched to this process at all --
  # there is nothing to leave behind, so "await is not woken by a different
  # light" above cannot distinguish "skipped" from "never arrived". This adds
  # the broader `type:` subscription the moduledoc's own limitation
  # describes -- a process that was independently subscribed before calling
  # `await_write/5` -- so a light-99 event genuinely lands in the mailbox
  # ahead of the light-1 confirmation, and selective receive has something
  # real to skip over.
  test "an event for a different rid, reachable via a broader subscription, stays in the mailbox",
       %{name: name, stream: stream} do
    task =
      Task.async(fn ->
        :ok = Bridge.subscribe(name, type: :light)
        result = Light.set(name, "Iris", on: true, await: true, await_timeout: 500)

        stray =
          receive do
            message -> message
          after
            0 -> :mailbox_was_empty
          end

        {result, stray}
      end)

    assert_receive {:hue_stub, :put, _path, _body}, @receive_timeout

    push(stream, [
      %{"type" => "light", "id" => "light-99", "on" => %{"on" => true}},
      %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}
    ])

    assert {:ok, {:hue, %Event{rid: "light-99"}}} = Task.await(task, 2_000)
  end

  # await_write/5's `unsubscribe` runs from a `try/after`, so it must run
  # even when `write/4` -- not `wait_for/2` -- is what fails. Terminating only
  # the Server child (not the whole bridge) makes this deterministic rather
  # than racing a supervisor restart: Registry is an earlier :rest_for_one
  # sibling and stays up, so `subscribe/2` inside `await_write/5` still
  # succeeds (idempotently, against the subscription set up below) and
  # `write/4` is what fails, because the process `Process.whereis/1` looks
  # for is genuinely, not momentarily, gone.
  test "unsubscribe runs even when the write fails locally, clearing a pre-existing subscription",
       %{name: name} do
    assert :ok = Bridge.subscribe(name, rid: "light-1")
    assert :ok = Supervisor.terminate_child(name, Hue.Bridge.Server)

    assert {:error, %Error{reason: :not_started}} =
             Bridge.await_write(name, :light, "light-1", %{"on" => %{"on" => true}})

    assert Registry.lookup(Bridge.registry(name), {:rid, "light-1"}) == []
  end

  # Two writes to the same target collapse into one PUT (Hue.Bridge.Writes).
  # Whether both awaiting callers still get their own event, or one waits out
  # its timeout, is the thing this whole feature could get wrong. Two
  # `Task.async` callers each doing their own resolve-then-write would leave
  # the coalescing outcome to a scheduling race against the flush timer (see
  # Hue.BridgeWritesTest's own note on that race) -- this instead subscribes
  # two independent processes by rid first, exactly what `await_write/5` does
  # internally, and then issues both writes back-to-back from this one
  # process, which is what actually guarantees they land in the queue before
  # either can be sent and therefore genuinely coalesce.
  test "two writes to the same light that coalesce into one PUT still wake every waiter", %{
    name: name,
    stream: stream
  } do
    parent = self()

    waiter = fn label ->
      Task.async(fn ->
        :ok = Bridge.subscribe(name, rid: "light-1")
        send(parent, {:subscribed, label})

        receive do
          {:hue, %Event{rid: "light-1"}} -> :ok
        after
          1_000 -> :timeout
        end
      end)
    end

    task_a = waiter.(:a)
    assert_receive {:subscribed, :a}, @receive_timeout
    task_b = waiter.(:b)
    assert_receive {:subscribed, :b}, @receive_timeout

    assert :ok = Bridge.write(name, :light, "light-1", %{"on" => %{"on" => true}})
    assert :ok = Bridge.write(name, :light, "light-1", %{"dimming" => %{"brightness" => 55.0}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", body}, @receive_timeout
    assert body == %{"on" => %{"on" => true}, "dimming" => %{"brightness" => 55.0}}
    refute_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", _body}, 200

    push(stream, [
      %{
        "type" => "light",
        "id" => "light-1",
        "on" => %{"on" => true},
        "dimming" => %{"brightness" => 55.0}
      }
    ])

    assert Task.await(task_a, 2_000) == :ok
    assert Task.await(task_b, 2_000) == :ok
  end
end
