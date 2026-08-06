defmodule Hue.DiscoveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Hue.Bridge
  alias Hue.Certificates
  alias Hue.Discovery
  alias Hue.Transport

  @bridge_certificate "0011223344556677"
  @service ~c"_hue._tcp.local"
  @instance ~c"Philips Hue - AABBCC._hue._tcp.local"
  @target ~c"Philips-hue.local"

  describe "identify/2" do
    test "confirms a candidate and captures its identity" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/api/config"

        Req.Test.json(conn, %{
          "name" => "Hue Bridge",
          "bridgeid" => "0011223344556677",
          "modelid" => "BSB002",
          "apiversion" => "1.78.0"
        })
      end)

      assert {:ok, %Bridge.Info{bridge_id: "0011223344556677", model_id: "BSB002"}} =
               Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__})
    end

    test "rejects a v1 bridge, which has no CLIP v2 at all" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"bridgeid" => "0011223344556677", "modelid" => "BSB001"})
      end)

      assert {:error, %Hue.Error{reason: :unsupported_bridge}} =
               Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__})
    end

    test "records the method that found the candidate, defaulting to manual" do
      stub_config(%{"bridgeid" => "0011223344556677", "modelid" => "BSB002"})

      assert {:ok, %Bridge.Info{discovered_by: :manual}} =
               Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__})

      assert {:ok, %Bridge.Info{discovered_by: :cloud}} =
               Discovery.identify("192.0.2.10",
                 discovered_by: :cloud,
                 plug: {Req.Test, __MODULE__}
               )
    end

    test "carries the port through onto the bridge it returns" do
      stub_config(%{"bridgeid" => "0011223344556677", "modelid" => "BSB002"})

      assert {:ok, %Bridge.Info{host: "192.0.2.10", port: 8443}} =
               Discovery.identify("192.0.2.10", port: 8443, plug: {Req.Test, __MODULE__})
    end

    test "a stubbed request leaves the fingerprint empty rather than faking a pin" do
      stub_config(%{"bridgeid" => "0011223344556677", "modelid" => "BSB002"})

      assert {:ok, bridge} = Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__})
      refute bridge.fingerprint

      # And the client built from it must be honest about being unverified --
      # in the struct and out loud.
      {{:ok, client}, log} = ExUnit.CaptureLog.with_log(fn -> Hue.from_bridge(bridge) end)
      refute client.fingerprint
      assert log =~ "will not verify"
    end

    test "a stub cannot conjure a pin, but a caller-supplied one is carried through" do
      stub_config(%{"bridgeid" => "0011223344556677", "modelid" => "BSB002"})
      pin = String.duplicate("ab", 32)

      assert {:ok, bridge} =
               Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__}, fingerprint: pin)

      assert bridge.fingerprint == pin
    end

    test "reports a 200 that is not a bridge at all" do
      stub_config(%{"hello" => "i am a printer"})

      assert {:error, %Hue.Error{reason: :unexpected_response}} =
               Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__})
    end

    test "reports a body that is not JSON" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "<html>nope</html>") end)

      assert {:error, %Hue.Error{reason: :unexpected_response}} =
               Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__})
    end

    test "reports a non-200 status" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, %Hue.Error{reason: :bridge_busy, status: 503}} =
               Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__}, retry: false)
    end

    test "reports a transport failure instead of vanishing" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Hue.Error{reason: :econnrefused}} =
               Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__}, retry: false)
    end
  end

  describe "identify/2 against a real TLS listener" do
    test "pins the certificate the server actually presented" do
      {der, expected} = Certificates.bridge_certificate(@bridge_certificate)

      port =
        Certificates.start_bridge_https_listener(@bridge_certificate,
          body: ~s({"bridgeid":"0011223344556677","modelid":"BSB002"})
        )

      assert {:ok, bridge} = Discovery.identify("127.0.0.1", port: port, retry: false)

      assert bridge.fingerprint == expected
      assert bridge.fingerprint == Transport.fingerprint(der)
      assert bridge.bridge_id == "0011223344556677"
      assert bridge.port == port
    end

    test "the pinned bridge builds a client that keeps working against the same certificate" do
      port =
        Certificates.start_bridge_https_listener(@bridge_certificate,
          body: ~s({"bridgeid":"0011223344556677","modelid":"BSB002"})
        )

      assert {:ok, bridge} = Discovery.identify("127.0.0.1", port: port, retry: false)
      assert {:ok, client} = Hue.from_bridge(bridge, retry: false)
      assert client.fingerprint == bridge.fingerprint

      assert {:ok, %Req.Response{status: 200}} =
               Req.request(Req.merge(client.req, method: :get, url: client.base_url))
    end

    test "refuses when the certificate's common name disagrees with the reported bridge id" do
      port =
        Certificates.start_bridge_https_listener(@bridge_certificate,
          body: ~s({"bridgeid":"FFFFFFFFFFFFFFFF","modelid":"BSB002"})
        )

      assert {:error, %Hue.Error{reason: :bridge_identity_mismatch} = error} =
               Discovery.identify("127.0.0.1", port: port, retry: false)

      assert Exception.message(error) =~ "0011223344556677"
      assert Exception.message(error) =~ "FFFFFFFFFFFFFFFF"
    end

    test "a supplied fingerprint is honoured instead of re-deciding trust" do
      {_der, fingerprint} = Certificates.bridge_certificate(@bridge_certificate)

      port =
        Certificates.start_bridge_https_listener(@bridge_certificate,
          body: ~s({"bridgeid":"0011223344556677","modelid":"BSB002"})
        )

      assert {:ok, bridge} =
               Discovery.identify("127.0.0.1",
                 port: port,
                 fingerprint: fingerprint,
                 retry: false
               )

      assert bridge.fingerprint == fingerprint
    end

    test "a supplied fingerprint that does not match fails the request" do
      wrong = String.duplicate("ab", 32)

      port =
        Certificates.start_bridge_https_listener(@bridge_certificate,
          body: ~s({"bridgeid":"0011223344556677","modelid":"BSB002"})
        )

      assert {:error, %Hue.Error{}} =
               Discovery.identify("127.0.0.1", port: port, fingerprint: wrong, retry: false)
    end

    test "reports the failure when nothing is listening" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert {:error, %Hue.Error{reason: reason}} =
               Discovery.identify("127.0.0.1", port: port, timeout: 1_000, retry: false)

      assert reason in [:econnrefused, :timeout]
    end

    # :receive_timeout bounds waiting for a response, not connecting and
    # handshaking. Before the connect phase was bounded too, a 1000ms budget
    # here took 5115ms, governed by Finch's five-second default.
    test "stays inside its budget when the connection after the capture is black-holed" do
      port = Certificates.start_stalling_bridge_listener()

      {elapsed, result} =
        :timer.tc(fn ->
          Discovery.identify("127.0.0.1", port: port, timeout: 500, retry: false)
        end)

      assert {:error, %Hue.Error{}} = result
      assert div(elapsed, 1_000) < 2_000
    end

    test "the v1 bridge is rejected even when its certificate pins cleanly" do
      port =
        Certificates.start_bridge_https_listener(@bridge_certificate,
          body: ~s({"bridgeid":"0011223344556677","modelid":"BSB001"})
        )

      assert {:error, %Hue.Error{reason: :unsupported_bridge}} =
               Discovery.identify("127.0.0.1", port: port, retry: false)
    end
  end

  describe "identity_agrees?/2" do
    test "agrees when the common name is the bridge id, whatever the case" do
      assert Discovery.identity_agrees?("0011223344556677", "0011223344556677")

      assert Discovery.identity_agrees?(
               "0011223344556677",
               "0011223344556677" |> String.downcase()
             )

      assert Discovery.identity_agrees?("001788fffeae1b58", "001788FFFEAE1B58")
    end

    test "disagrees when they name different bridges" do
      refute Discovery.identity_agrees?("0011223344556677", "FFFFFFFFFFFFFFFF")
    end

    test "an absent common name is not a disagreement" do
      assert Discovery.identity_agrees?(nil, "0011223344556677")
      assert Discovery.identity_agrees?("0011223344556677", nil)
    end

    # U+FB00, LATIN SMALL LIGATURE FF, is what tells :ascii folding apart from
    # full Unicode folding: String.upcase/1 expands it to "FF", so a plain
    # upcase would call this pair equal. A comparison that claims to be about
    # hex must be about hex, and this is the test that fails if the `:ascii`
    # argument is ever dropped.
    test "folding is ASCII-only, so a ligature is not two hex digits" do
      refute Discovery.identity_agrees?("001788ﬀfeae1b58", "001788FFFEAE1B58")
      assert Discovery.identity_agrees?("001788ﬀfeae1b58", "001788ﬀFEAE1B58")
    end
  end

  describe "merge/1" do
    test "deduplicates by bridge id and prefers the local method" do
      found = [
        %Bridge.Info{host: "192.0.2.10", bridge_id: "AAA", discovered_by: :cloud},
        %Bridge.Info{host: "192.0.2.10", bridge_id: "AAA", discovered_by: :mdns},
        %Bridge.Info{host: "192.0.2.11", bridge_id: "BBB", discovered_by: :cloud}
      ]

      merged = Discovery.merge(found)

      assert length(merged) == 2
      assert Enum.find(merged, &(&1.bridge_id == "AAA")).discovered_by == :mdns
    end

    test "fills the preferred record's gaps from the ones it displaces" do
      found = [
        %Bridge.Info{
          host: "192.0.2.10",
          bridge_id: "AAA",
          model_id: "BSB002",
          discovered_by: :cloud
        },
        %Bridge.Info{host: "192.0.2.10", bridge_id: "AAA", discovered_by: :mdns}
      ]

      assert [%Bridge.Info{discovered_by: :mdns, model_id: "BSB002"}] = Discovery.merge(found)
    end

    test "keeps candidates that carry no bridge id apart by host" do
      found = [
        %Bridge.Info{host: "192.0.2.10", discovered_by: :mdns},
        %Bridge.Info{host: "192.0.2.10", discovered_by: :mdns},
        %Bridge.Info{host: "192.0.2.11", discovered_by: :mdns}
      ]

      assert Discovery.merge(found) |> length() == 2
    end

    test "drops an anonymous candidate for a host already identified" do
      found = [
        %Bridge.Info{host: "192.0.2.10", bridge_id: "AAA", discovered_by: :cloud},
        %Bridge.Info{host: "192.0.2.10", discovered_by: :mdns}
      ]

      assert [%Bridge.Info{bridge_id: "AAA"}] = Discovery.merge(found)
    end

    test "prefers a manually supplied record over a cloud one" do
      found = [
        %Bridge.Info{host: "192.0.2.10", bridge_id: "AAA", discovered_by: :cloud},
        %Bridge.Info{host: "192.0.2.10", bridge_id: "AAA", discovered_by: :manual}
      ]

      assert [%Bridge.Info{discovered_by: :manual}] = Discovery.merge(found)
    end

    test "an empty list merges to an empty list" do
      assert Discovery.merge([]) == []
    end
  end

  describe "parse_cloud_response/1" do
    test "reads the discovery endpoint's shape" do
      body = [%{"id" => "001788fffeae1b58", "internalipaddress" => "192.0.2.10", "port" => 443}]

      assert [%Bridge.Info{host: "192.0.2.10", port: 443, discovered_by: :cloud}] =
               Discovery.parse_cloud_response(body)
    end

    test "upcases the id, which the endpoint reports in lower case" do
      body = [%{"id" => "001788fffeae1b58", "internalipaddress" => "192.0.2.10"}]

      assert [%Bridge.Info{bridge_id: "001788FFFEAE1B58"}] = Discovery.parse_cloud_response(body)
    end

    test "defaults the port when the entry omits it" do
      body = [%{"id" => "001788fffeae1b58", "internalipaddress" => "192.0.2.10"}]

      assert [%Bridge.Info{port: 443}] = Discovery.parse_cloud_response(body)
    end

    # Same reason as identity_agrees?/2: full Unicode upcasing would turn the
    # U+FB00 ligature into the two hex digits "FF" and manufacture an id the
    # endpoint never reported.
    test "upcasing the id is ASCII-only, so it invents no hex digits" do
      body = [%{"id" => "001788ﬀfeae1b58", "internalipaddress" => "192.0.2.10"}]

      assert [%Bridge.Info{bridge_id: bridge_id}] = Discovery.parse_cloud_response(body)
      assert bridge_id == "001788ﬀFEAE1B58"
      refute bridge_id == "001788FFFEAE1B58"
    end

    test "skips entries with no address" do
      body = [%{"id" => "001788fffeae1b58"}, %{"internalipaddress" => "192.0.2.10"}]

      assert [%Bridge.Info{host: "192.0.2.10"}] = Discovery.parse_cloud_response(body)
    end

    test "an empty response is an empty list, not an error" do
      assert Discovery.parse_cloud_response([]) == []
    end
  end

  describe "parse_mdns_packet/1" do
    test "finds the address in the additional records, where responders put it" do
      packet = mdns_response(a_records: [{@target, {192, 0, 2, 10}}])

      assert Discovery.parse_mdns_packet(packet) == ["192.0.2.10"]
    end

    test "finds an address in the answer section too" do
      packet =
        :inet_dns.encode(
          :inet_dns.make_msg(
            header: :inet_dns.make_header(id: 0, qr: true, opcode: :query, aa: true),
            anlist: [
              :inet_dns.make_rr(
                domain: @target,
                type: :a,
                class: :in,
                ttl: 120,
                data: {192, 0, 2, 20}
              )
            ]
          )
        )

      assert Discovery.parse_mdns_packet(packet) == ["192.0.2.20"]
    end

    test "ignores the PTR, SRV, and TXT records that arrive alongside" do
      packet = mdns_response(a_records: [])

      assert Discovery.parse_mdns_packet(packet) == []
    end

    test "deduplicates repeated addresses" do
      packet =
        mdns_response(
          a_records: [
            {@target, {192, 0, 2, 10}},
            {~c"other.local", {192, 0, 2, 10}},
            {~c"other.local", {192, 0, 2, 11}}
          ]
        )

      assert Discovery.parse_mdns_packet(packet) == ["192.0.2.10", "192.0.2.11"]
    end

    test "a packet that is not DNS at all yields nothing" do
      assert Discovery.parse_mdns_packet("not a dns packet") == []
      assert Discovery.parse_mdns_packet("") == []
    end
  end

  describe "query_packet/0" do
    test "asks one PTR question for the Hue service" do
      assert {:ok, message} = :inet_dns.decode(Discovery.query_packet())

      assert [question] = :inet_dns.msg(message, :qdlist)
      assert :inet_dns.dns_query(question, :domain) == @service
      assert :inet_dns.dns_query(question, :type) == :ptr
      assert :inet_dns.dns_query(question, :class) == :in
    end

    test "is a query, not a response" do
      {:ok, message} = :inet_dns.decode(Discovery.query_packet())
      header = :inet_dns.msg(message, :header)

      refute :inet_dns.header(header, :qr)
      assert :inet_dns.header(header, :opcode) == :query
    end
  end

  describe "collect_answers/2" do
    test "reads the addresses out of the answers it receives" do
      socket = open_socket()

      send_to(socket, mdns_response(a_records: [{@target, {192, 0, 2, 10}}]))
      send_to(socket, mdns_response(a_records: [{@target, {192, 0, 2, 11}}]))

      found = Discovery.collect_answers(socket, 300)

      assert Enum.map(found, & &1.host) |> Enum.sort() == ["192.0.2.10", "192.0.2.11"]
      assert Enum.all?(found, &(&1.discovered_by == :mdns))
    end

    test "deduplicates a host that several packets name" do
      socket = open_socket()
      packet = mdns_response(a_records: [{@target, {192, 0, 2, 10}}])

      for _ <- 1..5, do: send_to(socket, packet)

      assert [%Bridge.Info{host: "192.0.2.10"}] = Discovery.collect_answers(socket, 300)
    end

    # The bug this replaced restarted the timeout on every packet, so a
    # steady trickle of them extended the budget without bound.
    test "the budget is absolute, not per packet" do
      socket = open_socket()
      packet = mdns_response(a_records: [{@target, {192, 0, 2, 10}}])

      flooder =
        spawn_link(fn ->
          Stream.repeatedly(fn -> send_to(socket, packet) end) |> Enum.take(5_000)
        end)

      {elapsed, found} = :timer.tc(fn -> Discovery.collect_answers(socket, 200) end)
      Process.unlink(flooder)
      Process.exit(flooder, :kill)

      assert [%Bridge.Info{host: "192.0.2.10"}] = found
      assert div(elapsed, 1_000) < 1_000
    end

    test "an exhausted budget returns what it already had" do
      socket = open_socket()

      assert Discovery.collect_answers(socket, 0) == []
    end

    test "ignores packets that are not DNS at all" do
      socket = open_socket()

      send_to(socket, "this is not a dns packet")
      send_to(socket, mdns_response(a_records: [{@target, {192, 0, 2, 10}}]))

      assert [%Bridge.Info{host: "192.0.2.10"}] = Discovery.collect_answers(socket, 300)
    end
  end

  describe "discover/1" do
    # The multicast path itself: opening the socket, sending the query, running
    # the collection to its deadline, closing. A responder may or may not exist
    # on the machine running this, so the assertions are about shape and time,
    # and the stub catches any candidate a real bridge might contribute rather
    # than letting the suite reach the network.
    test "the multicast path runs end to end and stays inside its budget" do
      stub_config(%{"bridgeid" => "0011223344556677", "modelid" => "BSB002"})

      {elapsed, result} =
        :timer.tc(fn ->
          Discovery.discover(
            cloud: false,
            timeout: 200,
            plug: {Req.Test, __MODULE__},
            retry: false
          )
        end)

      assert {:ok, bridges} = result
      assert Enum.all?(bridges, &(&1.discovered_by == :mdns))
      assert div(elapsed, 1_000) < 3_000
    end

    test "does no network work at all when both methods are disabled" do
      assert {:ok, []} = Discovery.discover(mdns: false, cloud: false)
    end

    test "finds and confirms a bridge through the cloud endpoint" do
      Req.Test.stub(__MODULE__, &discovery_network/1)

      assert {:ok, [bridge]} =
               Discovery.discover(mdns: false, plug: {Req.Test, __MODULE__}, timeout: 1_000)

      assert bridge.host == "192.0.2.10"
      assert bridge.bridge_id == "001788FFFEAE1B58"
      assert bridge.discovered_by == :cloud
    end

    test "reports, rather than silently drops, a candidate it cannot confirm" do
      Req.Test.stub(__MODULE__, fn
        %{host: "discovery.meethue.com"} = conn ->
          Req.Test.json(conn, [%{"id" => "aaa", "internalipaddress" => "192.0.2.10"}])

        conn ->
          Req.Test.transport_error(conn, :econnrefused)
      end)

      log =
        capture_log(fn ->
          assert {:ok, []} =
                   Discovery.discover(
                     mdns: false,
                     plug: {Req.Test, __MODULE__},
                     timeout: 1_000,
                     retry: false
                   )
        end)

      assert log =~ "192.0.2.10"
      assert log =~ "econnrefused"
    end

    test "an unreachable cloud endpoint degrades to no candidates rather than an error" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :nxdomain) end)

      assert {:ok, []} =
               Discovery.discover(
                 mdns: false,
                 plug: {Req.Test, __MODULE__},
                 timeout: 1_000,
                 retry: false
               )
    end

    test "skipping the cloud endpoint means it is never contacted" do
      Req.Test.stub(__MODULE__, fn conn ->
        flunk("no request should have been made, got #{conn.host}#{conn.request_path}")
      end)

      assert {:ok, []} =
               Discovery.discover(
                 mdns: false,
                 cloud: false,
                 plug: {Req.Test, __MODULE__},
                 timeout: 1_000
               )
    end
  end

  # An ordinary unicast socket standing in for the multicast one. Nothing in
  # collect_answers/2 cares how the packets arrived, which is the point of it
  # taking an already-open socket.
  defp open_socket do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(socket) end)
    socket
  end

  defp send_to(socket, packet) do
    {:ok, port} = :inet.port(socket)
    {:ok, sender} = :gen_udp.open(0, [:binary, active: false])
    :gen_udp.send(sender, {127, 0, 0, 1}, port, packet)
    :gen_udp.close(sender)
  end

  defp stub_config(body) do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)
  end

  defp discovery_network(%{host: "discovery.meethue.com"} = conn) do
    Req.Test.json(conn, [
      %{"id" => "001788fffeae1b58", "internalipaddress" => "192.0.2.10", "port" => 443}
    ])
  end

  defp discovery_network(conn) do
    assert conn.request_path == "/api/config"
    Req.Test.json(conn, %{"bridgeid" => "001788FFFEAE1B58", "modelid" => "BSB002"})
  end

  defp mdns_response(options) do
    a_records =
      for {domain, address} <- Keyword.fetch!(options, :a_records) do
        :inet_dns.make_rr(domain: domain, type: :a, class: :in, ttl: 120, data: address)
      end

    :inet_dns.encode(
      :inet_dns.make_msg(
        header: :inet_dns.make_header(id: 0, qr: true, opcode: :query, aa: true),
        qdlist: [:inet_dns.make_dns_query(domain: @service, type: :ptr, class: :in)],
        anlist: [
          :inet_dns.make_rr(domain: @service, type: :ptr, class: :in, ttl: 120, data: @instance)
        ],
        arlist:
          [
            :inet_dns.make_rr(
              domain: @instance,
              type: :srv,
              class: :in,
              ttl: 120,
              data: {0, 0, 443, @target}
            ),
            :inet_dns.make_rr(
              domain: @instance,
              type: :txt,
              class: :in,
              ttl: 120,
              data: [~c"bridgeid=AABBCC"]
            )
          ] ++ a_records
      )
    )
  end
end
