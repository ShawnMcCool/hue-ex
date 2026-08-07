defmodule Hue.Color do
  @moduledoc """
  Colour conversion for Hue lights.

  Developers think in hex, RGB, and Kelvin. Hue speaks CIE xy and mirek, and
  the representable range differs per light. This module bridges the two,
  always against the gamut of the light being addressed rather than a
  generic one — see `Hue.Color.Gamut`.

      {:ok, xy} = Hue.Color.to_xy("#ff8800", light)
      370 = Hue.Color.kelvin_to_mirek(2700)

  ## On accuracy

  `to_hex/1` is not "a shade off" — it discards luminance entirely and
  always answers with the brightest colour of the given hue. An xy pair
  carries no luminance, so converting back to RGB requires inventing one,
  and this invents the maximum (`yY: 1.0`). Two colours that differ only in
  brightness — `#000000`, `#808080`, and `#ffffff` are all achromatic, so
  they share one chromaticity, the D65 white point — convert to the exact
  same hex: **`#000000` becomes `#ffffff`**. Use it to show *which* colour
  a light is set to, never *how bright*.

  ## Bridge-data errors versus caller bugs

  A colour that cannot be represented because the *bridge* reports data this
  module cannot use — no `"color"` key, or one that cannot be turned into a
  gamut triangle (see `Hue.Color.Gamut.from_light/1`) — comes back as
  `{:error, %Hue.Error{}}`. A colour that cannot be represented because the
  *caller* passed something that was never valid — an RGB component outside
  `0..255`, a hex string with non-hex characters, a non-positive Kelvin
  value — raises, consistent with the rest of this library (see
  `Hue.Error`'s moduledoc).
  """

  alias Elixir.Color.SRGB
  alias Hue.Color.Gamut
  alias Hue.Error

  @type input :: String.t() | {0..255, 0..255, 0..255} | {:xy, number(), number()}

  # Philips's published absolute mirek bounds (roughly 2000 K-6536 K),
  # used only when a light reports "color_temperature" but its
  # "mirek_schema" is missing or incomplete. Every light on the reference
  # bridge that reports "color_temperature" also reports a full
  # "mirek_schema" (see Hue.ColorTest) — this is a defensive fallback for
  # the CLIP v2 schema's stated optionality, not something exercised by
  # real hardware.
  @fallback_mirek_minimum 153
  @fallback_mirek_maximum 500

  @doc """
  Converts a colour into an xy pair inside `light`'s gamut.

  Accepts a hex string (`"#ff8800"`), an `{r, g, b}` tuple of `0..255`
  integers, or an explicit `{:xy, x, y}` pair. Whatever the input resolves
  to is clamped into `light`'s own reported gamut (see
  `Hue.Color.Gamut.clamp/2`) — a colour outside that triangle is not merely
  approximate, it is unrepresentable on this specific light.

  Returns `{:error, %Hue.Error{reason: :not_color_capable}}` if `light` has
  no colour support at all, and `{:error, %Hue.Error{reason:
  :invalid_gamut}}` if it claims colour support but the bridge's gamut data
  could not be parsed — see `Hue.Color.Gamut.from_light/1`. Both are
  bridge-data problems, not caller bugs.

  Raises if `input` itself could never have been valid — an RGB component
  outside `0..255`, or a hex string that is not valid hex.
  """
  @spec to_xy(input(), map()) :: {:ok, Gamut.point()} | {:error, Error.t()}
  def to_xy(input, light) do
    with {:ok, point} <- to_chromaticity(input) do
      case Gamut.from_light(light) do
        nil ->
          {:error,
           %Error{
             reason: :not_color_capable,
             rid: light["id"],
             description: "this light reports no colour support"
           }}

        {:error, :invalid_gamut} ->
          {:error,
           %Error{
             reason: :invalid_gamut,
             rid: light["id"],
             description: "this light's reported gamut data could not be parsed"
           }}

        gamut ->
          {:ok, Gamut.clamp(gamut, point)}
      end
    end
  end

  @doc "Builds the CLIP v2 body for setting a colour on `light`."
  @spec payload(input(), map()) :: {:ok, map()} | {:error, Error.t()}
  def payload(input, light) do
    with {:ok, {x, y}} <- to_xy(input, light) do
      {:ok, %{"color" => %{"xy" => %{"x" => x, "y" => y}}}}
    end
  end

  @doc """
  Converts a colour temperature in Kelvin to mirek, Hue's reciprocal unit.

  Raises for a non-positive Kelvin value — dividing by zero or a negative
  temperature was never a valid call, so this is a caller bug rather than
  something to clamp away.

      iex> Hue.Color.kelvin_to_mirek(2700)
      370
  """
  @spec kelvin_to_mirek(pos_integer()) :: pos_integer()
  def kelvin_to_mirek(kelvin) when is_integer(kelvin) and kelvin > 0 do
    round(1_000_000 / kelvin)
  end

  @doc """
  Converts Kelvin to mirek and clamps it to the range `light` reports for
  itself, rather than to a hardcoded constant.

  Falls back to `#{@fallback_mirek_minimum}`-`#{@fallback_mirek_maximum}`
  (Philips's published absolute mirek bounds) only if `light` reports
  `"color_temperature"` but no `"mirek_schema"` — see the moduledoc note on
  those constants above.
  """
  @spec mirek_for(pos_integer(), map()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def mirek_for(kelvin, light) when is_integer(kelvin) and kelvin > 0 do
    case light["color_temperature"] do
      nil ->
        {:error,
         %Error{
           reason: :not_color_capable,
           rid: light["id"],
           description: "this light reports no colour temperature support"
         }}

      temperature ->
        schema = temperature["mirek_schema"] || %{}
        minimum = schema["mirek_minimum"] || @fallback_mirek_minimum
        maximum = schema["mirek_maximum"] || @fallback_mirek_maximum

        {:ok, kelvin |> kelvin_to_mirek() |> max(minimum) |> min(maximum)}
    end
  end

  @doc """
  Converts an xy pair to a hex string, for display only.

  Not a lossless round trip: an xy pair carries no luminance, so this
  invents the maximum (`yY: 1.0`) and always answers with the brightest
  colour of that hue. Every achromatic input — `{0.3127, 0.3290}`, the D65
  white point that `#000000`, any grey, and `#ffffff` all share — comes back
  `"#ffffff"`. See the moduledoc's "On accuracy" section. Good for showing
  *which* colour a light is set to; never use it to judge brightness.
  """
  @spec to_hex(Gamut.point()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_hex({x, y}) do
    case Elixir.Color.convert(%Elixir.Color.XyY{x: x, y: y, yY: 1.0}, Elixir.Color.SRGB) do
      {:ok, srgb} ->
        {:ok, SRGB.to_hex(srgb)}

      {:error, exception} ->
        {:error, Error.transport(:unknown, description: Exception.message(exception))}
    end
  end

  defp to_chromaticity({:xy, x, y}) when is_number(x) and is_number(y) do
    {:ok, {x * 1.0, y * 1.0}}
  end

  defp to_chromaticity({r, g, b}) when is_integer(r) and is_integer(g) and is_integer(b) do
    case Elixir.Color.convert([r, g, b], Elixir.Color.XyY) do
      {:ok, %Elixir.Color.XyY{x: x, y: y}} -> {:ok, {x, y}}
      # An out-of-range RGB component was never a valid call — a caller
      # bug, not a bridge-data problem, so it raises rather than returning
      # an %Hue.Error{}. See the moduledoc.
      {:error, exception} -> raise exception
    end
  end

  defp to_chromaticity("#" <> _ = hex) do
    case Elixir.Color.convert(hex, Elixir.Color.XyY) do
      {:ok, %Elixir.Color.XyY{x: x, y: y}} -> {:ok, {x, y}}
      # Same reasoning as the RGB clause above: a hex string that was never
      # valid hex is a caller bug.
      {:error, exception} -> raise exception
    end
  end
end
