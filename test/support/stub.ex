defmodule Hue.Stub do
  @moduledoc """
  A bridge that answers over a function plug, for testing layer 2.

  ## Why not `Req.Test`

  `Req.Test` stubs are owned by the process that installs them. Every request
  layer 2 makes is issued by the bridge's own server or by a task it spawned,
  never by the test process, so a `Req.Test` suite here would rest entirely on
  `$callers` propagating through `Task.Supervisor` — an assumption about another
  library's internals, load-bearing under every test in the layer.

  `Hue.new/2` passes unknown options through to `Req.new/1`, and Req accepts a
  bare function as `:plug`. A function plug runs in whichever process makes the
  request and closes over whatever it was built with. No ownership, no
  allowances, and tests stay `async: true`.

  ## Talking to the stub

  Every request announces itself to the process that called `client/1`:

      {:hue_stub, :fetch, path}
      {:hue_stub, :put, path, decoded_body}
      {:hue_stub, :eventstream, stream_pid}

  The eventstream one carries a pid because a stream is not a canned response.
  Send it `{:frame, iodata}` to push bytes down the connection and `:close` to
  end it cleanly; kill it to simulate a drop.

  ## Options

    * `:resources` — what the full-state fetch answers with. Defaults to the
      recorded fixture, all 178 resources.
    * `:fetch_status` — an HTTP status to fail the full-state fetch with.
    * `:fetch_failures` — how many fetches fail with `:fetch_status` before the
      stub starts succeeding. Omit for "every fetch fails".
    * `:eventstream_status` — an HTTP status to refuse the eventstream with.
  """

  @default_body ~s({"errors":[{"description":"stubbed failure"}],"data":[]})
  @unauthorized_body "<html><body>unauthorized user</body></html>"
  @stream_idle_timeout 5_000

  @doc "Builds a client pointed at the stub. See the moduledoc for options."
  @spec client(keyword()) :: Hue.Client.t()
  def client(options \\ []) do
    test = self()
    resources = Keyword.get_lazy(options, :resources, fn -> Hue.Fixtures.full_state()["data"] end)
    fetch_status = Keyword.get(options, :fetch_status)
    eventstream_status = Keyword.get(options, :eventstream_status)

    # A counter rather than an Agent: it is shared across every process that
    # makes a request, and it needs no supervision or cleanup.
    remaining_failures = :counters.new(1, [:atomics])
    :counters.put(remaining_failures, 1, Keyword.get(options, :fetch_failures, -1))

    {:ok, client} =
      Hue.new("192.0.2.10",
        application_key: "k",
        # Req retries a 503 by default (:safe_transient), which would run the
        # plug — and so consume the failure counter below — more than once per
        # call the test makes. That is desirable against a real bridge and
        # wrong here: it silently multiplies each stubbed failure into two or
        # three, which is how "fail twice, then succeed" became "fail once, in
        # a call that never returned control to the test in between."
        retry: false,
        plug: fn conn ->
          route(conn, %{
            test: test,
            resources: resources,
            fetch_status: fetch_status,
            eventstream_status: eventstream_status,
            remaining_failures: remaining_failures
          })
        end
      )

    client
  end

  defp route(%{request_path: "/eventstream/clip/v2"} = conn, config) do
    case config.eventstream_status do
      nil -> eventstream(conn, config)
      status -> refuse(conn, status)
    end
  end

  defp route(%{method: "GET", request_path: "/clip/v2/resource"} = conn, config) do
    send(config.test, {:hue_stub, :fetch, conn.request_path})

    if failing?(config.remaining_failures, config.fetch_status) do
      refuse(conn, config.fetch_status)
    else
      json(conn, 200, %{"errors" => [], "data" => config.resources})
    end
  end

  defp route(%{method: "PUT"} = conn, config) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(config.test, {:hue_stub, :put, conn.request_path, Jason.decode!(raw)})

    json(conn, 200, %{"errors" => [], "data" => []})
  end

  defp route(conn, config) do
    send(config.test, {:hue_stub, :unhandled, conn.method, conn.request_path})
    json(conn, 404, %{"errors" => [%{"description" => "no stub for this path"}], "data" => []})
  end

  # -1 means "fail forever"; any other value counts down and stops failing at 0.
  defp failing?(_counter, nil), do: false

  defp failing?(counter, _status) do
    case :counters.get(counter, 1) do
      0 -> false
      -1 -> true
      _positive -> :counters.sub(counter, 1, 1) == :ok
    end
  end

  defp eventstream(conn, config) do
    send(config.test, {:hue_stub, :eventstream, self()})

    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_chunked(200)
    |> chunk_loop()
  end

  defp chunk_loop(conn) do
    receive do
      {:frame, data} ->
        {:ok, conn} = Plug.Conn.chunk(conn, data)
        chunk_loop(conn)

      :close ->
        conn
    after
      @stream_idle_timeout -> conn
    end
  end

  defp refuse(conn, 403) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(403, @unauthorized_body)
  end

  defp refuse(conn, status) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, @default_body)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
