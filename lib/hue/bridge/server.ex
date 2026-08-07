defmodule Hue.Bridge.Server do
  @moduledoc """
  The process behind `Hue.Bridge`. Owns the ETS table; nothing else writes to it.

  ## What this process is, and is not, on the hot path for

  It is not on the read path at all. `Hue.Bridge.fetch/3` is an `:ets.lookup`
  in the calling process, and this server never hears about it. What the server
  owns is everything that has to be serialised: seeding the cache, merging
  events into it, and — from Task 11 — pacing writes.

  ## Startup is not allowed to depend on the bridge

  `init/1` creates the table and returns. Everything else runs in
  `handle_continue/2`, after `start_link/1` has already returned to the
  supervisor. A bridge that is rebooting, unreachable, or answering 503 delays
  nothing: the consuming application boots, reads report `:not_synced`, and
  `status/1` says why.

  ## The connect sequence, and why it is in this order

      open the stream → buffer what it delivers → fetch → seed → replay buffer → live

  Fetching first and then opening the stream loses every change that happens in
  between. Opening first and replaying the buffer on top of the seed applies
  each change after the state it modifies, which is the only ordering that ends
  correct.

  This narrows the window without closing it. `Hue.Events.stream/2` connects
  lazily on first enumeration, so there is a moment between "the task started"
  and "the socket is open" that this process cannot observe. It is smaller than
  the fetch it replaces — request headers against 154 KB of response — and
  narrowing it costs nothing, but it is a narrowing and not a guarantee.

  ## Reconnect always refetches

  No `Last-Event-ID` resumption. The alternative buys 154 KB on an event that
  should be rare, and pays for it with a class of bug in which resumption
  appears to have succeeded while events were in fact missed.

  ## A dead stream is this library's characteristic failure

  It is silent: every read keeps answering, and every answer is quietly
  stale. No keepalive arrives on an idle stream (see `Hue.Events`'s "Silence
  is not evidence of anything"), so an idle stream and a dead one are
  protocol-indistinguishable — nothing on the wire tells them apart.
  `[:hue, :stream, :disconnected]` is the only thing that reveals a drop, which
  is why every path that ends the stream task, cleanly closed or crashed
  alike, is routed through `disconnected/2`.

  ## Why a fetch retry carries a generation number

  A fetch failure schedules its own retry (`sync_failed/2`), independently of
  whatever the stream is doing. That is deliberate: a fetch answered 503 while
  the stream is fine should retry the fetch alone, not tear down a perfectly
  good connection and its buffer along with it.

  But the *stream* can also disconnect while that retry is still pending —
  the fetch and the stream fail for unrelated reasons, on their own schedules.
  Left unguarded, the stale retry would eventually fire, seed from state that
  `disconnected/2` already cleared, and declare `:live` with no stream task
  running at all, while the real reconnect cycle `disconnected/2` scheduled is
  still in flight behind it. `generation` is incremented once per disconnect
  and stamped on every scheduled retry; `handle_info/2` drops any retry whose
  stamp does not match the current one, which is the only place this needs to
  exist — `:reconnect` always starts a fresh cycle and needs no such guard.
  """

  use GenServer

  alias Hue.Bridge
  alias Hue.Bridge.Cache
  alias Hue.Client
  alias Hue.Error
  alias Hue.Resource

  @default_retry_after :timer.seconds(5)
  @default_reconnect_after :timer.seconds(1)
  @default_max_reconnect_after :timer.seconds(60)

  defstruct [
    :client,
    :name,
    :table,
    :retry_after,
    :reconnect_after,
    :max_reconnect_after,
    :stream_task,
    :disconnected_at,
    :live_since,
    backoff: nil,
    buffer: [],
    syncing?: true,
    generation: 0
  ]

  @doc false
  def start_link(options) do
    {name, options} = Keyword.pop!(options, :server_name)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl GenServer
  def init(options) do
    state = %__MODULE__{
      client: without_retry(Keyword.fetch!(options, :client)),
      name: Keyword.fetch!(options, :name),
      table: Keyword.fetch!(options, :table),
      retry_after: Keyword.get(options, :retry_after, @default_retry_after),
      reconnect_after: Keyword.get(options, :reconnect_after, @default_reconnect_after),
      max_reconnect_after:
        Keyword.get(options, :max_reconnect_after, @default_max_reconnect_after)
    }

    Cache.new(state.table)

    {:ok, state, {:continue, :connect}}
  end

  # Req retries a GET answered 503 up to three times with exponential backoff by
  # default, under `:safe_transient`. Left on, that sits *underneath* this
  # server's own `retry_after` and reconnect backoff: one scheduled attempt
  # becomes up to four round trips over several seconds, and two uncoordinated
  # backoff layers compound. Layer 1 deliberately invents no retry policy and
  # leaves it to the caller (see `Hue.Client`) — this server is that caller, and
  # it owns reconnect timing, so it should be the only source of it.
  #
  # This also makes tests and production agree: `Hue.Stub` disables retry so
  # scripted failure counts are not silently consumed, and without this the
  # suite would model a bridge that fails once where the real one fails four
  # times per logical attempt.
  defp without_retry(%Client{} = client) do
    %{client | req: Req.merge(client.req, retry: false)}
  end

  @impl GenServer
  def handle_continue(:connect, state) do
    {:noreply, state |> open_stream() |> sync()}
  end

  @impl GenServer
  def handle_info({:sync, generation}, %{generation: generation} = state) do
    {:noreply, sync(state)}
  end

  # A `:sync` retry scheduled by `sync_failed/2` outlives the fetch failure it
  # was scheduled for whenever the *stream* also disconnects before the timer
  # fires: `disconnected/2` bumps `generation`, so a retry tagged with the old
  # one arrives after the state it was meant to complete no longer exists.
  # Letting it run anyway would call `seed/3` with `state.buffer` already
  # cleared by `disconnected/2` — silently losing whatever was buffered against
  # the now-dead stream — and would report `:live` with no stream task running
  # at all, while the real reconnect cycle is still in flight behind it.
  def handle_info({:sync, _stale_generation}, state), do: {:noreply, state}

  def handle_info(:reconnect, state), do: {:noreply, state |> open_stream() |> sync()}

  def handle_info({:hue_event, event}, %{syncing?: true} = state) do
    {:noreply, %{state | buffer: [event | state.buffer]}}
  end

  def handle_info({:hue_event, event}, state) do
    Cache.apply_event(state.table, event)
    {:noreply, state}
  end

  # `Task.Supervisor.async_nolink` sends this when the stream ends without
  # raising -- the bridge closed the connection cleanly. Elixir's own
  # documentation for `async_nolink/3` is explicit that this is not the only
  # notification of that exit: "regardless of how the task ... terminates, the
  # caller's process will always receive a `:DOWN` message ... If the task
  # terminates normally, the reason in the `:DOWN` message will be `:normal`."
  # That `:DOWN` message is handled below and would, on its own, still trigger
  # `disconnected/2` and still reconnect -- deleting this clause does not stop
  # reconnection, which is why a test that only asserts "did it reconnect"
  # cannot tell these two clauses apart, and is not the test to write here.
  # What this clause actually buys is a *reason worth reading*: `:closed`
  # instead of the ambiguous `:normal` a bare `:DOWN` would report, which
  # matters because `[:hue, :stream, :disconnected]`'s `reason` is the only
  # signal this library gives for its characteristic silent failure. Matching
  # `%Task{ref: ref}` on this state's own stream task rather than any bare
  # `{ref, result}` matters for a different reason: Task 12 puts write tasks
  # on the same `Task.Supervisor`, and their completions must not be mistaken
  # for a stream ending.
  def handle_info({ref, _result}, %{stream_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, disconnected(state, :closed)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{stream_task: %Task{ref: ref}} = state) do
    {:noreply, disconnected(state, exit_reason(reason))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec client(GenServer.server()) :: Client.t()
  def client(server), do: GenServer.call(server, :client)

  @impl GenServer
  def handle_call(:client, _from, state), do: {:reply, state.client, state}

  # -- connect ---------------------------------------------------------------

  defp open_stream(state) do
    server = self()

    task =
      Task.Supervisor.async_nolink(Bridge.tasks(state.name), fn ->
        state.client
        |> Hue.Events.stream()
        |> Enum.each(&send(server, {:hue_event, &1}))
      end)

    %{state | stream_task: task, syncing?: true, buffer: []}
  end

  defp sync(state) do
    Cache.put_status(state.table, :syncing)
    started_at = System.monotonic_time()

    case Resource.list_all(state.client) do
      {:ok, resources} -> seed(state, resources, started_at)
      {:error, %Error{reason: reason}} -> sync_failed(state, reason)
    end
  end

  defp seed(state, resources, started_at) do
    Cache.seed(state.table, resources)

    # Oldest first: the buffer is built by prepending.
    state.buffer
    |> Enum.reverse()
    |> Enum.each(&Cache.apply_event(state.table, &1))

    Cache.put_status(state.table, :live)

    :telemetry.execute(
      [:hue, :sync, :stop],
      %{duration: System.monotonic_time() - started_at, resource_count: length(resources)},
      %{bridge: state.name}
    )

    :telemetry.execute(
      [:hue, :stream, :connected],
      %{downtime: downtime(state)},
      %{bridge: state.name}
    )

    %{
      state
      | syncing?: false,
        buffer: [],
        disconnected_at: nil,
        live_since: System.monotonic_time(:millisecond)
    }
  end

  defp sync_failed(state, reason) do
    Cache.put_status(state.table, {:error, reason})
    Process.send_after(self(), {:sync, state.generation}, state.retry_after)
    state
  end

  # -- disconnect ------------------------------------------------------------

  defp disconnected(state, reason) do
    :telemetry.execute(
      [:hue, :stream, :disconnected],
      %{},
      %{bridge: state.name, reason: reason}
    )

    Cache.put_status(state.table, {:error, reason})

    backoff = next_backoff(state)
    Process.send_after(self(), :reconnect, backoff)

    %{
      state
      | stream_task: nil,
        syncing?: true,
        buffer: [],
        backoff: backoff,
        disconnected_at: state.disconnected_at || System.monotonic_time(:millisecond),
        generation: state.generation + 1
    }
  end

  # Whether *this* backoff computation grows the previous value or resets to
  # the base depends on how long the stream that just died had actually been
  # live -- not, as an earlier version of this function assumed, on whether
  # `seed/3` had run since the last disconnect.
  #
  # That assumption was wrong, and deterministically so: `open_stream/1` and
  # `sync/1` run back to back inside one `handle_continue`/`handle_info(:reconnect,
  # ...)` reduction, so when the fetch succeeds, `seed/3` always completes --
  # and, in the version this replaces, always reset `backoff` to `nil` -- before
  # this GenServer can process *any* message from the stream task it just
  # spawned, including that task immediately crashing (`eventstream_status: 403`
  # with an otherwise-working fetch is exactly this: the fetch succeeds every
  # cycle, the stream never does). Measured directly against this bug: reconnect
  # gaps stayed pinned at the base `reconnect_after` for eight consecutive
  # cycles, never doubling once. A working fetch is not evidence the stream is
  # healthy, so it must not be what resets the pacing that exists specifically
  # to protect the stream.
  #
  # `live_since` is recorded by `seed/3` on every successful sync, reconnect or
  # not, and is the only evidence available of how long the stream that just
  # ended had actually been up. If that was at least one full `reconnect_after`,
  # this failure reads as a fresh problem on an otherwise-working connection,
  # and backoff resets to the base rather than carrying over a multiplier from
  # an unrelated past flapping episode. Otherwise it grows, because the stream
  # that just died had not been alive long enough to count as recovered.
  defp next_backoff(state) do
    if live_long_enough?(state) do
      state.reconnect_after
    else
      case state.backoff do
        nil -> state.reconnect_after
        previous -> min(previous * 2, state.max_reconnect_after)
      end
    end
  end

  defp live_long_enough?(%{live_since: nil}), do: false

  defp live_long_enough?(state) do
    System.monotonic_time(:millisecond) - state.live_since >= state.reconnect_after
  end

  defp downtime(%{disconnected_at: nil}), do: 0
  defp downtime(state), do: System.monotonic_time(:millisecond) - state.disconnected_at

  # `Hue.Events.stream/2` raises `Hue.Error` on a refused connection (403,
  # say) and on a transport failure while streaming; `async_nolink` wraps
  # whatever a crashing task raised as `{exception, stacktrace}`, so the
  # `Hue.Error` case has to be unwrapped explicitly or it falls to the last,
  # catch-all clause and every refusal reads as `:unknown`.
  defp exit_reason({%Error{reason: reason}, _stacktrace}) when not is_nil(reason), do: reason
  defp exit_reason({reason, _stacktrace}) when is_atom(reason), do: reason
  defp exit_reason(reason) when is_atom(reason), do: reason
  defp exit_reason(_other), do: :unknown
end
