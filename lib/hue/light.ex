defmodule Hue.Light do
  @moduledoc """
  Lights, addressed by the name you gave them in the Hue app.

      {:ok, light} = Hue.Light.get(bridge, "Desk Lamp")
      :ok = Hue.Light.set(bridge, "Iris", color: "#ff8800", brightness: 40)
      :ok = Hue.Light.set(bridge, "Overhead", kelvin: 2700, transition: 400)

  Targets are names or rids, interchangeably. Names are what you have in mind;
  rids survive someone renaming the light in the Hue app.

  ## Everything before the request is local

  Resolving "Iris" to a rid, checking that Iris can do colour, and building the
  body all happen against `Hue.Bridge`'s cache. Over layer 1 the same call is
  several round trips — list the devices, find the one named Iris, walk its
  services, read the light to learn its gamut, then write. Here it is a handful
  of `:ets.lookup` calls in your own process, and the only thing that reaches
  the network is the write itself.

  ## Options

    * `:on` — boolean
    * `:brightness` — 0–100; the light must report a `dimming` key
    * `:color` — a hex string like `"#ff8800"`, or `{r, g, b}`; converted through
      this light's own gamut
    * `:kelvin` — a colour temperature, clamped to this light's own mirek schema
    * `:transition` — milliseconds for the light to take getting there
    * `:await` — wait for the event confirming the change instead of returning
      as soon as it is queued. See `Hue.Bridge.await_write/5` for what it
      consumes from your mailbox.
    * `:await_timeout` — milliseconds to wait when `await: true`. Defaults to 5 seconds.

  ## Errors, and which ones raise

  A capability the light does not have returns `{:error, %Hue.Error{}}` — the
  bulb in the socket is a fact about the house, not a bug in the code. A
  malformed option raises, because that is a bug in the code and there is
  nothing to handle at runtime. See `Hue.Bridge.Body`.
  """

  alias Hue.Bridge
  alias Hue.Bridge.Body
  alias Hue.Error

  @doc "Fetches one light by name or rid."
  @spec get(atom(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(bridge, target) when is_binary(target), do: Bridge.resolve(bridge, :light, target)

  @doc "Every light the bridge knows about."
  @spec list(atom()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(bridge), do: Bridge.list(bridge, :light)

  @doc """
  Queues a change to one light. See the moduledoc for options.

  Returns `:ok` once queued, not once applied — see `Hue.Bridge.write/4`.
  """
  @spec set(atom(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def set(bridge, target, options) when is_binary(target) and is_list(options) do
    {await?, timeout, options} = Bridge.pop_await(options)

    with {:ok, light} <- get(bridge, target),
         {:ok, body} <- Body.build(options, light) do
      Bridge.put(bridge, :light, light["id"], body, await?, timeout)
    end
  end
end
