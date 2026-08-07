defmodule Hue.Room do
  @moduledoc """
  Rooms, addressed by name.

      :ok = Hue.Room.set(bridge, "Living Room", on: false)

  ## A room is not what accepts the write

  A room has no `on` state of its own. What responds is the `grouped_light`
  service the room owns, and `set/3` walks there for you. `get/2` deliberately
  returns the *room* — that is what you asked for — so if you want the group's
  current brightness, read it with `Hue.Bridge.grouped_light/3` instead.

  An empty room owns no `grouped_light` at all, and `set/3` returns
  `{:error, %Hue.Error{reason: :no_grouped_light}}` rather than inventing one.
  Two of the six rooms on the reference bridge are in exactly that state.

  Options are `Hue.Light`'s, checked against the group rather than a single
  bulb, plus `:await` and `:await_timeout` — see `Hue.Bridge.await_write/5`.
  """

  alias Hue.Error
  alias Hue.Group

  @doc "Fetches one room by name or rid."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, target), do: Group.get(bridge, :room, target)

  @doc "Every room the bridge knows about."
  @spec list(atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge), do: Group.list(bridge, :room)

  @doc "Queues a change to every light in a room. See `Hue.Light` for options."
  @spec set(atom(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set(bridge, target, options), do: Group.set(bridge, :room, target, options)
end
