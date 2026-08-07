defmodule Hue.Bridge.Merge do
  @moduledoc """
  Applies an eventstream delta to a cached resource.

  Maps recurse; everything else replaces.

  The distinction is load-bearing rather than stylistic. CLIP v2 events are
  partial — an observed light event carried `on: %{"on" => true}` and the two
  identity fields, and nothing else — so replacing the cached resource with the
  delta would erase the light's brightness, colour, and capabilities. Merging
  one level deep is not enough either: a delta carrying
  `%{"dimming" => %{"brightness" => 86.11}}` must leave the `min_dim_level`
  cached beside it alone.

  Lists replace because a list arriving in an event is authoritative. A
  `services` list is the complete set of that device's services, not an
  addition to it, and there is no key to merge list elements on.

  A struct replaces because it is treated as an opaque value, the same as a
  list or a scalar. Deep-merging two structs key by key produces a map
  carrying `__struct__` but not that struct's actual field set — something
  that is neither struct. Nothing arriving from the bridge is ever a struct;
  a struct reaching here means a caller passed something this function was
  not built to merge, and replacing it whole is the only treatment that does
  not silently fabricate a hybrid.
  """

  @doc """
  Deep-merges `delta` into `cached`.

      iex> Hue.Bridge.Merge.merge(
      ...>   %{"dimming" => %{"brightness" => 42.0, "min_dim_level" => 0.2}},
      ...>   %{"dimming" => %{"brightness" => 86.11}}
      ...> )
      %{"dimming" => %{"brightness" => 86.11, "min_dim_level" => 0.2}}
  """
  @spec merge(map(), map()) :: map()
  def merge(cached, delta)
      when is_map(cached) and is_map(delta) and not is_struct(cached) and not is_struct(delta) do
    Map.merge(cached, delta, fn _key, old, new -> merge_values(old, new) end)
  end

  defp merge_values(old, new)
       when is_map(old) and is_map(new) and not is_struct(old) and not is_struct(new) do
    merge(old, new)
  end

  defp merge_values(_old, new), do: new
end
