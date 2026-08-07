defmodule Hue.Bridge.Graph do
  @moduledoc """
  Walks the resource graph to turn a target a human wrote into a resource this
  library can act on.

  ## Targets are names or rids, interchangeably

  Names are what a person has in mind; rids are what survives someone renaming
  a room in the Hue app. Both are accepted everywhere a target is, and **rid is
  tried first** — an exact identity match should never lose to a coincidental
  name collision.

  ## Rooms and zones are not writable

  A room has no `on` state. What responds to a write is the `grouped_light`
  service the room owns, reached through `room.services`. That indirection is
  why "dim the living room" is several lookups rather than one, and why doing
  it per call over layer 1 costs several round trips.

  Two rooms on the reference bridge are empty and expose no `grouped_light`
  service at all, so `:no_grouped_light` is a case that fires in real use rather
  than a defensive branch. It is deliberately distinct from `:not_found`: the
  room exists, and telling the caller it does not would send them looking for
  the wrong problem.
  """

  alias Hue.Bridge.Cache
  alias Hue.Error

  @doc """
  Resolves a name-or-rid to the resource itself.

  Tries the rid first; falls back to the name index. `Cache.fetch/3` can also
  fail with `:not_synced` or `:not_started` — those are not "no such rid" and
  must propagate unchanged rather than send this to the name index, which
  would only fail the same way a second time.

  ## The exact match on `:not_found` is deliberate, and currently untestable

  This matches `{:error, %Error{reason: :not_found}}` specifically, rather
  than a catch-all `{:error, _}`, on purpose: a `:not_synced` or
  `:not_started` result is a fact about the cache, not about the target, and
  should be returned as-is instead of paying for a second lookup that asks
  the same cache the same question a different way.

  But today, `Cache.fetch/3` and `Cache.fetch_by_name/3` share the exact same
  `readable/1` gate, so for `:not_synced` and `:not_started` both paths
  produce the byte-identical error — falling through to `fetch_by_name`
  unconditionally would be observably wrong only if the two functions' gating
  ever diverged. No test in this suite can currently tell "propagated
  directly" apart from "fell through and independently derived the same
  answer" without instrumenting `Cache` with a call counter, which was judged
  not worth building. **Do not simplify this to a catch-all on the strength
  of the test suite staying green if you do** — the suite cannot see the
  difference, but a future change to either function's gating could make it
  observable again, silently.
  """
  @spec resolve(Cache.table(), atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def resolve(table, type, target) when is_binary(target) do
    case Cache.fetch(table, type, target) do
      {:ok, resource} -> {:ok, resource}
      {:error, %Error{reason: :not_found}} -> Cache.fetch_by_name(table, type, target)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Resolves a room or zone target to the `grouped_light` that acts for it.

  Returns `:no_grouped_light` when the room or zone exists but owns no such
  service — an empty room, which is a real state on real bridges.
  """
  @spec grouped_light(Cache.table(), :room | :zone, String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def grouped_light(table, type, target) when type in [:room, :zone] and is_binary(target) do
    with {:ok, group} <- resolve(table, type, target),
         {:ok, rid} <- grouped_light_rid(group) do
      Cache.fetch(table, :grouped_light, rid)
    end
  end

  defp grouped_light_rid(%{"services" => services, "id" => rid}) when is_list(services) do
    services
    |> Enum.find(&match?(%{"rtype" => "grouped_light"}, &1))
    |> case do
      %{"rid" => grouped_rid} when is_binary(grouped_rid) -> {:ok, grouped_rid}
      _none -> {:error, %Error{reason: :no_grouped_light, rid: rid}}
    end
  end

  defp grouped_light_rid(%{"id" => rid}) do
    {:error, %Error{reason: :no_grouped_light, rid: rid}}
  end
end
