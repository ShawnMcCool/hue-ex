defmodule Hue.EventsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Hue.Event
  alias Hue.Events

  @application_key "an-application-key-that-must-never-be-logged"

  # -- the contract ----------------------------------------------------------

  test "decode/1 unwraps both array layers" do
    events = Events.decode(Hue.Fixtures.raw("eventstream_frames.txt"))

    assert length(events) == 2
    assert %Event{type: :update, resource_type: :light} = hd(events)
  end

  test "decode/1 keeps the resource delta intact" do
    [light_event | _] = Events.decode(Hue.Fixtures.raw("eventstream_frames.txt"))

    assert light_event.data["on"] == %{"on" => true}
    assert light_event.id
    assert light_event.creationtime
  end

  test "decode/1 ignores the comment the bridge opens with" do
    assert Events.decode(": hi\n\n") == []
  end

  test "one frame can carry many envelopes and many resources" do
    frame = """
    id: 1:0
    data: [{"creationtime":"2026-08-06T15:50:32Z","id":"a","type":"update","data":[{"id":"1","type":"light","on":{"on":true}},{"id":"2","type":"light","on":{"on":false}}]},{"creationtime":"2026-08-06T15:50:32Z","id":"b","type":"add","data":[{"id":"3","type":"room"}]}]

    """

    events = Events.decode(frame)

    assert length(events) == 3
    assert Enum.map(events, & &1.type) == [:update, :update, :add]
    assert Enum.map(events, & &1.resource_type) == [:light, :light, :room]
  end

  test "decoding is invariant to where the stream is chopped" do
    raw = Hue.Fixtures.raw("eventstream_frames.txt")
    expected = Events.decode(raw)

    for split <- 1..(byte_size(raw) - 1) do
      <<first::binary-size(split), second::binary>> = raw

      assert Events.decode_stream([first, second]) == expected,
             "decoding differed when the stream was split at byte #{split}"
    end
  end

  # -- what the flattened event carries --------------------------------------

  describe "decode/1" do
    test "carries the envelope's identity onto every resource it held" do
      events =
        Events.decode(
          frame(
            ~s([{"creationtime":"then","id":"env","type":"update",) <>
              ~s("data":[{"id":"one","type":"light"},{"id":"two","type":"light"}]}])
          )
        )

      assert Enum.map(events, & &1.id) == ["env", "env"]
      assert Enum.map(events, & &1.creationtime) == ["then", "then"]
      assert Enum.map(events, & &1.rid) == ["one", "two"]
    end

    test "carries the owner through, which is how a service finds its device" do
      [event | _] = Events.decode(Hue.Fixtures.raw("eventstream_frames.txt"))

      assert event.owner == %{
               "rid" => "20bceb24-5ad3-53b1-4129-4cc0d3ca41af",
               "rtype" => "device"
             }
    end

    test "an envelope with no owner on the resource is not a failure" do
      [event] = Events.decode(envelope("update", [%{"id" => "1", "type" => "light"}]))

      assert event.owner == nil
    end
  end

  describe "envelope types" do
    test "add, update, and delete are the atoms CLIP v2 names them" do
      for type <- ~w(add update delete) do
        [event] = Events.decode(envelope(type, [%{"id" => "1", "type" => "light"}]))
        assert event.type == String.to_existing_atom(type)
      end
    end

    test "an error envelope is :error" do
      [event] = Events.decode(envelope("error", [%{"id" => "1", "type" => "light"}]))

      assert event.type == :error
    end

    # Reporting an unrecognised envelope type as :error would tell a caller the
    # bridge reported a failure when it reported nothing of the kind.
    test "an envelope type this library does not know is not reported as an error" do
      [event] = Events.decode(envelope("rearrange", [%{"id" => "1", "type" => "light"}]))

      assert event.type == "rearrange"
    end
  end

  describe "resource types" do
    test "every type the recorded bridge population uses becomes an atom" do
      types = Hue.Fixtures.full_state()["data"] |> Enum.map(& &1["type"]) |> Enum.uniq()

      for type <- types do
        [event] = Events.decode(envelope("update", [%{"id" => "1", "type" => type}]))
        assert is_atom(event.resource_type)
        assert Atom.to_string(event.resource_type) == type
      end
    end

    # The bridge names the type, so turning it into an atom is turning network
    # input into a term that is never collected.
    test "a type this library does not know stays the string the bridge sent" do
      [event] = Events.decode(envelope("update", [%{"id" => "1", "type" => "quantum_lamp"}]))

      assert event.resource_type == "quantum_lamp"
      refute is_atom(event.resource_type)
    end

    test "two unrecognised types stay distinguishable from each other" do
      events =
        Events.decode(
          envelope("update", [
            %{"id" => "1", "type" => "quantum_lamp"},
            %{"id" => "2", "type" => "tachyon_sensor"}
          ])
        )

      assert Enum.map(events, & &1.resource_type) == ["quantum_lamp", "tachyon_sensor"]
    end
  end

  describe "frames that do not decode" do
    test "an empty data array yields no events, quietly" do
      log = capture_log(fn -> assert Events.decode(envelope("update", [])) == [] end)

      assert log == ""
    end

    test "an envelope list that is empty yields no events, quietly" do
      log = capture_log(fn -> assert Events.decode(frame("[]")) == [] end)

      assert log == ""
    end

    # A frame that vanishes without trace is the hardest eventstream bug to find.
    test "a frame that is not JSON is dropped, and says so" do
      log = capture_log(fn -> assert Events.decode(frame("not json at all")) == [] end)

      assert log =~ "not valid JSON"
      assert log =~ "not json at all"
    end

    test "a frame that is not a list of envelopes is dropped, and says so" do
      log = capture_log(fn -> assert Events.decode(frame(~s({"type":"update"}))) == [] end)

      assert log =~ "not a list of envelopes"
    end

    test "an envelope with no resource list is dropped, and says so" do
      log = capture_log(fn -> assert Events.decode(frame(~s([{"type":"update"}]))) == [] end)

      assert log =~ "no list of changed resources"
    end

    # The struct's declared types are a promise about what a consumer can match
    # on. Passing an integer through where a String.t() was declared is the same
    # misplaced trust as calling String.to_atom/1 on a name from the bridge.
    test "a type that is not text is dropped rather than passed off as a String.t()" do
      log =
        capture_log(fn ->
          assert Events.decode(
                   frame(~s([{"id":"e","type":42,"data":[{"id":"1","type":"light"}]}]))
                 ) ==
                   []

          assert Events.decode(
                   frame(~s([{"id":"e","type":"update","data":[{"id":"1","type":7}]}]))
                 ) ==
                   []
        end)

      assert log =~ "envelope"
      assert log =~ "resource"
    end

    test "an rid that is not text is dropped too" do
      log =
        capture_log(fn ->
          assert Events.decode(
                   frame(~s([{"id":"e","type":"update","data":[{"id":1,"type":"light"}]}]))
                 ) == []
        end)

      assert log =~ "resource"
    end

    test "an owner that is not an object is dropped too" do
      body = ~s([{"id":"e","type":"update","data":[{"id":"1","type":"light","owner":"nope"}]}])
      log = capture_log(fn -> assert Events.decode(frame(body)) == [] end)

      assert log =~ "resource"
    end

    # Absent and wrong are different situations. A bridge that sends no
    # creationtime has told us nothing; one that sends 42 has told us something
    # false.
    test "a field the bridge simply omitted is not malformed" do
      [event] = Events.decode(frame(~s([{"type":"update","data":[{"type":"light"}]}])))

      assert event.rid == nil
      assert event.id == nil
      assert event.creationtime == nil
      assert event.resource_type == :light
    end

    test "a resource that is not an object is dropped, and says so" do
      log =
        capture_log(fn ->
          assert Events.decode(frame(~s([{"type":"update","data":["light"]}]))) == []
        end)

      assert log =~ "was not an object"
    end

    test "one malformed frame does not cost the frames around it" do
      raw =
        frame(~s([{"type":"update","data":[{"id":"1","type":"light"}]}])) <>
          frame("not json at all") <>
          frame(~s([{"type":"update","data":[{"id":"2","type":"light"}]}]))

      events = capture_log(fn -> send(self(), {:events, Events.decode(raw)}) end)
      assert events =~ "not valid JSON"

      assert_received {:events, [%Event{rid: "1"}, %Event{rid: "2"}]}
    end
  end

  describe "decode_stream/1" do
    test "a comment arriving between two frames is ignored" do
      raw = Hue.Fixtures.raw("eventstream_frames.txt")
      [first, second] = String.split(raw, "id: 1786031433", parts: 2)

      chunks = [first, ": keepalive\n\n", "id: 1786031433" <> second]

      assert Events.decode_stream(chunks) == Events.decode(raw)
    end

    test "a chunk that ends mid-frame yields nothing until the frame completes" do
      raw = Hue.Fixtures.raw("eventstream_frames.txt")
      <<first::binary-size(200), _rest::binary>> = raw

      assert Events.decode_stream([first]) == []
    end

    test "an empty enumerable decodes to no events" do
      assert Events.decode_stream([]) == []
    end
  end

  # -- the live stream -------------------------------------------------------

  describe "stream/2" do
    test "reads events off a real socket, split mid-frame at every fragment" do
      raw = Hue.Fixtures.raw("eventstream_frames.txt")
      {port, fingerprint} = Hue.EventstreamServer.start(fragments(raw, 17), close_after: :done)

      assert client(port, fingerprint) |> Events.stream() |> Enum.to_list() ==
               Events.decode(raw)
    end

    test "sends the application key and asks for an event stream" do
      raw = Hue.Fixtures.raw("eventstream_frames.txt")
      {port, fingerprint} = Hue.EventstreamServer.start([raw], close_after: :done)

      client(port, fingerprint) |> Events.stream() |> Enum.to_list()

      assert_received {:eventstream_request, request}
      assert request =~ "GET /eventstream/clip/v2 HTTP/1.1"
      assert request =~ "hue-application-key: #{@application_key}"
      assert request =~ "accept: text/event-stream"
    end

    # Enum.take/2 halts the stream from above. Nothing below it gets to run a
    # cleanup of its own, so the socket is only released if the after_fun is
    # what releases it -- and the server is the only witness to that.
    test "taking one event and stopping closes the connection" do
      raw = Hue.Fixtures.raw("eventstream_frames.txt")
      {port, fingerprint} = Hue.EventstreamServer.start([raw])

      assert [%Event{resource_type: :light}] =
               client(port, fingerprint) |> Events.stream() |> Enum.take(1)

      assert_receive {:eventstream_finished, {:error, :closed}}, 5_000
    end

    test "leaves the caller's unrelated messages untouched and in order" do
      raw = Hue.Fixtures.raw("eventstream_frames.txt")
      collector = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(collector, :kill) end)

      # Many small fragments plus a consumer slower than the bridge: measured,
      # that leaves 42 chunk messages queued behind the first event at the
      # moment the stream halts. They are what a stream that cleans up after
      # itself has to take back out of a mailbox it does not own.
      {port, fingerprint} = Hue.EventstreamServer.start(fragments(raw, 8), report_to: collector)

      send(self(), :marker_one)
      send(self(), :marker_two)

      assert [%Event{}] =
               client(port, fingerprint)
               |> Events.stream()
               |> Stream.map(fn event ->
                 Process.sleep(100)
                 event
               end)
               |> Enum.take(1)

      assert_received :marker_one
      assert_received :marker_two
      refute_received {_reference, _payload}
    end

    # The reason has to survive as an atom the caller can match on. Req hands
    # this one back as an exception struct rather than the bare reason every
    # other error path in this library carries.
    test "a bridge that disappears mid-stream raises rather than ending quietly" do
      raw = Hue.Fixtures.raw("eventstream_frames.txt")
      <<first::binary-size(400), _rest::binary>> = raw
      {port, fingerprint} = Hue.EventstreamServer.start([first], close_after: :abruptly)

      error =
        assert_raise Hue.Error, fn ->
          client(port, fingerprint) |> Events.stream() |> Enum.to_list()
        end

      refute error.reason == :unknown
    end

    test "a bridge that refuses the stream raises the error it refused with" do
      {port, fingerprint} =
        Hue.EventstreamServer.start([], status: {403, "Forbidden"}, content_type: "text/html")

      assert_raise Hue.Error, fn ->
        client(port, fingerprint) |> Events.stream() |> Enum.to_list()
      end
    end

    test "the refusal keeps the description the bridge gave for it" do
      body = ~s({"errors":[{"description":"device or resource not found"}]})

      {port, fingerprint} =
        Hue.EventstreamServer.start([], status: {404, "Not Found"}, body: body)

      error =
        assert_raise Hue.Error, fn ->
          client(port, fingerprint) |> Events.stream() |> Enum.to_list()
        end

      assert error.reason == :not_found
      assert error.description == "device or resource not found"
    end

    # The key is a bearer credential. It goes in a header and nowhere else.
    test "no failure path puts the application key in a log line" do
      {port, fingerprint} = Hue.EventstreamServer.start([], status: {403, "Forbidden"})

      log =
        capture_log(fn ->
          assert_raise Hue.Error, fn ->
            client(port, fingerprint) |> Events.stream() |> Enum.to_list()
          end
        end)

      refute log =~ @application_key
    end

    test "the raised error does not carry the application key either" do
      {port, fingerprint} = Hue.EventstreamServer.start([], status: {403, "Forbidden"})

      error =
        assert_raise Hue.Error, fn ->
          client(port, fingerprint) |> Events.stream() |> Enum.to_list()
        end

      refute inspect(error) =~ @application_key
      refute Exception.message(error) =~ @application_key
    end

    test "nothing is opened until the stream is enumerated" do
      {port, fingerprint} = Hue.EventstreamServer.start([], close_after: :done)

      client(port, fingerprint) |> Events.stream()

      refute_received {:eventstream_request, _request}
    end

    test "an unknown option is refused rather than silently ignored" do
      {:ok, client} = Hue.new("127.0.0.1", verify: :none)

      assert_raise ArgumentError, ~r/unknown option\(s\) \[:recieve_timeout\]/, fn ->
        Events.stream(client, recieve_timeout: 1_000)
      end
    end

    test "options that are not a keyword list are refused" do
      {:ok, client} = Hue.new("127.0.0.1", verify: :none)

      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Events.stream(client, %{receive_timeout: 1_000})
      end
    end

    test "a receive_timeout that is not a duration is refused" do
      {:ok, client} = Hue.new("127.0.0.1", verify: :none)

      for value <- ["loud", -1, 1.5, nil] do
        assert_raise ArgumentError, ~r/receive_timeout/, fn ->
          Events.stream(client, receive_timeout: value)
        end
      end
    end

    test ":infinity and any count of milliseconds are durations" do
      {:ok, client} = Hue.new("127.0.0.1", verify: :none)

      for value <- [:infinity, 0, 5_000] do
        assert Enumerable.impl_for(Events.stream(client, receive_timeout: value))
      end
    end

    test "a bounded receive_timeout still reads the stream it was given" do
      raw = Hue.Fixtures.raw("eventstream_frames.txt")
      {port, fingerprint} = Hue.EventstreamServer.start([raw], close_after: :done)

      assert client(port, fingerprint)
             |> Events.stream(receive_timeout: 5_000)
             |> Enum.to_list() == Events.decode(raw)
    end
  end

  # Every other stream test builds its client with `retry: false`, which is a
  # habit that can hide a whole configuration. These use the one `Hue.new/2`
  # actually hands out. `retry_delay: 0` removes the waiting between attempts,
  # not the retrying -- `retry: :safe_transient` and `max_retries: 3` are still
  # Req's defaults here, so a retry would still happen and still be counted.
  describe "stream/2 under the configuration Hue.new/2 actually produces" do
    test "asks the bridge once, because a half-read stream cannot be resumed" do
      {port, fingerprint} = retrying_bridge()

      capture_log(fn ->
        assert_raise Hue.Error, fn ->
          retrying_client(port, fingerprint) |> Events.stream() |> Enum.to_list()
        end
      end)

      assert_received {:eventstream_request, _request}
      refute_received {:eventstream_request, _request}
    end

    # A retried request abandons its predecessor's `into: :self` response
    # without cancelling it, so every attempt but the last leaves its chunks
    # behind in a mailbox this library does not own.
    test "leaves no orphaned chunks behind in the caller's mailbox" do
      collector = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(collector, :kill) end)

      {port, fingerprint} = retrying_bridge(report_to: collector)

      capture_log(fn ->
        assert_raise Hue.Error, fn ->
          retrying_client(port, fingerprint) |> Events.stream() |> Enum.to_list()
        end
      end)

      refute_received {_reference, _payload}
    end

    test "the refusal still reaches the caller as the reason the bridge gave" do
      {port, fingerprint} = retrying_bridge()

      error =
        capture_log(fn ->
          error =
            assert_raise Hue.Error, fn ->
              retrying_client(port, fingerprint) |> Events.stream() |> Enum.to_list()
            end

          send(self(), {:error, error})
        end)

      assert is_binary(error)
      assert_received {:error, %Hue.Error{reason: :bridge_busy, status: 503}}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp client(port, fingerprint) do
    {:ok, client} =
      Hue.new("127.0.0.1",
        port: port,
        fingerprint: fingerprint,
        application_key: @application_key,
        retry: false
      )

    client
  end

  # 503 is a documented bridge answer, and it is one of the statuses Req's
  # default `:safe_transient` retries.
  defp retrying_bridge(options \\ []) do
    Hue.EventstreamServer.start(
      [],
      Keyword.merge(options,
        status: {503, "Service Unavailable"},
        body: ~s({"errors":[{"description":"bridge is busy"}]})
      )
    )
  end

  defp retrying_client(port, fingerprint) do
    {:ok, client} =
      Hue.new("127.0.0.1",
        port: port,
        fingerprint: fingerprint,
        application_key: @application_key,
        retry_delay: 0
      )

    client
  end

  defp frame(data), do: "id: 1:0\ndata: #{data}\n\n"

  defp envelope(type, resources) do
    frame(
      Jason.encode!([
        %{
          "creationtime" => "2026-08-06T15:50:32Z",
          "id" => "e",
          "type" => type,
          "data" => resources
        }
      ])
    )
  end

  defp fragments(binary, size) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:binary.list_to_bin/1)
  end
end
