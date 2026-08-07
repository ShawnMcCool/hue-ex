defmodule Hue.BridgeTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error

  # Each test gets its own bridge name, which is what makes the whole layer-2
  # suite safely async: the derived server, registry, and ETS table names are
  # all distinct, so no two tests share a process or a table.
  setup context do
    name =
      Module.concat(Hue.BridgeTest, context.test |> to_string() |> String.replace(~r/\W/, "_"))

    {:ok, name: name}
  end

  defp start(name, client, options \\ []) do
    start_supervised!({Bridge, [name: name, client: client] ++ options}, id: name)
  end

  defp await_live(name, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_live(name, deadline, Bridge.status(name))
  end

  defp await_live(_name, _deadline, :live), do: :ok

  defp await_live(name, deadline, status) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("bridge never reached :live, last status #{inspect(status)}")
    else
      Process.sleep(10)
      await_live(name, deadline, Bridge.status(name))
    end
  end

  test "status is :not_started before anything is running", %{name: name} do
    assert Bridge.status(name) == :not_started
  end

  test "reads before a bridge exists are :not_started, not a crash", %{name: name} do
    assert {:error, %Error{reason: :not_started}} = Bridge.fetch(name, :light, "light-1")
  end

  test "start_link returns without waiting for the bridge", %{name: name} do
    # A stub that answers immediately (even with a failure) cannot tell
    # "returned without waiting" apart from "waited, but not for long" — a
    # fast synchronous sync and a correctly async one are indistinguishable
    # at the assertion below unless the fetch genuinely never completes.
    # See `Hue.Stub`'s `:fetch_hang` moduledoc entry for why.
    client = Hue.Stub.client(fetch_hang: true)

    assert is_pid(start(name, client))
    # The fetch this bridge is attempting can never succeed or fail — it is
    # parked in `receive do end` inside the server process — so status can
    # never reach :live or {:error, _}. Whether the assertion below observes
    # :connecting (handle_continue has not run yet) or :syncing (it has, and
    # is now blocked in the request) depends on scheduling and is not the
    # property under test; either is proof the sync did not run inside
    # init/1, because a synchronous init/1 with a hung request would have
    # kept `start/2` itself from ever returning — this line would not be
    # reached at all.
    assert Bridge.status(name) in [:connecting, :syncing]
  end

  test "the cache is seeded from one full-state request", %{name: name} do
    client = Hue.Stub.client()

    start(name, client)
    await_live(name)

    assert_received {:hue_stub, :fetch, "/clip/v2/resource"}
    refute_received {:hue_stub, :fetch, _}

    assert {:ok, %{"type" => "light"}} = Bridge.fetch(name, :light, first_light_rid())
    assert {:ok, lights} = Bridge.list(name, :light)
    assert length(lights) == 19
  end

  test "reads are :not_synced between start and the first successful fetch", %{name: name} do
    client = Hue.Stub.client(fetch_status: 503)

    start(name, client)

    assert {:error, %Error{reason: :not_synced}} = Bridge.fetch(name, :light, "light-1")
  end

  test "a failed fetch is retried until it succeeds", %{name: name} do
    client = Hue.Stub.client(fetch_failures: 2, fetch_status: 503, resources: [light("light-1")])

    start(name, client, retry_after: 10)
    await_live(name)

    assert {:ok, %{"id" => "light-1"}} = Bridge.fetch(name, :light, "light-1")
  end

  test "a failing bridge reports the reason through status", %{name: name} do
    client = Hue.Stub.client(fetch_status: 403)

    start(name, client, retry_after: 10)

    assert eventually(fn -> Bridge.status(name) == {:error, :unauthorized} end)
  end

  test "lights are readable by the name of the device that owns them", %{name: name} do
    client = Hue.Stub.client()

    start(name, client)
    await_live(name)

    {:ok, lights} = Bridge.list(name, :light)
    rid = hd(lights)["id"]
    device_name = Bridge.name_of(name, :light, rid)

    assert is_binary(device_name)
    assert {:ok, %{"id" => ^rid}} = Bridge.fetch_by_name(name, :light, device_name)
  end

  test "sync emits telemetry carrying the resource count", %{name: name} do
    handler = {__MODULE__, name}
    test = self()

    :telemetry.attach(
      handler,
      [:hue, :sync, :stop],
      fn _event, measurements, metadata, _config ->
        send(test, {:sync, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    start(name, Hue.Stub.client())
    await_live(name)

    assert_receive {:sync, %{duration: duration, resource_count: 178}, %{bridge: ^name}}
    assert duration > 0
  end

  test "two bridges in one test do not share a cache", %{name: name} do
    other = Module.concat(name, Other)

    start(name, Hue.Stub.client(resources: [light("light-1")]))
    start(other, Hue.Stub.client(resources: [light("light-2")]))

    await_live(name)
    await_live(other)

    assert {:ok, [%{"id" => "light-1"}]} = Bridge.list(name, :light)
    assert {:ok, [%{"id" => "light-2"}]} = Bridge.list(other, :light)
  end

  test "two bridges start under a real supervisor with no explicit :id", %{name: name} do
    other = Module.concat(name, Other)

    # Unlike start/3 above, this uses `{Bridge, ...}` child specs directly,
    # with no `id:` override — that override is exactly what would paper over
    # a broken `Hue.Bridge.child_spec/1`. `use Supervisor`'s generated
    # default :ids every child by module, so two of these would collide on
    # `Hue.Bridge` and this supervisor would fail to start at all unless
    # `child_spec/1` keys `:id` on `:name` the way it is documented to.
    children = [
      {Bridge, name: name, client: Hue.Stub.client(resources: [light("light-1")])},
      {Bridge, name: other, client: Hue.Stub.client(resources: [light("light-2")])}
    ]

    sup =
      start_supervised!(%{
        id: :two_bridges_no_explicit_id,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]}
      })

    assert is_pid(sup)

    await_live(name)
    await_live(other)

    assert {:ok, [%{"id" => "light-1"}]} = Bridge.list(name, :light)
    assert {:ok, [%{"id" => "light-2"}]} = Bridge.list(other, :light)
  end

  test "without_retry/1 keeps Req's own retry from multiplying a stubbed failure",
       %{name: name} do
    # Req's default retry (:safe_transient) would itself retry a 503 with
    # exponential backoff, invoking the plug again before Resource.list_all/1
    # ever returns to sync/1. With fetch_failures: 1 that second, Req-internal
    # attempt already succeeds — so if the bridge did not strip retry, this
    # single logical sync attempt would produce two fetches before the
    # server's own retry_after is ever consulted. retry_after is set far
    # longer than any delay Req's own backoff could produce for one retry, so
    # a second fetch showing up inside that window can only be Req's.
    client =
      Hue.Stub.client(
        retry: true,
        fetch_failures: 1,
        fetch_status: 503,
        resources: [light("light-1")]
      )

    start(name, client, retry_after: 10_000)

    assert_receive {:hue_stub, :fetch, "/clip/v2/resource"}, 1_000

    # Req's own backoff for one retry is ~0.9-1.0s (exponential-with-jitter,
    # retry count 0). Waiting past that — comfortably short of retry_after —
    # is what makes the check below mean something: a bare, no-wait
    # refute_received right after the line above would still pass, because
    # Req's retry has not slept its delay yet. Sleeping first is the fix, not
    # a nicety; without it this test cannot fail even when without_retry/1 is
    # deleted (measured while writing it).
    Process.sleep(1_500)

    refute_received {:hue_stub, :fetch, _}
  end

  defp light(rid), do: %{"type" => "light", "id" => rid, "on" => %{"on" => false}}

  defp first_light_rid do
    Hue.Fixtures.full_state()["data"]
    |> Enum.find(&(&1["type"] == "light"))
    |> Map.fetch!("id")
  end

  defp eventually(check, remaining \\ 100) do
    cond do
      check.() -> true
      remaining == 0 -> false
      true -> Process.sleep(10) && eventually(check, remaining - 1)
    end
  end
end
