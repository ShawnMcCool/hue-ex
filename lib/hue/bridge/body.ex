defmodule Hue.Bridge.Body do
  @moduledoc """
  Translates `set` options into a CLIP v2 request body, checking capabilities
  against the cached resource first.

  ## Two kinds of wrongness

  `brightness: "loud"` is a bug in the calling code. There is no runtime
  handling for it — only a source change — so it **raises**, at the call
  site, with a message naming the option.

  `color: "#ff8800"` sent to a white-only bulb is not a bug. It is a mismatch
  between what the code asked for and what is screwed into a lamp in the
  user's house, which the code could not have known, so it **returns**
  `{:error, %Hue.Error{reason: :not_color_capable}}`.

  ## Capabilities are checked before the request leaves

  Because `Hue.Bridge` caches every light's capabilities, this check does not
  need the bridge's opinion. That is strictly better than sending the request
  and interpreting the rejection: no round trip, and an error that names the
  light rather than quoting a CLIP description. The reference bridge has two
  lights with no `dimming` key at all, so `:not_dimmable` is a case real
  users hit, not a defensive branch.

  ## Colour and colour temperature delegate rather than duplicate

  `:color` and `:kelvin` do not check capability here. `Hue.Color.payload/2`
  and `Hue.Color.mirek_for/2` already return
  `{:error, %Hue.Error{reason: :not_color_capable, rid: ...}}` for a light
  with no `"color"` or no `"color_temperature"` key — confirmed against
  layer 1 directly before writing this module. A second check here would be
  a second place for the two to drift; there would be no way to notice a
  mismatch except by hand.
  """

  alias Hue.Color
  alias Hue.Error

  @known_options [:on, :brightness, :color, :kelvin, :transition]

  @doc """
  Builds the request body for `options` against `resource`.

  Returns `{:ok, body}`, or `{:error, %Hue.Error{}}` for a capability the
  resource does not have. Raises `ArgumentError` for a malformed option or an
  option this module does not know.

  Options are applied in the order given. The first capability failure halts
  the rest — later options are never attempted, and never reported — while a
  malformed option raises immediately regardless of position, because
  `validate_options!/1` runs before any option is translated.
  """
  @spec build(keyword(), map()) :: {:ok, map()} | {:error, Error.t()}
  def build(options, resource) when is_list(options) and is_map(resource) do
    validate_options!(options)

    Enum.reduce_while(options, {:ok, %{}}, fn option, {:ok, body} ->
      case fragment(option, resource) do
        {:ok, fragment} -> {:cont, {:ok, Map.merge(body, fragment)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp fragment({:on, value}, _resource) when is_boolean(value) do
    {:ok, %{"on" => %{"on" => value}}}
  end

  defp fragment({:on, value}, _resource) do
    raise ArgumentError, "on: expects a boolean, got: #{inspect(value)}"
  end

  defp fragment({:brightness, value}, resource) when is_number(value) do
    if Map.has_key?(resource, "dimming") do
      {:ok, %{"dimming" => %{"brightness" => value / 1}}}
    else
      {:error, %Error{reason: :not_dimmable, rid: resource["id"]}}
    end
  end

  defp fragment({:brightness, value}, _resource) do
    raise ArgumentError, "brightness: expects a number, got: #{inspect(value)}"
  end

  defp fragment({:transition, value}, _resource) when is_integer(value) and value >= 0 do
    {:ok, %{"dynamics" => %{"duration" => value}}}
  end

  defp fragment({:transition, value}, _resource) do
    raise ArgumentError,
          "transition: expects a non-negative integer of milliseconds, got: #{inspect(value)}"
  end

  defp fragment({:color, value}, resource) do
    Color.payload(value, resource)
  end

  defp fragment({:kelvin, value}, resource) when is_integer(value) and value > 0 do
    case Color.mirek_for(value, resource) do
      {:ok, mirek} -> {:ok, %{"color_temperature" => %{"mirek" => mirek}}}
      {:error, _reason} = error -> error
    end
  end

  defp fragment({:kelvin, value}, _resource) do
    raise ArgumentError, "kelvin: expects a positive integer, got: #{inspect(value)}"
  end

  # `Enum.uniq/1` before the subtraction is load-bearing, not decoration.
  # `--/2` removes only one matching element per occurrence on its right side,
  # so a duplicated *known* option — `[on: true, on: false]`, a slider firing
  # twice before the caller reads its own accumulator — leaves one copy of
  # `:on` behind after the first is cancelled out, and without the dedupe
  # that survivor is reported as "unknown option(s) [:on]": a real option,
  # called an unknown one. Deduping first means a repeated known option is
  # accepted (later values win, via `Map.merge/3` in `build/2`, the same
  # last-one-wins rule any keyword-list API applies), and only names genuinely
  # absent from `@known_options` are ever reported.
  defp validate_options!(options) do
    case Enum.uniq(Keyword.keys(options)) -- @known_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown option(s) #{inspect(unknown)}; accepted: #{inspect(@known_options)}"
    end
  end
end
