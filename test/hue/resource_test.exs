defmodule Hue.ResourceTest do
  use ExUnit.Case, async: true

  alias Hue.Error
  alias Hue.Resource

  setup do
    {:ok, client} = Hue.new("192.0.2.10", application_key: "k", plug: {Req.Test, __MODULE__})
    {:ok, client: client}
  end

  test "list/2 returns the data array", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/clip/v2/resource/light"
      assert Plug.Conn.get_req_header(conn, "hue-application-key") == ["k"]
      Req.Test.json(conn, %{"errors" => [], "data" => Hue.Fixtures.resources("light")})
    end)

    assert {:ok, lights} = Resource.list(client, :light)
    assert length(lights) == 19
  end

  test "get/3 returns a single resource", %{client: client} do
    light = Hue.Fixtures.resource("light")

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/clip/v2/resource/light/#{light["id"]}"
      Req.Test.json(conn, %{"errors" => [], "data" => [light]})
    end)

    assert {:ok, ^light} = Resource.get(client, :light, light["id"])
  end

  test "get/4 is :not_found when the bridge answers with an empty data array", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"errors" => [], "data" => []})
    end)

    assert {:error, %Error{reason: :not_found, rid: "missing-rid"}} =
             Resource.get(client, :light, "missing-rid")
  end

  # Recorded from a real BSB002 on firmware 1.78.0, which answers a missing,
  # malformed, or unknown-type rid with HTTP 404 and this JSON body rather
  # than HTTP 200 with an empty data array. This is the path get/4 actually
  # takes against real hardware; it also proves the rid the caller asked for
  # reaches the resulting Error, not just the description the bridge sent.
  test "a real 404 becomes :not_found with the rid attached", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, Hue.Fixtures.raw("not_found_404.json"))
    end)

    assert {:error,
            %Error{reason: :not_found, status: 404, description: "Not Found", rid: "missing-rid"}} =
             Resource.get(client, :light, "missing-rid")
  end

  test "update/5 attaches the rid to a real 404 too", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, Hue.Fixtures.raw("not_found_404.json"))
    end)

    assert {:error, %Error{reason: :not_found, rid: "missing-rid"}} =
             Resource.update(client, :light, "missing-rid", %{"on" => %{"on" => true}})
  end

  test "delete/4 attaches the rid to a real 404 too", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, Hue.Fixtures.raw("not_found_404.json"))
    end)

    assert {:error, %Error{reason: :not_found, rid: "missing-rid"}} =
             Resource.delete(client, :light, "missing-rid")
  end

  test "get/4 refuses return: :detailed, since there is no data list for errors to sit beside", %{
    client: client
  } do
    assert_raise ArgumentError, ~r/get\/4/, fn ->
      Resource.get(client, :light, "abc", return: :detailed)
    end
  end

  test "update/4 PUTs and returns :ok", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"on" => %{"on" => true}}
      Req.Test.json(conn, %{"errors" => [], "data" => [%{"rid" => "x", "rtype" => "light"}]})
    end)

    assert :ok = Resource.update(client, :light, "abc", %{"on" => %{"on" => true}})
  end

  test "create/4 POSTs and returns the created rid", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/clip/v2/resource/scene"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"name" => "Relax"}
      Req.Test.json(conn, %{"errors" => [], "data" => [%{"rid" => "new-id", "rtype" => "scene"}]})
    end)

    assert {:ok, [%{"rid" => "new-id"}]} = Resource.create(client, :scene, %{"name" => "Relax"})
  end

  test "delete/4 DELETEs and returns :ok", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/clip/v2/resource/scene/old-id"
      Req.Test.json(conn, %{"errors" => [], "data" => [%{"rid" => "old-id", "rtype" => "scene"}]})
    end)

    assert :ok = Resource.delete(client, :scene, "old-id")
  end

  test "an HTML 403 becomes :unauthorized rather than a decode crash", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(403, Hue.Fixtures.raw("unauthorized_403.html"))
    end)

    assert {:error, %Error{reason: :unauthorized, status: 403}} = Resource.list(client, :light)
  end

  test "partial success surfaces both data and errors", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "errors" => [%{"description" => "device (1) has communication issues"}],
        "data" => [%{"rid" => "x", "rtype" => "light"}]
      })
    end)

    assert {:ok, data, [%{"description" => description}]} =
             Resource.update(client, :light, "abc", %{}, return: :detailed)

    assert description =~ "communication issues"
    assert [%{"rid" => "x"}] = data
  end

  # The bridge can answer with `errors` and no `data` key at all -- a total
  # failure rather than a partial one. `:detailed` still gets the errors, just
  # against an empty data list rather than a missing one.
  test "errors with no data key, in :detailed mode, is ok with empty data", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"description" => "bridge overloaded"}]})
    end)

    assert {:ok, [], [%{"description" => "bridge overloaded"}]} =
             Resource.list(client, :light, return: :detailed)
  end

  # In :simple mode there is no data to hand back, so this has to be an
  # error rather than silently returning an empty list as if nothing had
  # gone wrong.
  test "errors with no data key, in :simple mode, is an error not a crash", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"description" => "bridge overloaded"}]})
    end)

    assert {:error, %Error{reason: :unexpected_response, description: description}} =
             Resource.list(client, :light)

    assert description =~ "bridge overloaded"
  end

  test "a body with neither data nor errors is an error, not a crash", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"unexpected" => "shape"})
    end)

    assert {:error, %Error{reason: :unexpected_response}} = Resource.list(client, :light)
  end

  test "a transport failure is normalised" do
    {:ok, client} =
      Hue.new("192.0.2.10", application_key: "k", plug: {Req.Test, __MODULE__}, retry: false)

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %Error{reason: :econnrefused}} = Resource.list(client, :light)
  end

  describe "options" do
    # The hard constraint this library carries: nothing may forward a
    # caller's :connect_options onto a request, because Req.merge/2 replaces
    # :connect_options wholesale and would silently drop the certificate pin.
    # A silently-ignored :connect_options here would be just as dangerous a
    # habit to let a caller form, so it is rejected outright instead.
    test "rejects an unknown option instead of silently ignoring it", %{client: client} do
      assert_raise ArgumentError, ~r/connect_options/, fn ->
        Resource.list(client, :light, connect_options: [timeout: 1_000])
      end
    end

    test "rejects a return mode that isn't :simple or :detailed", %{client: client} do
      assert_raise ArgumentError, ~r/return/, fn ->
        Resource.list(client, :light, return: :verbose)
      end
    end
  end

  describe "telemetry" do
    # A handler attached with :telemetry_test.attach_event_handlers/2 is not
    # scoped to this test's own calls -- it fires for every [:hue, :request]
    # span anywhere in the (async, concurrent) suite, all forwarded to this
    # process under this test's own ref. The ref proves a message came from
    # *this* handler; it says nothing about which test's request produced the
    # underlying event. Capturing `metadata` loosely and asserting on it
    # afterward let a same-named event from a *different*, concurrently
    # running test satisfy the receive first -- observed directly: a stop
    # event for this request seen alongside a start event whose path and
    # method belonged to another test's PUT. Matching the expected content
    # inside the receive pattern itself, as :telemetry_test's own docs do,
    # is what keeps the match specific to this call.
    test "emits start and stop around a read", %{client: client} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:hue, :request, :start],
          [:hue, :request, :stop]
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"errors" => [], "data" => []})
      end)

      Resource.list(client, :light)

      assert_received {[:hue, :request, :start], ^ref, %{monotonic_time: _},
                       %{method: :get, path: "/resource/light"}}

      assert_received {[:hue, :request, :stop], ^ref, %{duration: _},
                       %{method: :get, path: "/resource/light", result: :ok}}
    end

    # This is the bug the plan flagged: :telemetry.span/3 requires its
    # function to return `{result, metadata}`, and reading the outcome with
    # `elem(result, 0)` raises ArgumentError the moment `result` is the bare
    # atom `:ok` -- exactly what update/5 and delete/4 return in :simple
    # mode. Proves the fix (pattern-matched outcome/1) holds for that shape.
    #
    # The rid is this test's own, used nowhere else in the suite: "abc" (the
    # original choice) is also the rid three other tests in this file PUT to
    # the same path with the same :ok outcome, and a stop event only matched
    # on `%{result: :ok}` cannot tell this test's own event apart from theirs.
    test "emits stop with result: :ok when the call itself returns bare :ok", %{client: client} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:hue, :request, :stop]])

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"errors" => [], "data" => [%{"rid" => "x", "rtype" => "light"}]})
      end)

      assert :ok = Resource.update(client, :light, "returns-bare-ok", %{"on" => %{"on" => true}})

      assert_received {[:hue, :request, :stop], ^ref, _measurements,
                       %{method: :put, path: "/resource/light/returns-bare-ok", result: :ok}}
    end

    # "missing" is this test's own rid; the sibling test below (empty data,
    # not a wire-level 404) uses a different one, "unregistered-rid" -- both
    # produce result: :error, so without a path to tell them apart, either
    # one's event could satisfy the other's assert_received and the test that
    # actually regressed would still pass.
    test "emits stop with result: :error on a bridge error", %{client: client} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:hue, :request, :stop]])

      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      Resource.get(client, :light, "missing")

      assert_received {[:hue, :request, :stop], ^ref, _measurements,
                       %{method: :get, path: "/resource/light/missing", result: :error}}
    end

    # Telemetry wraps the whole public call, so a domain-level reinterpretation
    # -- get/4 turning an empty data array into :not_found -- shows up as
    # :error here too, not just a wire-level 200. See the sibling test above
    # for why this uses its own distinct rid rather than "missing" too.
    test "emits stop with result: :error when get/4 collapses to :not_found", %{client: client} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:hue, :request, :stop]])

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"errors" => [], "data" => []})
      end)

      Resource.get(client, :light, "unregistered-rid")

      assert_received {[:hue, :request, :stop], ^ref, _measurements,
                       %{method: :get, path: "/resource/light/unregistered-rid", result: :error}}
    end
  end

  test "list_all/1 returns every resource on the bridge in one request", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/clip/v2/resource"
      assert Plug.Conn.get_req_header(conn, "hue-application-key") == ["k"]
      Req.Test.json(conn, %{"errors" => [], "data" => Hue.Fixtures.full_state()["data"]})
    end)

    assert {:ok, resources} = Resource.list_all(client)
    assert length(resources) == 178
    assert Enum.count(resources, &(&1["type"] == "light")) == 19
  end

  test "list_all/2 surfaces partial success like list/3 does", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"description" => "partly"}], "data" => []})
    end)

    assert {:ok, [], [%{"description" => "partly"}]} =
             Resource.list_all(client, return: :detailed)
  end

  test "type/1 converts a documented resource type to an atom" do
    assert Resource.type("light") == :light
    assert Resource.type("grouped_light") == :grouped_light
  end

  test "type/1 leaves an unknown type as a string rather than creating an atom" do
    assert Resource.type("type_signify_invents_in_2027") == "type_signify_invents_in_2027"
  end

  test "type/1 passes nil through" do
    assert Resource.type(nil) == nil
  end
end
