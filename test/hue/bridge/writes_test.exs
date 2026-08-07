defmodule Hue.Bridge.WritesTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge.Writes

  defp light_key(rid), do: {:light, rid}

  test "a queued write is taken back out" do
    {writes, _collapsed} =
      Writes.new() |> Writes.enqueue(light_key("light-1"), %{"on" => %{"on" => true}})

    assert {:ok, {:light, "light-1"}, %{"on" => %{"on" => true}}, _writes} =
             Writes.take(writes, :light, 0)
  end

  test "an empty queue has nothing to take" do
    assert :empty = Writes.take(Writes.new(), :light, 0)
  end

  test "two writes to one target collapse into one request" do
    {writes, 0} =
      Writes.new()
      |> Writes.enqueue(light_key("light-1"), %{"dimming" => %{"brightness" => 40.0}})

    {writes, 1} =
      Writes.enqueue(writes, light_key("light-1"), %{"dimming" => %{"brightness" => 60.0}})

    assert {:ok, _key, %{"dimming" => %{"brightness" => 60.0}}, writes} =
             Writes.take(writes, :light, 0)

    assert :empty = Writes.take(writes, :light, 0)
  end

  test "collapsing merges different keys rather than discarding them" do
    {writes, 0} = Writes.new() |> Writes.enqueue(light_key("light-1"), %{"on" => %{"on" => true}})

    {writes, 1} =
      Writes.enqueue(writes, light_key("light-1"), %{"dimming" => %{"brightness" => 40.0}})

    assert {:ok, _key, body, _writes} = Writes.take(writes, :light, 0)
    assert body == %{"on" => %{"on" => true}, "dimming" => %{"brightness" => 40.0}}
  end

  test "the collapsed count reports how many writes were absorbed" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
    {writes, 1} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => false}})
    {_writes, 2} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
  end

  test "the collapsed count resets once the write is taken" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
    {writes, 1} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => false}})

    {:ok, _key, _body, writes} = Writes.take(writes, :light, 0)

    # This first re-enqueue always reports 0, whether or not `take/3` cleared
    # the stale counter: the key is absent from `pending`, so `enqueue/3`
    # takes its fresh-insert branch, which returns a literal 0 without
    # consulting `collapsed` at all. A second re-enqueue is what actually
    # exercises the merge branch that reads `collapsed`, so it is the one
    # that would catch a counter resuming from a stale value instead of
    # restarting at 0.
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
    {_writes, 1} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => false}})
  end

  test "writes to different targets do not collapse into each other" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})
    {writes, 0} = Writes.enqueue(writes, light_key("light-2"), %{"on" => %{"on" => false}})

    {:ok, {:light, "light-1"}, _one, writes} = Writes.take(writes, :light, 0)
    {:ok, {:light, "light-2"}, _two, writes} = Writes.take(writes, :light, 100)
    assert :empty = Writes.take(writes, :light, 200)
  end

  test "targets are taken in the order they were first queued" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("a"), %{"on" => %{"on" => true}})
    {writes, 0} = Writes.enqueue(writes, light_key("b"), %{"on" => %{"on" => true}})
    # Re-queueing a already in the queue must not move it to the back.
    {writes, 1} = Writes.enqueue(writes, light_key("a"), %{"on" => %{"on" => false}})

    {:ok, {:light, "a"}, _, writes} = Writes.take(writes, :light, 0)
    {:ok, {:light, "b"}, _, _writes} = Writes.take(writes, :light, 100)
  end

  test "a type with nothing pending is never due" do
    assert Writes.due_in(Writes.new(), :light, 0) == :never
  end

  test "a type with something pending and no recent send is due now" do
    {writes, 0} = Writes.new() |> Writes.enqueue(light_key("light-1"), %{"on" => %{"on" => true}})

    assert Writes.due_in(writes, :light, 0) == 0
  end

  test "a light waits out the light interval after a send" do
    {writes, 0} = Writes.new() |> Writes.enqueue(light_key("a"), %{"on" => %{"on" => true}})
    {:ok, _key, _body, writes} = Writes.take(writes, :light, 1_000)
    {writes, 0} = Writes.enqueue(writes, light_key("b"), %{"on" => %{"on" => true}})

    assert Writes.due_in(writes, :light, 1_000) == 100
    assert Writes.due_in(writes, :light, 1_050) == 50
    assert Writes.due_in(writes, :light, 1_100) == 0
    assert Writes.due_in(writes, :light, 5_000) == 0
  end

  test "a grouped_light is paced ten times slower than a light" do
    {writes, 0} =
      Writes.new() |> Writes.enqueue({:grouped_light, "gl-1"}, %{"on" => %{"on" => true}})

    {:ok, _key, _body, writes} = Writes.take(writes, :grouped_light, 1_000)
    {writes, 0} = Writes.enqueue(writes, {:grouped_light, "gl-2"}, %{"on" => %{"on" => true}})

    assert Writes.due_in(writes, :grouped_light, 1_000) == 1_000
    assert Writes.due_in(writes, :grouped_light, 1_999) == 1
  end

  test "pacing is per type, so a light is not delayed by a grouped_light" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, {:grouped_light, "gl-1"}, %{"on" => %{"on" => true}})
    {:ok, _key, _body, writes} = Writes.take(writes, :grouped_light, 1_000)
    {writes, 0} = Writes.enqueue(writes, light_key("light-1"), %{"on" => %{"on" => true}})

    assert Writes.due_in(writes, :light, 1_000) == 0
  end

  test "an unknown type falls back to the light interval" do
    {writes, 0} = Writes.new() |> Writes.enqueue({:button, "button-1"}, %{"foo" => "bar"})
    {:ok, _key, _body, writes} = Writes.take(writes, :button, 1_000)
    {writes, 0} = Writes.enqueue(writes, {:button, "button-2"}, %{"foo" => "bar"})

    assert Writes.due_in(writes, :button, 1_000) == 100
  end

  test "a scene recall is paced at the grouped_light rate, not the light rate" do
    {writes, 0} = Writes.new() |> Writes.enqueue({:scene, "scene-1"}, %{"recall" => %{}})
    {:ok, _key, _body, writes} = Writes.take(writes, :scene, 1_000)
    {writes, 0} = Writes.enqueue(writes, {:scene, "scene-2"}, %{"recall" => %{}})

    assert Writes.due_in(writes, :scene, 1_000) == 1_000
    assert Writes.due_in(writes, :scene, 1_999) == 1
  end

  test "the pending types are reportable" do
    writes = Writes.new()
    {writes, 0} = Writes.enqueue(writes, light_key("a"), %{"on" => %{"on" => true}})
    {writes, 0} = Writes.enqueue(writes, {:grouped_light, "gl-1"}, %{"on" => %{"on" => true}})

    assert Enum.sort(Writes.pending_types(writes)) == [:grouped_light, :light]
  end
end
