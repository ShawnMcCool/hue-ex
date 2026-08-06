defmodule Hue.Color.Gamut do
  @moduledoc """
  The triangle of colours a particular light can actually produce.

  Hue reports gamut per light as three CIE xy primaries, and they differ by
  model — a single bridge commonly hosts several (the reference bridge behind
  `Hue.Fixtures` has all three published types: A, B, and C). A colour outside
  a light's triangle is not merely approximate, it is unrepresentable, so it
  is projected onto the nearest point the light can actually reach.

  This is the part of colour handling the `color` dependency cannot do: its
  `Color.Gamut` maps between *named* working spaces (`:SRGB`, `:P3`, …), never
  three arbitrary xy primaries, and these triangles are per-device.

  ## The published fallback triangles

  `@standard/1`'s constants are the three triangles Philips publishes for
  gamut types A, B, and C. They are also, byte for byte (modulo trailing
  zeros), what the reference bridge behind `Hue.Fixtures` reports for real
  lights of each type — see the `standard/1` doctest-adjacent test
  `"matches the gamut reported by real lights of each type on the reference
  bridge"` in `Hue.Color.GamutTest`, which pins that comparison as a
  regression.

  ## Floating point at the boundary

  `clamp/2` projects an exterior point onto the nearest triangle *edge*.
  That projection is exact in real-number arithmetic, but IEEE 754 rounding
  in the multiply/divide chain (`closest_on_segment/2`) can land the result a
  few ULPs to either side of the edge it was projected onto. `contains?/2`
  would then read that hair-outside point as outside the very triangle it was
  just clamped into.

  `@boundary_epsilon` absorbs that: a cross-product magnitude smaller than it
  is treated as zero — "on the boundary" — rather than as a definite sign.
  Its value, `1.0e-9`, is chosen from the two things that bound it, not
  picked to make a test pass:

    * **Above the noise floor.** Every cross product here is a handful of
      additions/subtractions/multiplications of doubles whose magnitude
      stays within a small constant factor of 1 (CIE xy coordinates and their
      differences are all in `[-1, 1]`). Double rounding error per operation
      is bounded by the machine epsilon, `~2.22e-16`; accumulated over the
      few operations in `cross/3` and `closest_on_segment/2`, the residual
      stays many orders of magnitude below `1.0e-9`.
    * **Below any real colour difference.** The tightest gap between two
      distinct primaries recorded on the reference bridge is on the order of
      `1.0e-3`–`1.0e-4` (e.g. gamut B and C's red differ at the third decimal
      place). `1.0e-9` is nine orders of magnitude below that, so it can
      never mask a genuine outside point.
  """

  @type point :: {float(), float()}
  @type t :: %{red: point(), green: point(), blue: point()}

  @typedoc """
  What `from_light/1` hands back for a light that has a `"color"` key but
  data this module cannot turn into a triangle: a `"gamut"` object missing a
  primary or carrying a non-numeric coordinate, or a `"gamut_type"` this
  module does not recognise (Hue defines A, B, and C; a future bridge
  reporting something else is not a caller bug — see `standard/1`). Distinct
  from `nil`, which means the light has no colour capability at all.
  """
  @type from_light_error :: {:error, :invalid_gamut}

  # See the moduledoc's "Floating point at the boundary" section.
  @boundary_epsilon 1.0e-9

  # Published fallbacks for lights that report a gamut_type but no gamut.
  # Verified byte-for-byte (modulo trailing zeros) against every gamut the
  # reference bridge reports for real lights of each type — see the
  # moduledoc and Hue.Color.GamutTest.
  @standard %{
    "A" => %{red: {0.7040, 0.2960}, green: {0.2151, 0.7106}, blue: {0.1380, 0.0800}},
    "B" => %{red: {0.6750, 0.3220}, green: {0.4090, 0.5180}, blue: {0.1670, 0.0400}},
    "C" => %{red: {0.6915, 0.3083}, green: {0.1700, 0.7000}, blue: {0.1532, 0.0475}}
  }

  @doc """
  The published triangle for one of Hue's gamut types, `"A"`, `"B"`, or `"C"`.

  Raises for anything else. That is a caller bug, not a bridge-data problem:
  the three gamut types are a closed, documented set, and every call site in
  this library reaches this function only after checking the type is one of
  them (see `from_light/1`). A bridge reporting a type outside that set is a
  different situation — handled there, not here, as `{:error,
  :invalid_gamut}` rather than a crash.
  """
  @spec standard(String.t()) :: t()
  def standard(type), do: Map.fetch!(@standard, type)

  @doc """
  The gamut a light reports for itself.

  Three outcomes:

    * The light has an explicit `color.gamut` — its own three primaries are
      returned, provided all six coordinates are present and numeric.
    * The light has `color.gamut_type` but no `color.gamut` — the matching
      `standard/1` triangle is returned, unwrapped, exactly as `standard/1`
      returns it.
    * The light has no `"color"` key at all — `nil`. It has no colour
      capability; this is expected and common (two lights on the reference
      bridge are dimmable-only).

  Anything else under `"color"` — a malformed `gamut` object, or a
  `gamut_type` this module does not recognise — is `{:error,
  :invalid_gamut}`, never a crash and never conflated with the "no colour
  support" `nil` case. See `t:from_light_error/0`.
  """
  @spec from_light(map()) :: t() | nil | from_light_error()
  def from_light(%{"color" => color}) when is_map(color) do
    case color do
      %{"gamut" => gamut} when is_map(gamut) -> parse_gamut(gamut)
      %{"gamut_type" => type} -> standard_or_error(type)
      _ -> {:error, :invalid_gamut}
    end
  end

  def from_light(_light), do: nil

  @doc """
  Whether `point` lies inside (or on the boundary of) `gamut`.

  Uses the standard same-side cross-product test against all three edges,
  with `@boundary_epsilon` slack so a point that floating-point rounding put
  a hair outside an edge it is mathematically on still reads as inside — see
  the moduledoc.

  A degenerate, zero-area `gamut` (its three primaries collinear, or
  identical) makes every cross product exactly zero regardless of `point`,
  so this returns `true` unconditionally for such a gamut. That is an
  honest consequence of the algorithm, not a special case handled here: a
  sign test has nothing to test against on a shape with no area. No real
  Hue bridge reports a degenerate gamut (every gamut on the reference bridge
  is a proper triangle).
  """
  @spec contains?(t(), point()) :: boolean()
  def contains?(%{red: r, green: g, blue: b}, point) do
    d1 = cross(point, r, g)
    d2 = cross(point, g, b)
    d3 = cross(point, b, r)

    negative = d1 < -@boundary_epsilon or d2 < -@boundary_epsilon or d3 < -@boundary_epsilon
    positive = d1 > @boundary_epsilon or d2 > @boundary_epsilon or d3 > @boundary_epsilon

    not (negative and positive)
  end

  @doc """
  `point`, or the nearest point on `gamut`'s boundary if `point` is outside.

  An interior (or boundary) point is returned unchanged. An exterior point is
  projected onto each of the three edges in turn and the closest of the
  three projections is kept.
  """
  @spec clamp(t(), point()) :: point()
  def clamp(gamut, point) do
    if contains?(gamut, point) do
      point
    else
      %{red: r, green: g, blue: b} = gamut

      [{r, g}, {g, b}, {b, r}]
      |> Enum.map(&closest_on_segment(&1, point))
      |> Enum.min_by(&distance_squared(&1, point))
    end
  end

  defp parse_gamut(%{"red" => r, "green" => g, "blue" => b}) do
    with {:ok, red} <- point(r),
         {:ok, green} <- point(g),
         {:ok, blue} <- point(b) do
      %{red: red, green: green, blue: blue}
    else
      :error -> {:error, :invalid_gamut}
    end
  end

  defp parse_gamut(_gamut), do: {:error, :invalid_gamut}

  defp point(%{"x" => x, "y" => y}) when is_number(x) and is_number(y),
    do: {:ok, {x * 1.0, y * 1.0}}

  defp point(_coordinates), do: :error

  defp standard_or_error(type) when is_map_key(@standard, type), do: standard(type)
  defp standard_or_error(_type), do: {:error, :invalid_gamut}

  defp cross({px, py}, {ax, ay}, {bx, by}), do: (px - bx) * (ay - by) - (ax - bx) * (py - by)

  defp closest_on_segment({{ax, ay}, {bx, by}}, {px, py}) do
    abx = bx - ax
    aby = by - ay
    length_squared = abx * abx + aby * aby

    t =
      if length_squared == 0 do
        0.0
      else
        ((px - ax) * abx + (py - ay) * aby) / length_squared
      end
      |> max(0.0)
      |> min(1.0)

    {ax + t * abx, ay + t * aby}
  end

  # Squared, deliberately: Enum.min_by/2 above only needs the three
  # projections' *relative* order, and skipping the sqrt every distance
  # comparison would otherwise need is free.
  defp distance_squared({ax, ay}, {bx, by}), do: :math.pow(ax - bx, 2) + :math.pow(ay - by, 2)
end
