defmodule Hue.StubTest do
  use ExUnit.Case, async: true

  alias Hue.Error
  alias Hue.Resource

  test "the full-state fetch is answered from the fixture by default" do
    client = Hue.Stub.client()

    assert {:ok, resources} = Resource.list_all(client)
    assert length(resources) == 178
  end

  test "the resources answered can be replaced" do
    client = Hue.Stub.client(resources: [%{"type" => "light", "id" => "light-1"}])

    assert {:ok, [%{"id" => "light-1"}]} = Resource.list_all(client)
  end

  test "the fetch reports itself to the test process" do
    client = Hue.Stub.client()

    {:ok, _} = Resource.list_all(client)

    assert_receive {:hue_stub, :fetch, "/clip/v2/resource"}
  end

  test "a fetch can be made to fail a fixed number of times before succeeding" do
    client = Hue.Stub.client(fetch_failures: 2, fetch_status: 503)

    assert {:error, %Error{reason: :bridge_busy}} = Resource.list_all(client)
    assert {:error, %Error{reason: :bridge_busy}} = Resource.list_all(client)
    assert {:ok, resources} = Resource.list_all(client)
    assert length(resources) == 178
  end

  test "a fetch can be made to fail forever" do
    client = Hue.Stub.client(fetch_status: 403)

    assert {:error, %Error{reason: :unauthorized}} = Resource.list_all(client)
    assert {:error, %Error{reason: :unauthorized}} = Resource.list_all(client)
  end

  test "a write reports its path and body to the test process" do
    client = Hue.Stub.client()

    assert :ok = Resource.update(client, :light, "light-1", %{"on" => %{"on" => true}})

    assert_receive {:hue_stub, :put, "/clip/v2/resource/light/light-1", body}
    assert body == %{"on" => %{"on" => true}}
  end

  test "the eventstream hands its pid to the test, chunks frames, and closes" do
    client = Hue.Stub.client()

    task = Task.async(fn -> client |> Hue.Events.stream() |> Enum.to_list() end)

    assert_receive {:hue_stub, :eventstream, stream}

    send(
      stream,
      {:frame,
       "id: 1:0\ndata: [{\"creationtime\":\"t\",\"id\":\"e1\",\"type\":\"update\",\"data\":[{\"type\":\"light\",\"id\":\"light-1\",\"on\":{\"on\":true}}]}]\n\n"}
    )

    send(stream, :close)

    assert [%Hue.Event{type: :update, resource_type: :light, rid: "light-1"}] =
             Task.await(task)
  end

  test "the eventstream can refuse the connection" do
    client = Hue.Stub.client(eventstream_status: 403)

    assert_raise Error, fn -> client |> Hue.Events.stream() |> Enum.to_list() end
  end
end
