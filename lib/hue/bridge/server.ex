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

  ## Writes are queued here, but never run here

  `handle_cast({:write, ...})` only ever touches `Hue.Bridge.Writes` — a pure
  struct — and arms a timer. The PUT itself is sent by `send_write/4` from a
  task on `Bridge.tasks/1`, via `Task.Supervisor.async_nolink/2`. Two things
  follow from `async_nolink` specifically, not from `async/2`:

    * A write that crashed its task does not crash this server. It has no
      caller left to report to by the time it fails (`write/4` already
      returned `:ok`), so `handle_info/2` catches the `{:DOWN, ...}` and
      routes it to `report_write_failure/3` instead of letting the ordinary
      supervised-task link tear this process down over an HTTP error.
    * A write's completion arrives as the same `{ref, result}` / `{:DOWN,
      ...}` shapes the stream task already produces. `write_tasks` is a
      second map keyed by ref specifically so the two families of message
      cannot be confused for each other, matched with `is_map_key(tasks,
      ref)`. What actually keeps a write's completion from being mistaken
      for the stream's is not clause order — a `Task.Supervisor.async_nolink/2`
      reference is unique per call, so a write's ref can never equal
      `state.stream_task.ref` and never becomes a key in `write_tasks` by
      accident either. Clause order only decides that a write's completion
      is matched by *some* `handle_info/2` clause at all, rather than
      falling through to the catch-all `handle_info(_message, state)` and
      being silently ignored — which is why these clauses sit before it.

  ## `Writes.due_in/3` can answer `:never`

  Nothing is pending for a type once its last write has been taken — and
  `Process.send_after/3` raises `ArgumentError` given `:never` where it wants
  a non-negative integer. `arm_flush/2` branches on it explicitly rather than
  forwarding whatever `due_in/3` returned, because dialyzer does not catch
  this: success typing only rejects calls that can *never* succeed, and
  `due_in/3`'s return type is a union that also contains
  `non_neg_integer()`, so a probe that skips the branch and passes the value
  straight through compiles clean.

  ## A failed write has no caller left

  `write/4` already returned `:ok` by the time a write task's result is
  known, so a failure cannot be returned to anyone — it is reported instead,
  through `[:hue, :write, :failed]` telemetry and through an `error` event to
  whoever subscribed. See `report_write_failure/3`.
  """

  use GenServer

  alias Hue.Bridge
  alias Hue.Bridge.Cache
  alias Hue.Bridge.Writes
  alias Hue.Client
  alias Hue.Error
  alias Hue.Event
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
    :writes,
    backoff: nil,
    buffer: [],
    syncing?: true,
    generation: 0,
    flush_armed: MapSet.new(),
    write_tasks: %{}
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
        Keyword.get(options, :max_reconnect_after, @default_max_reconnect_after),
      writes: Writes.new()
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

  # Only the queue is touched here -- coalescing (Hue.Bridge.Writes.enqueue/3)
  # and arming a flush timer are both cheap and synchronous. The PUT itself
  # never runs in this reduction; see send_write/4 and the moduledoc's
  # "Writes are queued here, but never run here".
  @impl GenServer
  def handle_cast({:write, type, rid, body}, state) do
    {writes, collapsed} = Writes.enqueue(state.writes, {type, rid}, body)

    if collapsed > 0 do
      :telemetry.execute(
        [:hue, :write, :coalesced],
        %{collapsed_count: collapsed},
        %{bridge: state.name, type: type, rid: rid}
      )
    end

    {:noreply, arm_flush(%{state | writes: writes}, type)}
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

  # `flush_armed` is cleared before `take/3` is even asked, not after: the
  # timer that fired is the one this clears, so whatever `arm_flush/2` decides
  # below (nothing left, due -> send now, or not yet due -> arm a fresh timer)
  # starts from "no timer is currently armed for this type" rather than
  # having to reason about the one that just fired.
  def handle_info({:flush, type}, state) do
    state = %{state | flush_armed: MapSet.delete(state.flush_armed, type)}

    case Writes.take(state.writes, type, now()) do
      :empty ->
        {:noreply, state}

      {:ok, {^type, rid}, body, writes} ->
        state = %{state | writes: writes}
        {:noreply, state |> send_write(type, rid, body) |> arm_flush(type)}
    end
  end

  def handle_info({:hue_event, event}, %{syncing?: true} = state) do
    {:noreply, %{state | buffer: [event | state.buffer]}}
  end

  def handle_info({:hue_event, event}, state) do
    # Resolved before applying: a delete removes the resource and its index
    # entries, and a subscriber who asked for "Iris" by name most needs to
    # hear the event that removed Iris. The cost is symmetric — a rename
    # notifies subscribers of the old name, not the new one — which is the
    # correct reading of "which subscription does this event concern": the
    # subscriber asked about the thing they knew as Iris.
    name = Cache.name_of(state.table, event.resource_type, event.rid)

    Cache.apply_event(state.table, event)
    dispatch(state, event, name)

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

  # A write task's normal completion. `Resource.update/5` never raises for an
  # HTTP-level failure -- it returns `{:error, %Error{}}` -- and `send_write/4`
  # always asks for `return: :detailed`, so `{:ok, _data, _errors}` and
  # `{:error, %Error{}}` are the only two shapes this ever sees; `write_error/1`
  # tells them apart, including the partial-success case a bare `:ok`/`{:error,
  # _}` match would have missed. It is genuinely reachable -- exercised by
  # every test in this file that scripts `:put_errors` -- not defensive
  # boilerplate.
  def handle_info({ref, result}, %{write_tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {target, tasks} = Map.pop(tasks, ref)

    case write_error(result) do
      nil -> :ok
      %Error{} = error -> report_write_failure(state, target, error)
    end

    {:noreply, %{state | write_tasks: tasks}}
  end

  # A write task that crashed instead of returning -- a bug in this library,
  # in Req, or in the connection, rather than an HTTP error the bridge
  # answered with (that path is the clause above). `async_nolink/2` is what
  # keeps this from taking the server down with it: the crash arrives here as
  # data, not as this process's own exit.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{write_tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {target, tasks} = Map.pop(tasks, ref)
    report_write_failure(state, target, %Error{reason: exit_reason(reason)})
    {:noreply, %{state | write_tasks: tasks}}
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
  defp exit_reason({%Error{reason: reason}, _stacktrace}), do: reason
  defp exit_reason({reason, _stacktrace}) when is_atom(reason), do: reason
  defp exit_reason(reason) when is_atom(reason), do: reason
  defp exit_reason(_other), do: :unknown

  # -- writes ------------------------------------------------------------

  # A two-branch `cond` with a literal `true` fallback is an `if` in a
  # costume; written as one so the two things this function actually decides
  # -- "is a timer already armed for this type" and, only if not, "when
  # should it fire" -- read as the two questions they are rather than a
  # sequence of guard clauses.
  defp arm_flush(state, type) do
    if MapSet.member?(state.flush_armed, type) do
      state
    else
      case Writes.due_in(state.writes, type, now()) do
        :never ->
          state

        delay ->
          Process.send_after(self(), {:flush, type}, delay)
          %{state | flush_armed: MapSet.put(state.flush_armed, type)}
      end
    end
  end

  # `return: :detailed` is not optional here. In the default `:simple` mode
  # `Resource.interpret/2` matches on `%{"data" => data}` alone and discards
  # `errors` outright -- built for `update/5`'s ordinary caller, who gets
  # back the rid they already had either way and has no use for an errors
  # list `:simple` mode was never going to hand them. That silently turned a
  # write the bridge partly rejected -- HTTP 200, `data` *and* `errors` both
  # non-empty -- into a plain `:ok`. Every write this server sends needs the
  # errors list precisely because nothing else is watching for it: unlike
  # `Resource.update/5`'s direct caller, this server's caller (`write/4`) is
  # long gone by the time the response arrives.
  defp send_write(state, type, rid, body) do
    client = state.client

    task =
      Task.Supervisor.async_nolink(Bridge.tasks(state.name), fn ->
        Resource.update(client, type, rid, body, return: :detailed)
      end)

    %{state | write_tasks: Map.put(state.write_tasks, task.ref, {type, rid})}
  end

  # `nil` for a write the bridge fully accepted, an `%Error{}` otherwise.
  # `{:ok, _data, []}` and `{:ok, _data, [_ | _]}` are the two shapes
  # `return: :detailed` produces for a 2xx response; `{:error, %Error{}}` is
  # everything below the application layer -- a non-2xx status or a
  # transport failure. CLIP v2 carries no numeric error codes for either
  # case (see `Hue.Error`'s moduledoc), so a partial rejection's reason is
  # built the same way `Hue.Resource`'s own `interpret/2` already builds one
  # for a *total* failure at HTTP 200 -- `Error.transport/2` tagged
  # `:unexpected_response`, carrying whatever description the bridge sent
  # rather than a reason this library would have to invent. `error["description"]`
  # rather than a pattern match: an error entry missing that key becomes a
  # `nil` description, not a crash in the one code path with no caller left
  # to raise to.
  defp write_error({:ok, _data, []}), do: nil

  defp write_error({:ok, _data, [error | _]}) do
    Error.transport(:unexpected_response, description: error["description"])
  end

  defp write_error({:error, %Error{} = error}), do: error

  # A write has no caller waiting by the time it fails -- `write/4` already
  # returned `:ok` before the PUT was even sent, let alone answered -- so the
  # failure has exactly two ways out: telemetry, and an error event to
  # whoever subscribed. Dropping it silently would make a bridge that rejects
  # every write indistinguishable from one that accepts them.
  defp report_write_failure(state, {type, rid}, %Error{} = error) do
    :telemetry.execute(
      [:hue, :write, :failed],
      %{},
      %{bridge: state.name, type: type, rid: rid, reason: error.reason}
    )

    event = %Event{type: :error, resource_type: type, rid: rid, data: error}
    dispatch(state, event, Cache.name_of(state.table, type, rid))
  end

  defp now, do: System.monotonic_time(:millisecond)

  # -- dispatch ----------------------------------------------------------

  # Fans one event out to the three registry keys it always matches
  # (`:all`, its type, its rid) plus a fourth when the resource is named,
  # rather than to every subscriber. A process registered under
  # `{:type, :button}` is not in `Registry.dispatch/3`'s entry list for a
  # light event at all — Registry does the filtering, this function only
  # decides which keys apply.
  #
  # Subscribing under two matching keys (`:all` and `{:type, :light}`, say)
  # delivers twice for one event: this walks every matching key and dispatches
  # to each independently, with no de-duplication across them. See
  # `Hue.Bridge.subscribe/2`'s "Subscribing twice with different filters".
  defp dispatch(state, %Event{} = event, resource_name) do
    registry = Bridge.registry(state.name)
    message = {:hue, event}

    keys = [:all, {:type, event.resource_type}, {:rid, event.rid}]
    keys = if resource_name, do: [{:name, resource_name} | keys], else: keys

    Enum.each(keys, &dispatch_to_key(registry, &1, message))
  end

  defp dispatch_to_key(registry, key, message) do
    Registry.dispatch(registry, key, &send_to_each(&1, message))
  end

  defp send_to_each(subscribers, message) do
    Enum.each(subscribers, fn {pid, _value} -> send(pid, message) end)
  end
end
