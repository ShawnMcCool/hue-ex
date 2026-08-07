defmodule Hue.Bridge.BodyTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Body
  alias Hue.Error

  defp light(extra \\ %{}) do
    Map.merge(
      %{
        "type" => "light",
        "id" => "light-1",
        "on" => %{"on" => false},
        "dimming" => %{"brightness" => 42.0, "min_dim_level" => 0.2},
        "color" => %{
          "gamut_type" => "C",
          "gamut" => %{
            "red" => %{"x" => 0.6915, "y" => 0.3083},
            "green" => %{"x" => 0.1700, "y" => 0.7000},
            "blue" => %{"x" => 0.1532, "y" => 0.0475}
          }
        },
        "color_temperature" => %{
          "mirek_schema" => %{"mirek_minimum" => 153, "mirek_maximum" => 500}
        }
      },
      extra
    )
  end

  defp plain_light, do: %{"type" => "light", "id" => "light-2", "on" => %{"on" => false}}

  test "on translates" do
    assert {:ok, %{"on" => %{"on" => true}}} = Body.build([on: true], light())
    assert {:ok, %{"on" => %{"on" => false}}} = Body.build([on: false], light())
  end

  test "brightness translates to a float under dimming" do
    assert {:ok, %{"dimming" => %{"brightness" => 40.0}}} = Body.build([brightness: 40], light())

    assert {:ok, %{"dimming" => %{"brightness" => 40.5}}} =
             Body.build([brightness: 40.5], light())
  end

  test "brightness on a light with no dimming key is :not_dimmable" do
    assert {:error, %Error{reason: :not_dimmable, rid: "light-2"}} =
             Body.build([brightness: 40], plain_light())
  end

  test "brightness accepts the boundary values 0 and 100" do
    assert {:ok, %{"dimming" => %{"brightness" => lower}}} = Body.build([brightness: 0], light())
    assert lower == 0.0

    assert {:ok, %{"dimming" => %{"brightness" => upper}}} =
             Body.build([brightness: 100], light())

    assert upper == 100.0
  end

  test "a brightness above 100 raises rather than being sent as-is" do
    assert_raise ArgumentError, ~r/brightness/, fn -> Body.build([brightness: 150], light()) end
  end

  test "a negative brightness raises rather than being sent as-is" do
    assert_raise ArgumentError, ~r/brightness/, fn -> Body.build([brightness: -1], light()) end
  end

  test "transition translates to dynamics duration" do
    assert {:ok, %{"dynamics" => %{"duration" => 400}}} = Body.build([transition: 400], light())
  end

  test "color translates through the light's own gamut" do
    assert {:ok, %{"color" => %{"xy" => %{"x" => x, "y" => y}}}} =
             Body.build([color: "#ff8800"], light())

    assert is_float(x) and is_float(y)
  end

  test "color on a light with no color key is :not_color_capable and names the light" do
    assert {:error, %Error{reason: :not_color_capable, rid: "light-2"}} =
             Body.build([color: "#ff8800"], plain_light())
  end

  test "kelvin on a light with no color_temperature key is :not_color_capable and names the light" do
    assert {:error, %Error{reason: :not_color_capable, rid: "light-2"}} =
             Body.build([kelvin: 2700], plain_light())
  end

  test "kelvin translates to mirek within the light's own schema" do
    assert {:ok, %{"color_temperature" => %{"mirek" => 370}}} =
             Body.build([kelvin: 2700], light())
  end

  test "several options combine into one body" do
    assert {:ok, body} = Body.build([on: true, brightness: 40, transition: 400], light())

    assert body == %{
             "on" => %{"on" => true},
             "dimming" => %{"brightness" => 40.0},
             "dynamics" => %{"duration" => 400}
           }
  end

  test "an empty option list is an empty body" do
    assert {:ok, %{}} = Body.build([], light())
  end

  test "a non-numeric brightness raises rather than returning an error" do
    assert_raise ArgumentError, ~r/brightness/, fn ->
      Body.build([brightness: "loud"], light())
    end
  end

  test "a non-boolean on raises" do
    assert_raise ArgumentError, ~r/on/, fn -> Body.build([on: "yes"], light()) end
  end

  test "a negative transition raises" do
    assert_raise ArgumentError, ~r/transition/, fn -> Body.build([transition: -1], light()) end
  end

  test "an unknown option raises and says what is accepted" do
    assert_raise ArgumentError, ~r/nonsense/, fn -> Body.build([nonsense: 1], light()) end
  end

  test "a known option given twice with different values is not misreported as unknown, and the later value wins" do
    assert {:ok, %{"on" => %{"on" => false}}} = Body.build([on: true, on: false], light())
  end

  test "a known option given twice with the same value is not misreported as unknown" do
    assert {:ok, %{"on" => %{"on" => true}}} = Body.build([on: true, on: true], light())
  end

  test "a non-keyword list raises ArgumentError rather than crashing some other way" do
    assert_raise ArgumentError, fn -> Body.build([1, 2, 3], light()) end
  end

  test "the first capability failure wins and the rest is not attempted" do
    assert {:error, %Error{reason: :not_dimmable}} =
             Body.build([on: true, brightness: 40], plain_light())
  end

  test "a caller bug raises even when a genuine capability error would have fired first" do
    assert_raise ArgumentError, ~r/brightness/, fn ->
      Body.build([color: "#ff8800", brightness: "loud"], plain_light())
    end
  end

  test "the raise happens regardless of option order — the property is order-independence" do
    assert_raise ArgumentError, ~r/brightness/, fn ->
      Body.build([brightness: "loud", color: "#ff8800"], plain_light())
    end
  end

  test "a capability error still returns when every option is well-formed" do
    assert {:error, %Error{reason: :not_color_capable}} =
             Body.build([color: "#ff8800"], plain_light())
  end

  test "a colour value that is not one of Hue.Color's accepted shapes raises, even against a colourless light" do
    # Hue.Color.payload/2 checks the light's gamut before it ever inspects the
    # input, so against a colourless light it answers :not_color_capable for
    # *any* input, well-formed or not — see the moduledoc. A shape this
    # library could never have turned into a colour is this module's own
    # caller-bug case, so it must raise here rather than surface as a
    # capability mismatch the caller did not actually have.
    assert_raise ArgumentError, ~r/color/, fn -> Body.build([color: 42], plain_light()) end

    assert_raise ArgumentError, ~r/color/, fn ->
      Body.build([color: "not-a-colour"], plain_light())
    end

    assert_raise ArgumentError, ~r/color/, fn -> Body.build([color: %{}], plain_light()) end
  end

  test "a colour value that is not one of Hue.Color's accepted shapes raises against a colour-capable light too" do
    assert_raise ArgumentError, ~r/color/, fn -> Body.build([color: 42], light()) end
  end

  test "a grouped_light accepts on and brightness like a light does" do
    grouped = %{
      "type" => "grouped_light",
      "id" => "gl-1",
      "on" => %{"on" => false},
      "dimming" => %{"brightness" => 50.0}
    }

    assert {:ok, %{"on" => %{"on" => true}, "dimming" => %{"brightness" => 25.0}}} =
             Body.build([on: true, brightness: 25], grouped)
  end
end
