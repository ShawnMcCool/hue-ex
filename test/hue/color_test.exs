defmodule Hue.ColorTest do
  use ExUnit.Case, async: true

  alias Hue.Color
  alias Hue.Color.Gamut

  setup do
    light =
      "light"
      |> Hue.Fixtures.resources()
      |> Enum.find(&(&1["color"]["gamut_type"] == "C"))

    {:ok, light: light}
  end

  test "to_xy/2 converts hex into the light's own gamut", %{light: light} do
    {:ok, {x, y}} = Color.to_xy("#ff8800", light)

    assert Gamut.contains?(Gamut.from_light(light), {x, y})
  end

  test "to_xy/2 accepts an RGB tuple", %{light: light} do
    assert {:ok, {_x, _y}} = Color.to_xy({255, 136, 0}, light)
  end

  test "to_xy/2 passes an explicit xy pair through the clamp", %{light: light} do
    assert {:ok, clamped} = Color.to_xy({:xy, 0.9, 0.9}, light)
    assert Gamut.contains?(Gamut.from_light(light), clamped)
  end

  test "to_xy/2 refuses a light with no colour support" do
    white = "light" |> Hue.Fixtures.resources() |> Enum.find(&(not Map.has_key?(&1, "color")))

    assert {:error, %Hue.Error{reason: :not_color_capable}} = Color.to_xy("#ff8800", white)
  end

  test "kelvin_to_mirek/1 inverts correctly" do
    assert Color.kelvin_to_mirek(2700) == 370
    assert Color.kelvin_to_mirek(6500) == 154
  end

  test "mirek_for/2 clamps to the light's reported schema", %{light: light} do
    schema = light["color_temperature"]["mirek_schema"]

    assert {:ok, mirek} = Color.mirek_for(1_000_000, light)
    assert mirek >= schema["mirek_minimum"]
    assert mirek <= schema["mirek_maximum"]
  end

  test "to_hex/1 round-trips approximately" do
    {:ok, hex} = Color.to_hex({0.5, 0.4})

    assert hex =~ ~r/\A#[0-9a-f]{6}\z/
    # Pinned so this test cannot pass against a to_hex/1 that ignores its
    # input: {0.5, 0.4} has one deterministic answer under the invented
    # yY: 1.0, and this is it.
    assert hex == "#ffd665"
  end

  describe "to_xy/2 against every published gamut type" do
    for type <- ["A", "B", "C"] do
      test "gamut type #{type} clamps a wide-gamut colour to its own triangle" do
        light =
          "light"
          |> Hue.Fixtures.resources()
          |> Enum.find(&(&1["color"]["gamut_type"] == unquote(type)))

        refute is_nil(light)

        {:ok, point} = Color.to_xy("#00ff00", light)

        assert Gamut.contains?(Gamut.from_light(light), point)
      end
    end
  end

  describe "to_xy/2 error handling" do
    test "distinguishes a malformed gamut from no colour support" do
      light = %{"id" => "malformed", "color" => %{"gamut_type" => "D"}}

      assert Gamut.from_light(light) == {:error, :invalid_gamut}

      assert {:error, %Hue.Error{reason: :invalid_gamut, rid: "malformed"}} =
               Color.to_xy("#ff8800", light)
    end

    test "an out-of-range RGB tuple is a caller bug, not a bridge error", %{light: light} do
      assert_raise Elixir.Color.InvalidComponentError, fn ->
        Color.to_xy({300, 0, 0}, light)
      end
    end

    test "a malformed hex string is a caller bug, not a bridge error", %{light: light} do
      assert_raise Elixir.Color.InvalidHexError, fn ->
        Color.to_xy("#zzzzzz", light)
      end
    end

    test "a malformed colour raises against a colourless light too — the caller bug does not depend on what is plugged in" do
      white = "light" |> Hue.Fixtures.resources() |> Enum.find(&(not Map.has_key?(&1, "color")))

      assert_raise Elixir.Color.InvalidComponentError, fn ->
        Color.to_xy({300, 0, 0}, white)
      end

      assert_raise Elixir.Color.InvalidHexError, fn ->
        Color.to_xy("#zzzzzz", white)
      end

      assert_raise FunctionClauseError, fn ->
        Color.to_xy("not-a-colour", white)
      end

      assert_raise FunctionClauseError, fn ->
        Color.to_xy(42, white)
      end
    end

    test "a well-formed colour against a colourless light still reports :not_color_capable" do
      white = "light" |> Hue.Fixtures.resources() |> Enum.find(&(not Map.has_key?(&1, "color")))

      assert {:error, %Hue.Error{reason: :not_color_capable}} = Color.to_xy("#ff8800", white)
      assert {:error, %Hue.Error{reason: :not_color_capable}} = Color.to_xy({255, 136, 0}, white)

      assert {:error, %Hue.Error{reason: :not_color_capable}} =
               Color.to_xy({:xy, 0.4, 0.4}, white)
    end
  end

  describe "payload/2" do
    test "builds the CLIP v2 body for a colour write", %{light: light} do
      assert {:ok, %{"color" => %{"xy" => %{"x" => x, "y" => y}}}} =
               Color.payload("#ff8800", light)

      assert is_float(x)
      assert is_float(y)
    end

    test "propagates a to_xy/2 :not_color_capable failure" do
      white = "light" |> Hue.Fixtures.resources() |> Enum.find(&(not Map.has_key?(&1, "color")))

      assert {:error, %Hue.Error{reason: :not_color_capable}} = Color.payload("#ff8800", white)
    end

    test "propagates a to_xy/2 :invalid_gamut failure" do
      light = %{"id" => "malformed", "color" => %{"gamut_type" => "D"}}

      assert {:error, %Hue.Error{reason: :invalid_gamut}} = Color.payload("#ff8800", light)
    end
  end

  describe "kelvin_to_mirek/1 edge cases" do
    test "raises for zero" do
      assert_raise FunctionClauseError, fn -> Color.kelvin_to_mirek(0) end
    end

    test "raises for a negative value" do
      assert_raise FunctionClauseError, fn -> Color.kelvin_to_mirek(-2700) end
    end

    test "raises for a non-integer" do
      assert_raise FunctionClauseError, fn -> Color.kelvin_to_mirek(2700.0) end
    end
  end

  describe "mirek_for/2" do
    test "reports :not_color_capable for a light with no colour temperature support at all" do
      light = %{"id" => "no-ct"}

      assert {:error, %Hue.Error{reason: :not_color_capable, rid: "no-ct"}} =
               Color.mirek_for(2700, light)
    end

    test "falls back to the named default bounds when a light reports color_temperature but no mirek_schema" do
      light = %{"id" => "no-schema", "color_temperature" => %{}}

      assert {:ok, mirek} = Color.mirek_for(1_000_000, light)
      assert mirek == 153

      assert {:ok, mirek} = Color.mirek_for(1, light)
      assert mirek == 500
    end
  end

  describe "to_hex/1" do
    test "a fully saturated primary round-trips back to itself" do
      # The sRGB green primary's chromaticity converts to full-luminance
      # green both ways, so this is the one case where "not a lossless
      # round trip" is, in practice, lossless.
      assert {:ok, "#00ff00"} = Color.to_hex({0.30, 0.60})
    end

    test "the same chromaticity produces the same hex at every luminance" do
      # #000000, a mid grey, and #ffffff are all achromatic — three
      # different luminances sharing one chromaticity, the D65 white
      # point. to_hex/1 has no luminance channel to distinguish them, so
      # it must answer identically for all three. Deriving the inputs
      # through the real hex -> xy path (rather than hand-picking two xy
      # literals) is what pins the *documented* collapse instead of some
      # other coincidental equality.
      {:ok, dark} = Elixir.Color.convert("#000000", Elixir.Color.XyY)
      {:ok, mid} = Elixir.Color.convert("#808080", Elixir.Color.XyY)

      assert {:ok, dark_hex} = Color.to_hex({dark.x, dark.y})
      assert {:ok, mid_hex} = Color.to_hex({mid.x, mid.y})

      assert dark_hex == mid_hex
    end

    test "genuinely different chromaticities produce different hex" do
      assert {:ok, red} = Color.to_hex({0.64, 0.33})
      assert {:ok, green} = Color.to_hex({0.30, 0.60})

      assert red != green
    end

    test "black in means white out — the documented surprise" do
      {:ok, %Elixir.Color.XyY{x: x, y: y}} = Elixir.Color.convert("#000000", Elixir.Color.XyY)

      assert {:ok, "#ffffff"} = Color.to_hex({x, y})
    end
  end

  describe "clamping is safe for every colour on every real fixture light" do
    test "any input colour clamped for any real fixture light lands inside that light's gamut" do
      lights =
        "light"
        |> Hue.Fixtures.resources()
        |> Enum.filter(&Map.has_key?(&1, "color"))

      inputs = [
        "#ff0000",
        "#00ff00",
        "#0000ff",
        "#ffffff",
        "#000000",
        {255, 0, 0},
        {0, 255, 0},
        {0, 0, 255},
        {:xy, 0.0, 0.0},
        {:xy, 1.0, 1.0},
        {:xy, 0.9, 0.1}
      ]

      for light <- lights, input <- inputs do
        assert {:ok, point} = Color.to_xy(input, light)

        assert Gamut.contains?(Gamut.from_light(light), point),
               "clamping #{inspect(input)} for #{light["id"]} produced #{inspect(point)}, " <>
                 "outside #{inspect(Gamut.from_light(light))}"
      end
    end
  end
end
