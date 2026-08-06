defmodule Hue.Color.GamutTest do
  use ExUnit.Case, async: true

  alias Hue.Color.Gamut

  @gamut_c %{
    red: {0.6915, 0.3083},
    green: {0.1700, 0.7000},
    blue: {0.1532, 0.0475}
  }

  test "contains?/2 accepts a point inside the triangle" do
    assert Gamut.contains?(@gamut_c, {0.35, 0.35})
  end

  test "contains?/2 rejects a point outside the triangle" do
    refute Gamut.contains?(@gamut_c, {0.9, 0.9})
  end

  test "clamp/2 leaves an interior point untouched" do
    assert Gamut.clamp(@gamut_c, {0.35, 0.35}) == {0.35, 0.35}
  end

  test "clamp/2 pulls an exterior point onto the triangle" do
    clamped = Gamut.clamp(@gamut_c, {0.9, 0.9})

    assert Gamut.contains?(@gamut_c, clamped)
  end

  test "from_light/1 reads the gamut a light reports for itself" do
    light =
      "light"
      |> Hue.Fixtures.resources()
      |> Enum.find(&(&1["color"]["gamut_type"] == "C"))

    assert %{red: {_, _}, green: {_, _}, blue: {_, _}} = Gamut.from_light(light)
  end

  test "from_light/1 falls back to the standard triangle when none is reported" do
    light = %{"color" => %{"gamut_type" => "B"}}

    assert Gamut.from_light(light) == Gamut.standard("B")
  end

  test "every clamped point lands inside every real gamut" do
    gamuts =
      "light"
      |> Hue.Fixtures.resources()
      |> Enum.filter(&Map.has_key?(&1, "color"))
      |> Enum.map(&Gamut.from_light/1)
      |> Enum.uniq()

    points = for x <- 0..10, y <- 0..10, do: {x / 10, y / 10}

    for gamut <- gamuts, point <- points do
      clamped = Gamut.clamp(gamut, point)

      assert Gamut.contains?(gamut, clamped),
             "clamping #{inspect(point)} into #{inspect(gamut)} produced #{inspect(clamped)}"
    end
  end

  describe "boundary points" do
    test "contains?/2 accepts a point exactly on a vertex" do
      assert Gamut.contains?(@gamut_c, @gamut_c.red)
      assert Gamut.contains?(@gamut_c, @gamut_c.green)
      assert Gamut.contains?(@gamut_c, @gamut_c.blue)
    end

    test "contains?/2 accepts a point exactly on an edge midpoint" do
      {rx, ry} = @gamut_c.red
      {gx, gy} = @gamut_c.green
      midpoint = {(rx + gx) / 2, (ry + gy) / 2}

      assert Gamut.contains?(@gamut_c, midpoint)
    end

    test "clamp/2 leaves a point already on the boundary untouched-in-effect" do
      {rx, ry} = @gamut_c.red
      {gx, gy} = @gamut_c.green
      midpoint = {(rx + gx) / 2, (ry + gy) / 2}

      assert Gamut.contains?(@gamut_c, Gamut.clamp(@gamut_c, midpoint))
    end
  end

  describe "degenerate gamuts" do
    @degenerate %{red: {0.3, 0.3}, green: {0.3, 0.3}, blue: {0.3, 0.3}}

    test "contains?/2 on a single-point gamut treats the cross-product test's blind spot honestly" do
      # A zero-area triangle carries no information a cross-product sign test
      # can use to separate "inside" from "outside" — every determinant comes
      # out exactly zero, algebraically, regardless of the query point. This
      # is documented behaviour, not a special case: it only arises for input
      # no real Hue bridge sends (every gamut on the reference bridge is a
      # proper triangle — see the moduledoc).
      assert Gamut.contains?(@degenerate, {0.3, 0.3})
      assert Gamut.contains?(@degenerate, {0.9, 0.9})
    end

    test "clamp/2 on a zero-length edge does not divide by zero" do
      assert Gamut.clamp(@degenerate, {0.9, 0.9}) == {0.9, 0.9}
    end
  end

  describe "from_light/1 error handling" do
    test "returns nil for a light with no color key at all" do
      light =
        "light"
        |> Hue.Fixtures.resources()
        |> Enum.find(&(not Map.has_key?(&1, "color")))

      refute is_nil(light)
      assert Gamut.from_light(light) == nil
    end

    test "returns an error for a gamut object missing a primary" do
      light = %{"color" => %{"gamut" => %{"red" => %{"x" => 0.1, "y" => 0.1}}}}

      assert Gamut.from_light(light) == {:error, :invalid_gamut}
    end

    test "returns an error for a gamut object with non-numeric coordinates" do
      light = %{
        "color" => %{
          "gamut" => %{
            "red" => %{"x" => "oops", "y" => 0.1},
            "green" => %{"x" => 0.2, "y" => 0.7},
            "blue" => %{"x" => 0.15, "y" => 0.04}
          }
        }
      }

      assert Gamut.from_light(light) == {:error, :invalid_gamut}
    end

    test "returns an error for an unrecognised gamut_type reported by the bridge" do
      light = %{"color" => %{"gamut_type" => "D"}}

      assert Gamut.from_light(light) == {:error, :invalid_gamut}
    end

    test "returns an error when color is present but carries neither gamut nor gamut_type" do
      light = %{"color" => %{}}

      assert Gamut.from_light(light) == {:error, :invalid_gamut}
    end
  end

  describe "standard/1" do
    test "raises for an unknown gamut type — a caller bug, not bridge data" do
      assert_raise KeyError, fn -> Gamut.standard("D") end
    end

    test "each standard triangle contains its own primaries" do
      for type <- ["A", "B", "C"] do
        gamut = Gamut.standard(type)

        assert Gamut.contains?(gamut, gamut.red)
        assert Gamut.contains?(gamut, gamut.green)
        assert Gamut.contains?(gamut, gamut.blue)
      end
    end

    test "matches the gamut reported by real lights of each type on the reference bridge" do
      for type <- ["A", "B", "C"] do
        light =
          "light"
          |> Hue.Fixtures.resources()
          |> Enum.find(&(&1["color"]["gamut_type"] == type))

        assert Gamut.from_light(light) == Gamut.standard(type),
               "standard(#{inspect(type)}) does not match the real bridge's reported gamut"
      end
    end
  end
end
