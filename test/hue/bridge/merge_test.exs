defmodule Hue.Bridge.MergeTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Merge

  test "a nested map merges rather than replacing its siblings" do
    cached = %{
      "dimming" => %{"brightness" => 42.0, "min_dim_level" => 0.2},
      "on" => %{"on" => false}
    }

    delta = %{"dimming" => %{"brightness" => 86.11}}

    assert Merge.merge(cached, delta) == %{
             "dimming" => %{"brightness" => 86.11, "min_dim_level" => 0.2},
             "on" => %{"on" => false}
           }
  end

  test "a list replaces rather than merging" do
    cached = %{"services" => [%{"rid" => "a"}, %{"rid" => "b"}]}
    delta = %{"services" => [%{"rid" => "c"}]}

    assert Merge.merge(cached, delta) == %{"services" => [%{"rid" => "c"}]}
  end

  test "a scalar replaces" do
    assert Merge.merge(%{"mode" => "normal"}, %{"mode" => "streaming"}) ==
             %{"mode" => "streaming"}
  end

  test "a key only the delta has is added" do
    assert Merge.merge(%{"id" => "x"}, %{"color" => %{"xy" => %{"x" => 0.3}}}) ==
             %{"id" => "x", "color" => %{"xy" => %{"x" => 0.3}}}
  end

  test "a key only the cache has survives" do
    assert Merge.merge(%{"id" => "x", "product_data" => %{"model_id" => "LCT001"}}, %{
             "id" => "x"
           }) == %{"id" => "x", "product_data" => %{"model_id" => "LCT001"}}
  end

  test "merging recurses to arbitrary depth" do
    cached = %{"a" => %{"b" => %{"c" => 1, "d" => 2}}}
    delta = %{"a" => %{"b" => %{"c" => 9}}}

    assert Merge.merge(cached, delta) == %{"a" => %{"b" => %{"c" => 9, "d" => 2}}}
  end

  test "a map replacing a scalar takes the map" do
    assert Merge.merge(%{"color" => nil}, %{"color" => %{"xy" => %{"x" => 0.3}}}) ==
             %{"color" => %{"xy" => %{"x" => 0.3}}}
  end

  test "a scalar replacing a map takes the scalar" do
    assert Merge.merge(%{"color" => %{"xy" => %{"x" => 0.3}}}, %{"color" => nil}) ==
             %{"color" => nil}
  end
end
