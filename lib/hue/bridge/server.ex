defmodule Hue.Bridge.Server do
  @moduledoc """
  The process behind `Hue.Bridge`. Owns the ETS table; nothing else writes to it.

  ## What this process is, and is not, on the hot path for

  It is not on the read path at all. `Hue.Bridge.fetch/3` is an `:ets.lookup`
  in the calling process, and this server never hears about it. What the server
  owns is everything that has to be serialised: seeding the cache, merging
  events into it, and — from Task 11 — pacing writes.

  ## Startup is not allowed to depend on the bridge

  `init/1` creates the table and returns. The full fetch runs in
  `handle_continue/2`, which is after `start_link/1` has already returned to the
  supervisor. A bridge that is rebooting, unreachable, or answering 503 delays
  nothing: the consuming application boots, reads report `:not_synced`, and
  `status/1` says why.
  """

  use GenServer

  alias Hue.Bridge.Cache
  alias Hue.Client
  alias Hue.Error
  alias Hue.Resource

  @default_retry_after :timer.seconds(5)

  defstruct [:client, :name, :table, :retry_after]

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
      retry_after: Keyword.get(options, :retry_after, @default_retry_after)
    }

    Cache.new(state.table)

    {:ok, state, {:continue, :sync}}
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
  def handle_continue(:sync, state) do
    {:noreply, sync(state)}
  end

  @impl GenServer
  def handle_info(:sync, state) do
    {:noreply, sync(state)}
  end

  defp sync(state) do
    Cache.put_status(state.table, :syncing)

    started_at = System.monotonic_time()

    case Resource.list_all(state.client) do
      {:ok, resources} ->
        Cache.seed(state.table, resources)
        Cache.put_status(state.table, :live)

        :telemetry.execute(
          [:hue, :sync, :stop],
          %{duration: System.monotonic_time() - started_at, resource_count: length(resources)},
          %{bridge: state.name}
        )

        state

      {:error, %Error{reason: reason}} ->
        Cache.put_status(state.table, {:error, reason})
        Process.send_after(self(), :sync, state.retry_after)
        state
    end
  end

  @doc false
  @spec client(GenServer.server()) :: Client.t()
  def client(server), do: GenServer.call(server, :client)

  @impl GenServer
  def handle_call(:client, _from, state), do: {:reply, state.client, state}
end
