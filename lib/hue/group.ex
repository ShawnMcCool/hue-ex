defmodule Hue.Group do
  @moduledoc false
  # Shared implementation for Hue.Room and Hue.Zone. Both are the same
  # operation against a different resource type: resolve the group, walk to the
  # grouped_light service that acts for it, write there.
  #
  # Not public, because "Hue.Group.set(bridge, :room, target, options)" is a
  # worse API than two six-line modules that say which one you mean.

  alias Hue.Bridge
  alias Hue.Bridge.Body
  alias Hue.Error

  @spec get(atom(), :room | :zone, String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, type, target), do: Bridge.resolve(bridge, type, target)

  @spec list(atom(), :room | :zone) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge, type), do: Bridge.list(bridge, type)

  @spec set(atom(), :room | :zone, String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set(bridge, type, target, options) do
    {await?, timeout, options} = Bridge.pop_await(options)

    with {:ok, grouped} <- Bridge.grouped_light(bridge, type, target),
         {:ok, body} <- Body.build(options, grouped) do
      Bridge.put(bridge, :grouped_light, grouped["id"], body, await?, timeout)
    end
  end
end
