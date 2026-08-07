defmodule Hue.Bridge.Names do
  @moduledoc """
  Builds the two name indexes `Hue.Bridge` keeps beside its resources.

  ## A light's name is not on the light

  `light.metadata` is deprecated in CLIP v2 and can hold a stale value. The name
  a user sees in the Hue app lives on the `device` that owns the light, and the
  only path from that device to the light is the device's `services` list. So
  naming is a walk, not a field read, and it is a walk this module does once per
  index rebuild rather than once per lookup.

  Rooms, zones, scenes, and smart scenes are different: those are named things
  in their own right, and their `metadata.name` is authoritative.

  `grouped_light` is deliberately unnamed. It is a service of a room or a zone,
  and it is addressed through the room or the zone — see `Hue.Bridge.Graph`.

  ## Two directions, one pass

  Both indexes come out of the same walk because they are two views of one fact:

    * `{:name, type, name} => rid` — what `Hue.Light.get(bridge, "Desk Lamp")` needs.
    * `{:rid_name, type, rid} => name` — what event dispatch needs, to answer
      "does this event concern the light someone subscribed to by name?" without
      re-walking the device graph for every event.
  """

  alias Hue.Resource

  @self_named ~w(room zone scene smart_scene device)

  @doc """
  Returns every index entry implied by `resources`, as `{key, value}` pairs
  ready for `:ets.insert/2`.

  Order is unspecified and duplicates are possible when two devices share a
  name — the later insert wins, which is the same arbitrary-but-stable choice
  the Hue app makes when you name two lights identically.
  """
  @spec entries([map()]) :: [{tuple(), String.t()}]
  def entries(resources) when is_list(resources) do
    Enum.flat_map(resources, &entries_for/1)
  end

  defp entries_for(%{"type" => "device", "id" => rid, "metadata" => %{"name" => name}} = device)
       when is_binary(rid) and is_binary(name) do
    pair(:device, rid, name) ++ service_entries(device, name)
  end

  defp entries_for(%{"type" => type, "id" => rid, "metadata" => %{"name" => name}})
       when is_binary(rid) and is_binary(name) and type in @self_named do
    pair(Resource.type(type), rid, name)
  end

  defp entries_for(_resource), do: []

  defp service_entries(%{"services" => services}, name) when is_list(services) do
    Enum.flat_map(services, fn
      %{"rid" => rid, "rtype" => rtype} when is_binary(rid) and is_binary(rtype) ->
        pair(Resource.type(rtype), rid, name)

      _other ->
        []
    end)
  end

  defp service_entries(_device, _name), do: []

  defp pair(type, rid, name) do
    [{{:name, type, name}, rid}, {{:rid_name, type, rid}, name}]
  end
end
