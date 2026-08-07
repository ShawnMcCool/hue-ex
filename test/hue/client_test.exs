defmodule Hue.ClientTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge

  # Real SHA-256 digests, because a fingerprint is required to be one.
  @pin "21cdf48f5217f21923a498576d01c31d800424dafef70efc259f1e05134f3274"
  @other_pin "19b0176ff5be4461cf15626db089ad5ce1af401f6cc5798055522a9a04d466e1"

  test "new/2 builds a client for the bridge" do
    {:ok, client} = Hue.new("192.0.2.10", application_key: "secret-key")

    assert client.base_url == "https://192.0.2.10/clip/v2"
    assert client.application_key == "secret-key"
  end

  test "the application key never appears in inspect output" do
    {:ok, client} = Hue.new("192.0.2.10", application_key: "super-secret-value")

    refute inspect(client) =~ "super-secret-value"
    assert inspect(client) =~ "[REDACTED]"
  end

  test "unknown options are passed through to Req" do
    {:ok, client} = Hue.new("192.0.2.10", application_key: "k", receive_timeout: 2_000)

    assert client.req.options[:receive_timeout] == 2_000
  end

  test "a fingerprint is turned into pinned TLS options" do
    {:ok, client} = Hue.new("192.0.2.10", application_key: "k", fingerprint: @pin)

    transport = client.req.options[:connect_options][:transport_opts]
    assert transport[:verify] == :verify_peer
  end

  describe "the base url" do
    test "omits the port when it is the default" do
      {:ok, explicit} = Hue.new("192.0.2.10", port: 443)
      {:ok, implicit} = Hue.new("192.0.2.10")

      assert explicit.base_url == "https://192.0.2.10/clip/v2"
      assert implicit.base_url == "https://192.0.2.10/clip/v2"
    end

    test "carries a non-default port" do
      {:ok, client} = Hue.new("192.0.2.10", port: 8443)

      assert client.base_url == "https://192.0.2.10:8443/clip/v2"
    end

    test "takes a hostname as readily as an address" do
      {:ok, client} = Hue.new("philips-hue.local")

      assert client.base_url == "https://philips-hue.local/clip/v2"
    end

    # The naive way to drop a default port is to strip ":443/" from the string,
    # which also mangles a host that legitimately contains it.
    test "does not mangle a host whose name contains the default port" do
      {:ok, client} = Hue.new("bridge-443.local", port: 8443)

      assert client.base_url == "https://bridge-443.local:8443/clip/v2"
    end

    # Bridge.Info declares pos_integer(); anything else built a url like
    # "https://h:/clip/v2" and only failed much later, at connect time.
    test "refuses a port that is not a positive integer" do
      for port <- [nil, 0, -1, "8443", :eight] do
        assert_raise ArgumentError, ~r/positive integer/, fn ->
          Hue.new("192.0.2.10", port: port)
        end
      end
    end
  end

  # The pin a user has is the one openssl printed: uppercase, colon separated.
  # Refusing it would be reported as :certificate_changed, which this library
  # documents as interception.
  describe "the form a fingerprint is written in" do
    test "does not change the pin, whichever form it arrives in" do
      for form <- [@pin, String.upcase(@pin), colon_separated(@pin), "  #{@pin}\n"] do
        {:ok, client} = Hue.new("192.0.2.10", fingerprint: form)

        assert client.fingerprint == @pin
        assert {_fun, @pin} = transport_options(client)[:verify_fun]
      end
    end

    test "does not make a restated pin look like a disagreement" do
      bridge = %Bridge.Info{host: "192.0.2.10", fingerprint: @pin}
      openssl = @pin |> String.upcase() |> colon_separated()

      assert {:ok, client} = Hue.from_bridge(bridge, fingerprint: openssl)
      assert client.fingerprint == @pin
    end

    test "does not let a bridge pinned in one form arrive in another" do
      bridge = %Bridge.Info{host: "192.0.2.10", fingerprint: String.upcase(@pin)}

      {:ok, client} = Hue.from_bridge(bridge)

      assert client.fingerprint == @pin
    end

    test "is still required to be a whole digest" do
      assert_raise ArgumentError, ~r/64-character hex string/, fn ->
        Hue.new("192.0.2.10", fingerprint: "abc")
      end
    end
  end

  describe "the TLS options a client carries" do
    test "are unverified before a fingerprint exists to pin to" do
      {:ok, client} = Hue.new("192.0.2.10")

      assert transport_options(client)[:verify] == :verify_none
    end

    test "are unverified when verification is explicitly declined" do
      {:ok, client} = Hue.new("192.0.2.10", verify: :none)

      assert transport_options(client)[:verify] == :verify_none
    end

    test "supply no CA store when pinned, because trust comes from the pin" do
      {:ok, client} = Hue.new("192.0.2.10", fingerprint: @pin)

      assert transport_options(client)[:cacerts] == []
      assert {_fun, @pin} = transport_options(client)[:verify_fun]
    end

    test "reject a fingerprint Hue.Transport would refuse" do
      assert_raise ArgumentError, ~r/hex string/, fn ->
        Hue.new("192.0.2.10", fingerprint: "not-hex-at-all")
      end
    end

    test "reject verify: :none alongside a fingerprint" do
      assert_raise ArgumentError, ~r/contradicts/, fn ->
        Hue.new("192.0.2.10", fingerprint: @pin, verify: :none)
      end
    end
  end

  # Silently dropping the caller's connect options, or silently dropping ours,
  # both end with pinning switched off by accident.
  describe "a caller who brings their own :connect_options" do
    test "keeps them alongside the pinned transport options" do
      {:ok, client} =
        Hue.new("192.0.2.10", fingerprint: @pin, connect_options: [timeout: 5_000])

      assert client.req.options[:connect_options][:timeout] == 5_000
      assert transport_options(client)[:verify] == :verify_peer
    end

    test "cannot replace the transport options, because that is where the pin lives" do
      assert_raise ArgumentError, ~r/transport_opts/, fn ->
        Hue.new("192.0.2.10",
          fingerprint: @pin,
          connect_options: [transport_opts: [verify: :verify_none]]
        )
      end
    end

    test "is told what to use instead" do
      assert_raise ArgumentError, ~r/:fingerprint/, fn ->
        Hue.new("192.0.2.10", connect_options: [transport_opts: [verify: :verify_none]])
      end
    end

    test "gets an ArgumentError rather than a FunctionClauseError for a non-keyword list" do
      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Hue.new("192.0.2.10", connect_options: %{transport_opts: []})
      end
    end
  end

  describe "from_bridge/2" do
    @describetag :capture_log

    test "carries the bridge's identity, pin, and port across" do
      bridge = %Bridge.Info{
        host: "192.0.2.10",
        port: 8443,
        bridge_id: "0011223344556677",
        fingerprint: @pin,
        discovered_by: :mdns
      }

      {:ok, client} = Hue.from_bridge(bridge, application_key: "k")

      assert client.base_url == "https://192.0.2.10:8443/clip/v2"
      assert client.bridge_id == "0011223344556677"
      assert client.fingerprint == @pin
      assert client.application_key == "k"
      assert transport_options(client)[:verify] == :verify_peer
    end

    test "passes other options through to new/2" do
      bridge = %Bridge.Info{host: "192.0.2.10", fingerprint: @pin}

      {:ok, client} = Hue.from_bridge(bridge, receive_timeout: 2_000)

      assert client.req.options[:receive_timeout] == 2_000
    end

    # The bridge's fingerprint is the pinned, trusted value. An option that
    # disagrees with it is a mistake, and resolving it either way silently
    # would mean a client pinned to something nobody chose.
    test "refuses a fingerprint that disagrees with the pinned one" do
      bridge = %Bridge.Info{host: "192.0.2.10", fingerprint: @pin}

      assert_raise ArgumentError, ~r/pinned/, fn ->
        Hue.from_bridge(bridge, fingerprint: @other_pin)
      end
    end

    test "accepts a fingerprint that restates the pinned one" do
      bridge = %Bridge.Info{host: "192.0.2.10", fingerprint: @pin}

      assert {:ok, client} = Hue.from_bridge(bridge, fingerprint: @pin)
      assert client.fingerprint == @pin
    end

    test "takes a fingerprint from the options when the bridge has none yet" do
      bridge = %Bridge.Info{host: "192.0.2.10"}

      {:ok, client} = Hue.from_bridge(bridge, fingerprint: @pin)

      assert client.fingerprint == @pin
    end

    test "is unverified when neither the bridge nor the caller has a pin" do
      bridge = %Bridge.Info{host: "192.0.2.10"}

      {{:ok, client}, _log} = ExUnit.CaptureLog.with_log(fn -> Hue.from_bridge(bridge) end)

      assert transport_options(client)[:verify] == :verify_none
    end

    # "Unverified and says so" should not mean "inspect the struct". A bridge
    # that was never pinned is a downgrade to the trust level of every other
    # Hue client, and it happens at the moment a client is built rather than at
    # the moment a request fails.
    test "says out loud that it is building an unverified client" do
      bridge = %Bridge.Info{host: "192.0.2.10", bridge_id: "0011223344556677"}

      log = ExUnit.CaptureLog.capture_log(fn -> Hue.from_bridge(bridge) end)

      assert log =~ "192.0.2.10"
      assert log =~ "will not verify"
      assert log =~ "Hue.Discovery.identify/2"
    end

    test "says nothing when a pin is actually in force" do
      bridge = %Bridge.Info{host: "192.0.2.10", fingerprint: @pin}

      # Not `== ""`: async: true means a concurrently-running test's unrelated
      # warning can land in this capture too (ExUnit.CaptureLog broadcasts every
      # log event to every currently-active capture, VM-wide, with no per-process
      # attribution — see ExUnit.CaptureServer.log/2). Scope the refutation to
      # the one warning this describe block is about, not to total silence.
      log = ExUnit.CaptureLog.capture_log(fn -> Hue.from_bridge(bridge) end)

      refute log =~ "has no pinned fingerprint"
    end

    test "says nothing when the caller supplies the pin the bridge lacks" do
      bridge = %Bridge.Info{host: "192.0.2.10"}

      log = ExUnit.CaptureLog.capture_log(fn -> Hue.from_bridge(bridge, fingerprint: @pin) end)

      refute log =~ "has no pinned fingerprint"
    end

    test "defaults the port to 443, as Bridge.Info does" do
      bridge = %Bridge.Info{host: "192.0.2.10"}

      {:ok, client} = Hue.from_bridge(bridge)

      assert client.base_url == "https://192.0.2.10/clip/v2"
    end

    test "lets the caller override the port" do
      bridge = %Bridge.Info{host: "192.0.2.10", port: 8443}

      {:ok, client} = Hue.from_bridge(bridge, port: 9443)

      assert client.base_url == "https://192.0.2.10:9443/clip/v2"
    end
  end

  test "inspect shows the identifying fields and hides nothing else" do
    {:ok, client} =
      Hue.new("192.0.2.10",
        application_key: "k",
        bridge_id: "0011223344556677",
        fingerprint: @pin
      )

    output = inspect(client)

    assert output =~ "#Hue.Client<"
    assert output =~ "https://192.0.2.10/clip/v2"
    assert output =~ "0011223344556677"
    assert output =~ ~s(fingerprint: "#{@pin}")
  end

  test "a client without an application key inspects without a redaction marker" do
    {:ok, client} = Hue.new("192.0.2.10")

    refute inspect(client) =~ "[REDACTED]"
  end

  defp transport_options(client) do
    client.req.options[:connect_options][:transport_opts]
  end

  # `21cdf4…` -> `21:cd:f4:…`, the layout openssl prints a digest in.
  defp colon_separated(fingerprint) do
    fingerprint |> String.graphemes() |> Enum.chunk_every(2) |> Enum.map_join(":", &Enum.join/1)
  end
end

# The options Hue.Transport produces only matter if they reach the socket
# unchanged. They travel Req -> Finch -> Mint, and Mint supplies its own
# cacerts and customize_hostname_check for HTTPS. If its merge ever wins,
# `cacerts: []` stops holding and the pin stops being consulted -- which is the
# exact bypass Task 4 closed.
#
# Sync, because it traces `:ssl.connect/4` process-wide.
defmodule Hue.ClientTransportTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  describe "the options that reach the socket" do
    test "are ours, not Mint's" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()
      port = Hue.Certificates.start_bridge_https_listener()
      {:ok, client} = Hue.new("127.0.0.1", port: port, fingerprint: fingerprint, retry: false)

      options = capture_ssl_connect_options(fn -> get(client) end)

      assert options[:verify] == :verify_peer
      assert options[:cacerts] == []
      refute Keyword.has_key?(options, :cacertfile)
      assert options[:depth] == 0
      assert {&Hue.Transport.verify_pinned/4, fingerprint} == options[:verify_fun]

      match_fun = options[:customize_hostname_check][:match_fun]
      assert Function.info(match_fun, :module) == {:module, Hue.Transport}
    end

    # Proves the assertion above is not vacuous: strip our `cacerts` and Mint
    # fills the gap with the system trust store, which is what let a
    # publicly-trusted certificate through without the pin ever being checked.
    test "would otherwise be Mint's, which is the whole hazard" do
      port = Hue.Certificates.start_bridge_https_listener()

      options =
        capture_ssl_connect_options(fn ->
          Req.get(
            url: "https://127.0.0.1:#{port}/clip/v2/resource",
            connect_options: [transport_opts: [verify: :verify_peer]],
            retry: false
          )
        end)

      assert :public_key.cacerts_get() != []
      assert options[:cacerts] != []
      assert length(options[:cacerts]) == length(:public_key.cacerts_get())
    end
  end

  describe "a real request through the full stack" do
    test "reaches a bridge whose certificate matches the pin" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()
      port = Hue.Certificates.start_bridge_https_listener()
      {:ok, client} = Hue.new("127.0.0.1", port: port, fingerprint: fingerprint, retry: false)

      assert {:ok, response} = get(client)
      assert response.status == 200
      assert response.body == %{"data" => []}
    end

    test "is refused when the certificate is not the pinned one" do
      {_other, wrong_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")
      port = Hue.Certificates.start_bridge_https_listener()

      {:ok, client} =
        Hue.new("127.0.0.1", port: port, fingerprint: wrong_fingerprint, retry: false)

      assert {:error, exception} = get(client)
      assert inspect(exception) =~ "certificate_changed"
    end

    # The reviewer's case: the pin a user actually has is what openssl printed.
    # Before normalisation this failed the handshake with :certificate_changed,
    # telling the user they were being intercepted for a formatting difference.
    test "reaches a bridge pinned in the form openssl prints" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate()

      openssl =
        fingerprint
        |> String.upcase()
        |> String.graphemes()
        |> Enum.chunk_every(2)
        |> Enum.map_join(":", &Enum.join/1)

      port = Hue.Certificates.start_bridge_https_listener()
      {:ok, client} = Hue.new("127.0.0.1", port: port, fingerprint: openssl, retry: false)

      assert {:ok, response} = get(client)
      assert response.status == 200
    end

    test "reaches the real hardware shape, a leaf signed by an absent authority" do
      {_der, fingerprint} = Hue.Certificates.bridge_certificate("00178800AABBCCDD")
      port = Hue.Certificates.start_bridge_https_listener("00178800AABBCCDD")
      {:ok, client} = Hue.new("127.0.0.1", port: port, fingerprint: fingerprint, retry: false)

      assert {:ok, response} = get(client)
      assert response.status == 200
    end

    test "is unverified, and so connects to anything, without a pin" do
      port = Hue.Certificates.start_bridge_https_listener()
      {:ok, client} = Hue.new("127.0.0.1", port: port, retry: false)

      assert {:ok, response} = get(client)
      assert response.status == 200
    end

    # The pin firing is the most security-relevant thing this library can
    # report, and it arrives wrapped in a TLS alert whose reason is a tuple.
    # Hue.Resource used to raise FunctionClauseError on it outright.
    test "a refused pin reaches Hue.Resource as :certificate_changed, not as a raise" do
      {_other, wrong_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")
      port = Hue.Certificates.start_bridge_https_listener()

      {:ok, client} =
        Hue.new("127.0.0.1", port: port, fingerprint: wrong_fingerprint, retry: false)

      assert {:error, %Hue.Error{reason: :certificate_changed} = error} =
               Hue.Resource.list(client, :light)

      assert Exception.message(error) =~ "certificate_changed"
    end

    test "a refused pin reaches Hue.Pairing as :certificate_changed too" do
      {_other, wrong_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")
      port = Hue.Certificates.start_bridge_https_listener()

      bridge = %Hue.Bridge.Info{host: "127.0.0.1", port: port, fingerprint: wrong_fingerprint}

      assert {:error, %Hue.Error{reason: :certificate_changed}} =
               Hue.Pairing.pair(bridge, retry: false)
    end

    test "an ordinary transport failure is still an ordinary transport failure" do
      {:ok, socket} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      {:ok, client} = Hue.new("127.0.0.1", port: port, retry: false)

      assert {:error, %Hue.Error{reason: reason}} = Hue.Resource.list(client, :light)
      assert reason in [:econnrefused, :timeout]
    end
  end

  defp get(client) do
    Req.get(client.req, url: client.base_url <> "/resource")
  end

  # The options `:ssl.connect/4` is actually called with, which is the only
  # place the whole merge can be read back.
  #
  # Two things make this silently observe nothing if they are got wrong, so
  # both are pinned down here: loading a module clears its trace patterns, so
  # `:ssl` is loaded first and the pattern is asserted to have stuck; and a
  # tracer does not trace itself, so the request runs off this process —
  # Finch establishes the connection in whichever process calls it.
  defp capture_ssl_connect_options(request) do
    Code.ensure_loaded!(:ssl)
    :erlang.trace_pattern({:ssl, :connect, 4}, true, [:global])
    :erlang.trace(:all, true, [:call])
    assert :erlang.trace_info({:ssl, :connect, 4}, :traced) == {:traced, :global}

    try do
      request |> Task.async() |> Task.await(10_000)

      receive do
        {:trace, _pid, :call, {:ssl, :connect, [_address, _port, options, _timeout]}} -> options
      after
        5_000 -> flunk("no call to :ssl.connect/4 was traced")
      end
    after
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({:ssl, :connect, 4}, false, [:global])
    end
  end
end
