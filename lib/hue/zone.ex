defmodule Hue.Zone do
  @moduledoc """
  Zones, addressed by name.

      :ok = Hue.Zone.set(bridge, "Downstairs", brightness: 30)

  A zone is a grouping that cuts across rooms — a light belongs to exactly one
  room but to any number of zones. Everything else is `Hue.Room`: the write goes
  to the zone's `grouped_light` service, and a zone owning none returns
  `{:error, %Hue.Error{reason: :no_grouped_light}}`.
  """

  alias Hue.Error
  alias Hue.Group

  @doc "Fetches one zone by name or rid."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, target), do: Group.get(bridge, :zone, target)

  @doc "Every zone the bridge knows about."
  @spec list(atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge), do: Group.list(bridge, :zone)

  @doc "Queues a change to every light in a zone. See `Hue.Light` for options."
  @spec set(atom(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set(bridge, target, options), do: Group.set(bridge, :zone, target, options)
end
