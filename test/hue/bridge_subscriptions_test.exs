defmodule Hue.BridgeSubscriptionsTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Event

  # See Hue.BridgeStreamTest's own @receive_timeout comment: assert_receive on
  # a message that crosses a real process boundary (the stub's plug, or this
  # server's own dispatch) loses ExUnit's 100 ms default under the full
  # suite's `max_cases` concurrency. Measured there at a 16% flake rate before
  # the bump; this file reuses the same margin rather than a smaller literal.
  @receive_timeout 1_000

  # refute_receive with no window is vacuous -- it passes because the thing
  # has not happened *yet*. This gives a broken filter time to be wrong,
  # without paying @receive_timeout on every negative assertion.
  @refute_window 300

  @resources [
    %{"type" => "light", "id" => "light-1", "on" => %{"on" => false}},
    %{"type" => "light", "id" => "light-2", "on" => %{"on" => false}},
    %{"type" => "button", "id" => "button-1"},
    %{
      "type" => "device",
      "id" => "device-1",
      "metadata" => %{"name" => "Iris"},
      "services" => [%{"rid" => "light-1", "rtype" => "light"}]
    }
  ]

  setup context do
    name =
      Module.concat(
        Hue.BridgeSubscriptionsTest,
        context.test |> to_string() |> String.replace(~r/\W/, "_")
      )

    {:ok, name: name}
  end

  # `Hue.Stub`'s eventstream connection cannot deliver a frame while it stays
  # open -- Req's function-plug adapter only turns accumulated
  # `Plug.Conn.chunk/2` calls into messages once the plug *returns*, and the
  # stub's chunk loop blocks until `:close`. Measured directly (Task 8): a
  # frame sent without a following close was still unobserved 1.5 seconds
  # later. So every test here closes right after sending, which is a clean
  # disconnect and schedules a reconnect -- every bridge below starts with a
  # generous `reconnect_after` unless a test deliberately wants the reconnect
  # to happen within the test's own timeout budget.
  defp deliver_and_close(stream, iodata) do
    send(stream, {:frame, iodata})
    send(stream, :close)
  end

  defp envelope(type, resources) do
    %{
      "creationtime" => "2026-08-07T10:00:00Z",
      "id" => "event-1",
      "type" => Atom.to_string(type),
      "data" => resources
    }
  end

  # One frame carries many envelopes, and each envelope carries many resource
  # deltas -- that is the real wire shape (see Hue.Events), and it is also
  # what lets a single delivery carry more than one logical event without
  # needing a second stub connection: the server processes each resulting
  # `Hue.Event` as its own `handle_info`, in the order the envelopes and their
  # resources appear.
  defp frame_of_envelopes(envelopes) do
    "id: 1:0\ndata: #{Jason.encode!(envelopes)}\n\n"
  end

  defp frame(resources), do: frame(:update, resources)
  defp frame(type, resources), do: frame_of_envelopes([envelope(type, resources)])

  defp start(name, options \\ []) do
    resources = Keyword.get(options, :resources, @resources)
    reconnect_after = Keyword.get(options, :reconnect_after, 10_000)

    client = Hue.Stub.client(resources: resources)

    start_supervised!(
      {Bridge, name: name, client: client, reconnect_after: reconnect_after},
      id: name
    )

    assert_receive {:hue_stub, :eventstream, stream}, @receive_timeout
    await_live(name)

    stream
  end

  defp await_live(name), do: assert_eventually(fn -> Bridge.status(name) == :live end)

  defp assert_eventually(check, remaining \\ 200) do
    cond do
      check.() -> true
      remaining == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && assert_eventually(check, remaining - 1)
    end
  end

  test "an unfiltered subscription receives everything", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name)

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    )

    assert_receive {:hue, %Event{resource_type: :light, rid: "light-1"}}, @receive_timeout
  end

  test "a type subscription receives its type", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, type: :button)

    deliver_and_close(
      stream,
      frame([
        %{"type" => "button", "id" => "button-1", "button" => %{"last_event" => "initial_press"}}
      ])
    )

    assert_receive {:hue, %Event{resource_type: :button, rid: "button-1"}}, @receive_timeout
  end

  test "a type subscription is not woken by other types", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, type: :button)

    deliver_and_close(
      stream,
      frame([
        %{"type" => "light", "id" => "light-1", "on" => %{"on" => true}},
        %{"type" => "light", "id" => "light-2", "on" => %{"on" => true}}
      ])
    )

    refute_receive {:hue, _}, @refute_window
  end

  test "a name subscription receives the light that device names", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, name: "Iris")

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    )

    assert_receive {:hue, %Event{rid: "light-1"}}, @receive_timeout
  end

  test "a name subscription is not woken by a different light", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, name: "Iris")

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-2", "on" => %{"on" => true}}])
    )

    refute_receive {:hue, _}, @refute_window
  end

  test "a rid subscription receives that rid", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, rid: "light-2")

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-2", "on" => %{"on" => true}}])
    )

    assert_receive {:hue, %Event{rid: "light-2"}}, @receive_timeout
  end

  test "a name subscriber still hears the delete that removes the name", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, name: "Iris")

    deliver_and_close(
      stream,
      frame(:delete, [%{"type" => "light", "id" => "light-1"}])
    )

    assert_receive {:hue, %Event{type: :delete, rid: "light-1"}}, @receive_timeout
  end

  # This is the second claim the plan's "Names are resolved before the event
  # is applied" paragraph makes and the one no test in the base set covers:
  # after a rename, subscribers of the *old* name stop matching. Both the
  # rename and the light event that follows it are put in one frame (two
  # envelopes, one delivery), which avoids needing a second stub connection
  # -- and, just as importantly, avoids a reconnect refetch resetting the
  # device's name back to "Iris" before the second event is even sent, which
  # would happen if these were two separate deliver_and_close calls (the stub
  # always reseeds from its static `resources` list on reconnect).
  test "a rename notifies the old name, and the event that follows does not", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, name: "Iris")

    deliver_and_close(
      stream,
      frame_of_envelopes([
        envelope(:update, [
          %{"type" => "device", "id" => "device-1", "metadata" => %{"name" => "Reading Lamp"}}
        ]),
        envelope(:update, [%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
      ])
    )

    assert_receive {:hue, %Event{resource_type: :device, rid: "device-1"}}, @receive_timeout
    refute_receive {:hue, %Event{resource_type: :light}}, @refute_window
  end

  test "unsubscribing stops delivery", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name)
    :ok = Bridge.unsubscribe(name)

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    )

    refute_receive {:hue, _}, @refute_window
  end

  test "a subscriber to two matching keys is dispatched to twice", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name)
    :ok = Bridge.subscribe(name, type: :light)

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    )

    assert_receive {:hue, %Event{resource_type: :light, rid: "light-1"}}, @receive_timeout
    assert_receive {:hue, %Event{resource_type: :light, rid: "light-1"}}, @receive_timeout
    refute_receive {:hue, _}, @refute_window
  end

  # A `:duplicate` registry never refuses a second `register/3` call for the
  # same key from the same process -- see the point-2 finding this fix comes
  # from -- so idempotence has to be `subscribe/2`'s own job. This is the
  # positive half of that: one subscription in, one message out.
  test "subscribing twice with the same filter is a no-op", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, type: :light)
    :ok = Bridge.subscribe(name, type: :light)

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    )

    assert_receive {:hue, %Event{resource_type: :light, rid: "light-1"}}, @receive_timeout
    # A bare refute_receive is vacuous -- it passes because a second message
    # has not arrived *yet*. @refute_window gives a broken idempotence check
    # (one that still registered a second entry) time to be wrong.
    refute_receive {:hue, _}, @refute_window
  end

  test "a single unsubscribe after a double subscribe stops delivery completely", %{name: name} do
    stream = start(name)
    :ok = Bridge.subscribe(name, type: :light)
    :ok = Bridge.subscribe(name, type: :light)
    :ok = Bridge.unsubscribe(name, type: :light)

    # Genuinely gone, not merely down to one entry -- the double subscribe
    # above must not have left a second, orphaned registration behind.
    assert Registry.lookup(Bridge.registry(name), {:type, :light}) == []

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    )

    refute_receive {:hue, _}, @refute_window
  end

  # Registry.dispatch/3 sends to whatever is registered when the event
  # arrives; a subscriber that has already died between registering and the
  # event firing must not crash the dispatching server. This closes the
  # stream twice on purpose: the first delivery is the control -- proof the
  # subscription genuinely worked before the subscriber died -- and the
  # second, sent only after the subscriber is confirmed dead, is what proves
  # dispatch survives a registry entry whose process is gone. The reconnect
  # `deliver_and_close/2` triggers after the first close is not a nuisance
  # here, it is the fresh connection the second delivery needs.
  test "a dead subscriber is cleaned up without the server noticing", %{name: name} do
    stream = start(name, reconnect_after: 200)
    server_pid = Process.whereis(Bridge.server(name))
    test = self()

    subscriber =
      spawn(fn ->
        :ok = Bridge.subscribe(name)
        send(test, :subscribed)

        receive do
          {:hue, _event} = message -> send(test, {:forwarded, message})
        end

        Process.sleep(:infinity)
      end)

    assert_receive :subscribed, @receive_timeout

    deliver_and_close(
      stream,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => true}}])
    )

    assert_receive {:forwarded, {:hue, %Event{rid: "light-1"}}}, @receive_timeout

    assert_receive {:hue_stub, :eventstream, stream2}, @receive_timeout
    await_live(name)

    Process.exit(subscriber, :kill)
    Process.sleep(20)

    deliver_and_close(
      stream2,
      frame([%{"type" => "light", "id" => "light-1", "on" => %{"on" => false}}])
    )

    assert_eventually(fn -> Bridge.status(name) == :live end)
    assert Process.whereis(Bridge.server(name)) == server_pid
  end

  test "subscribing to a bridge that is not running is an error" do
    assert {:error, %Error{reason: :not_started}} =
             Bridge.subscribe(Hue.BridgeSubscriptionsTest.Nowhere)
  end

  test "unsubscribing from a bridge that is not running does not raise" do
    assert :ok = Bridge.unsubscribe(Hue.BridgeSubscriptionsTest.NowhereEither)
  end

  test "a filter combining two keys raises rather than silently picking one" do
    assert_raise ArgumentError, fn ->
      Bridge.subscribe(Hue.BridgeSubscriptionsTest.Nowhere, type: :light, name: "Iris")
    end
  end
end
