defmodule Hue.FixturesTest do
  use ExUnit.Case, async: true

  test "the full state holds the recorded resource population" do
    data = Hue.Fixtures.full_state()["data"]
    assert length(data) == 178
    assert data |> Enum.map(& &1["type"]) |> Enum.uniq() |> length() == 22
  end

  test "the recorded capability spread is preserved" do
    lights = Hue.Fixtures.resources("light")
    assert length(lights) == 19
    assert Enum.count(lights, &(not Map.has_key?(&1, "dimming"))) == 2
    assert Enum.count(lights, &Map.has_key?(&1, "color")) == 15
  end

  test "all three gamut types are represented" do
    types =
      "light"
      |> Hue.Fixtures.resources()
      |> Enum.filter(&Map.has_key?(&1, "color"))
      |> Enum.map(& &1["color"]["gamut_type"])
      |> Enum.uniq()
      |> Enum.sort()

    assert types == ["A", "B", "C"]
  end

  test "two rooms have no grouped_light service" do
    empty =
      "room"
      |> Hue.Fixtures.resources()
      |> Enum.filter(fn room ->
        not Enum.any?(room["services"], &(&1["rtype"] == "grouped_light"))
      end)

    assert length(empty) == 2
  end
end
