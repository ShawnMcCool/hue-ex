defmodule Hue.Bridge.Writes do
  @moduledoc """
  The pending-write queue: coalescing, and Hue's per-type rate limits.

  This is the reason writes go through `Hue.Bridge`'s process while reads
  bypass it. Nothing about a read needs serialising. Coalescing and pacing are
  both statements about *all* writes together, and there is nowhere else in the
  design to make them.

  ## Coalescing merges, it does not replace

  Twenty slider drags on one light collapse to one request carrying the last
  value. Two writes setting different things — `on: true`, then
  `brightness: 40` — collapse to one request carrying both. Deep-merging the
  new body over the pending one gives both behaviours from a single rule:
  last-wins per leaf, union across keys.

  ## Pacing is per type

  Roughly 10 writes/second for lights and 1/second for grouped_lights, per
  Hue's own guidance. One request leaves per interval **per type**, not per
  pending item: three lights queued at once go out over 300 ms, and a queued
  grouped_light does not delay them.

  ## No clock

  Every function that cares about time takes `now` as a monotonic millisecond
  argument. The queue holds no timers and reads no clock, so its behaviour
  under a 1-second grouped_light interval is tested by passing `1_000`, not by
  sleeping for a second.
  """

  alias Hue.Bridge.Merge

  @light_interval 100
  @grouped_light_interval 1_000

  @intervals %{light: @light_interval, grouped_light: @grouped_light_interval}

  @type key :: {atom(), String.t()}

  @type t :: %__MODULE__{
          pending: %{key() => map()},
          order: [key()],
          collapsed: %{key() => non_neg_integer()},
          last_sent_at: %{atom() => integer()}
        }

  defstruct pending: %{}, order: [], collapsed: %{}, last_sent_at: %{}

  @doc "An empty queue."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Queues a write, merging it into whatever is already pending for that target.

  Returns the queue and the number of writes that have now been absorbed into
  this one pending body — `0` the first time, `1` the second, and so on. The
  server reports that as `[:hue, :write, :coalesced]`.
  """
  @spec enqueue(t(), key(), map()) :: {t(), non_neg_integer()}
  def enqueue(%__MODULE__{} = writes, key, body) when is_map(body) do
    case Map.fetch(writes.pending, key) do
      {:ok, pending} ->
        collapsed = Map.get(writes.collapsed, key, 0) + 1

        {%{
           writes
           | pending: Map.put(writes.pending, key, Merge.merge(pending, body)),
             collapsed: Map.put(writes.collapsed, key, collapsed)
         }, collapsed}

      :error ->
        {%{
           writes
           | pending: Map.put(writes.pending, key, body),
             order: writes.order ++ [key]
         }, 0}
    end
  end

  @doc """
  Takes the oldest pending write of `type` and records the send at `now`.

  Returns `:empty` when nothing of that type is pending. Does not check whether
  the write is due — that is `due_in/3`'s question, and the server asks it
  before calling this.
  """
  @spec take(t(), atom(), integer()) :: {:ok, key(), map(), t()} | :empty
  def take(%__MODULE__{} = writes, type, now) do
    case Enum.find(writes.order, fn {key_type, _rid} -> key_type == type end) do
      nil ->
        :empty

      key ->
        {body, pending} = Map.pop(writes.pending, key)

        {:ok, key, body,
         %{
           writes
           | pending: pending,
             order: List.delete(writes.order, key),
             collapsed: Map.delete(writes.collapsed, key),
             last_sent_at: Map.put(writes.last_sent_at, type, now)
         }}
    end
  end

  @doc """
  Milliseconds until a write of `type` may be sent, `0` if now, or `:never` if
  nothing of that type is pending.
  """
  @spec due_in(t(), atom(), integer()) :: non_neg_integer() | :never
  def due_in(%__MODULE__{} = writes, type, now) do
    if Enum.any?(writes.order, fn {key_type, _rid} -> key_type == type end) do
      case Map.fetch(writes.last_sent_at, type) do
        :error -> 0
        {:ok, sent_at} -> max(0, interval(type) - (now - sent_at))
      end
    else
      :never
    end
  end

  @doc "Every type with something pending."
  @spec pending_types(t()) :: [atom()]
  def pending_types(%__MODULE__{} = writes) do
    writes.order |> Enum.map(fn {type, _rid} -> type end) |> Enum.uniq()
  end

  # Anything Hue does not document a slower limit for is paced as a light,
  # which is the conservative direction: too slow costs latency, too fast costs
  # 429s and dropped commands.
  defp interval(type), do: Map.get(@intervals, type, @light_interval)
end
