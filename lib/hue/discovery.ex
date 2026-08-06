defmodule Hue.Discovery do
  @moduledoc """
  Finds Hue bridges, by three methods, because no single one is sufficient.

  | Method | Works on | Fails on |
  |---|---|---|
  | mDNS | A flat home LAN — the common case | Routed subnets, VLANs, containers |
  | Cloud | Anything sharing a public IP | No internet access |
  | Manual | Always | — |

  mDNS is link-local multicast and does not cross a router. On a network where
  the bridge sits behind a different subnet than the client — double-NAT behind
  an ISP router, an IoT VLAN, a container — it returns nothing at all, with no
  error to explain why. This library was developed on exactly such a network:
  host on `192.168.68.0/22`, bridge on `192.168.178.146`, a router in between.
  `avahi-browse` found nothing; the cloud endpoint answered instantly. That case
  is common enough that cloud discovery runs by default; disable it with
  `cloud: false`.

  Cloud discovery contacts `discovery.meethue.com`, which matches on public IP
  and returns local addresses. No credentials are involved, but Signify learns
  the requesting IP.

  Whatever the method, every candidate is confirmed by `identify/2` before it is
  returned, and confirming is also where the certificate is pinned.

  ## First contact is the trust decision

  A bridge's certificate cannot be verified — see `Hue.Transport` for why — so
  the library pins it instead, SSH-style, and `identify/2` is the single moment
  that pin is chosen. It:

    1. reads the certificate with `Hue.Transport.capture_certificate/3`,
    2. requests `GET /api/config` **pinned to that certificate**, so the bridge
       id it learns comes from the same endpoint the pin describes,
    3. rejects `BSB001`, the v1 bridge, which has no CLIP v2 API at all,
    4. checks the certificate's common name against the reported bridge id, and
    5. returns a `Hue.Bridge.Info` carrying host, port, bridge id, model, and
       fingerprint.

  Everything after that — `Hue.from_bridge/2`, `Hue.Pairing.pair/2`,
  `Hue.Resource` — is pinned to that fingerprint.

  Step 2 is why the capture comes first rather than after. A bridge id read over
  an unverified connection describes whatever answered; read over a connection
  pinned to the certificate just captured, it describes the holder of that
  certificate. The two statements then have to agree in step 4, and if they do
  not, `identify/2` returns `:bridge_identity_mismatch` rather than storing a
  pin under an identity it does not belong to.

  ## Stubbed requests do not produce a pin

  Pass `:plug` (or `:adapter`) and no TLS handshake happens, so there is no
  certificate to capture and none is invented: the returned bridge has
  `fingerprint: nil`, and a client built from it is unverified and says so.
  Nothing a stub can put on the wire produces a pin.

  A `:fingerprint` passed alongside a stub is still carried onto the result,
  because that is a value the caller supplied rather than one this library
  concluded from a stubbed connection. It is the same option `identify/2`
  documents for re-checking an already-trusted bridge, and it is not
  attacker-controllable.
  """

  require Logger

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Transport

  @cloud_url "https://discovery.meethue.com"
  @mdns_service ~c"_hue._tcp.local"
  @mdns_address {224, 0, 0, 251}
  @mdns_port 5353
  @default_timeout 5_000
  @default_port 443
  @task_grace 1_000
  @identify_phases 3
  @v1_model "BSB001"
  @config_path "/api/config"

  # Consumed by identify/2 itself; everything else is forwarded to Hue.new/2.
  @identify_options [:port, :discovered_by, :timeout]

  # Forwarded to the cloud request. Deliberately not :connect_options — the
  # caller's must never reach a request in this library, and the cloud endpoint
  # is an ordinary publicly-verifiable host that wants no help from us.
  @cloud_options [:plug, :adapter, :retry]

  # An option that replaces the transport means no real certificate exists.
  @stub_options [:plug, :adapter]

  @doc """
  Finds every reachable bridge, confirms each one, and pins its certificate.

  Runs the enabled methods concurrently, merges what they found, and confirms
  each candidate with `identify/2`. Only confirmed bridges come back, so every
  `Hue.Bridge.Info` in the list carries a bridge id and — unless the request was
  stubbed — a fingerprint.

  ## Options

    * `:cloud` — set `false` to skip the cloud endpoint. Defaults to `true`.
    * `:mdns` — set `false` to skip multicast. Defaults to `true`.
    * `:timeout` — the budget in milliseconds for **one phase of one thing**.
      Defaults to `#{@default_timeout}`. It bounds mDNS collection as a whole —
      answers are collected until an absolute deadline rather than restarting
      the clock per packet — and it bounds each of `identify/2`'s
      `#{@identify_phases}` phases. It is not a wall-clock ceiling on
      `discover/1`: finding runs concurrently with a budget of its own, and
      confirmation follows it, so a run against candidates that all stall takes
      roughly `#{@identify_phases + 1}` times the budget. Candidates are
      confirmed concurrently, so their number does not extend it.

  Every other option is forwarded to `identify/2`, and from there to `Hue.new/2`
  and `Req.new/1`.

  ## Candidates that could not be confirmed

  A candidate that answers neither the certificate capture nor `/api/config` is
  not returned — the list would otherwise contain entries with no bridge id and
  no pin, and `Hue.from_bridge/2` would happily build unverified clients from
  them. It is not discarded silently either: each one is logged at `:warning`
  with its address and the reason, because "found it, could not reach it" and
  "found nothing" call for completely different fixes and a caller who cannot
  tell them apart is stuck.
  """
  @spec discover(keyword()) :: {:ok, [Bridge.Info.t()]} | {:error, Error.t()}
  def discover(options \\ []) do
    {timeout, options} = Keyword.pop(options, :timeout, @default_timeout)
    {use_mdns?, options} = Keyword.pop(options, :mdns, true)
    {use_cloud?, options} = Keyword.pop(options, :cloud, true)

    candidates =
      [
        if(use_mdns?, do: fn -> mdns(timeout) end),
        if(use_cloud?, do: fn -> cloud(options, timeout) end)
      ]
      |> Enum.reject(&is_nil/1)
      |> run_concurrently(timeout)
      |> merge()

    {:ok, confirm(candidates, Keyword.put(options, :timeout, timeout))}
  end

  @doc """
  Confirms a candidate address is a CLIP v2 bridge, pins its certificate, and
  captures its identity.

  `GET #{@config_path}` needs no application key, which is what makes trust
  bootstrappable: it yields the bridge id needed to make sense of the
  certificate's common name.

  ## Options

    * `:port` — defaults to `#{@default_port}`.
    * `:timeout` — milliseconds allowed per phase, of which there are
      `#{@identify_phases}`: capturing the certificate, connecting and
      handshaking for the request, and waiting for the response. Defaults to
      `#{@default_timeout}`, so the worst case is that many times the budget.
      It sets `:receive_timeout` and `connect_options[:timeout]` unless the
      caller set them, because between them those are what bound the request —
      `:receive_timeout` alone leaves connecting and the handshake on Finch's
      five-second default, which ignores the budget entirely.
    * `:discovered_by` — recorded on the result. Defaults to `:manual`.
    * `:fingerprint` — an already-trusted pin. Given one, no certificate is
      captured and no trust decision is made: the request is pinned to it and
      fails if the bridge presents anything else. This is how to re-check a
      bridge you already know without re-deciding whether to trust it.

  Every other option is forwarded to `Hue.new/2` and from there to `Req.new/1`.

  ## Errors

    * `:unsupported_bridge` — a `#{@v1_model}`, the v1 bridge.
    * `:bridge_identity_mismatch` — the certificate's common name is not the
      bridge id the bridge reported.
    * `:unexpected_response` — a 200 that is not a bridge configuration.
    * anything `Hue.Error.from_response/4` or `Hue.Error.transport/2` produces.
  """
  @spec identify(String.t(), keyword()) :: {:ok, Bridge.Info.t()} | {:error, Error.t()}
  def identify(host, options \\ []) when is_binary(host) do
    {mine, client_options} = Keyword.split(options, @identify_options)
    port = Keyword.get(mine, :port, @default_port)
    timeout = Keyword.get(mine, :timeout, @default_timeout)
    client_options = bound_by(client_options, timeout)

    with {:ok, fingerprint, common_name} <- pin(host, port, timeout, client_options) do
      candidate = %{
        host: host,
        port: port,
        fingerprint: fingerprint,
        common_name: common_name,
        discovered_by: Keyword.get(mine, :discovered_by, :manual)
      }

      candidate
      |> read_config(client_options)
      |> interpret(candidate)
    end
  end

  @doc """
  Deduplicates candidates, preferring the locally-discovered record.

  A bridge found by both methods is one bridge. mDNS wins because it proves
  link-local reachability, which the cloud endpoint does not — it reports an
  address that the client may have no route to at all. Fields the winner is
  missing are filled from the records it displaced, so preferring mDNS never
  costs the bridge id only the cloud endpoint knows.

  Candidates that carry no bridge id — everything mDNS produces, which yields
  addresses and nothing else — are deduplicated by host instead, and dropped
  when a record that *does* carry an id already names that host.
  """
  @spec merge([Bridge.Info.t()]) :: [Bridge.Info.t()]
  def merge(bridges) when is_list(bridges) do
    {identified, anonymous} = Enum.split_with(bridges, & &1.bridge_id)

    identified = identified |> Enum.group_by(& &1.bridge_id) |> Enum.map(&best/1)
    known_hosts = MapSet.new(identified, & &1.host)

    anonymous =
      anonymous
      |> Enum.reject(&MapSet.member?(known_hosts, &1.host))
      |> Enum.group_by(& &1.host)
      |> Enum.map(&best/1)

    identified ++ anonymous
  end

  @doc """
  Whether a certificate's common name corroborates the bridge id the bridge
  reported. Pure.

  On real hardware the common name *is* the bridge id, so these are two
  independent statements of the same fact and they should agree. Compared
  case-insensitively: `/api/config` reports the id in upper case, the cloud
  endpoint in lower case, and a certificate in whichever its issuer chose.

  A `nil` on either side is not a disagreement. Absent corroboration and
  contradicted corroboration are different situations, and only the second one
  is evidence of anything.
  """
  @spec identity_agrees?(String.t() | nil, String.t() | nil) :: boolean()
  def identity_agrees?(nil, _bridge_id), do: true
  def identity_agrees?(_common_name, nil), do: true

  def identity_agrees?(common_name, bridge_id)
      when is_binary(common_name) and is_binary(bridge_id) do
    # :ascii, not full Unicode folding. String.upcase/1 expands U+FB00 to "FF",
    # so "001788\uFB00feae1b58" would equal "001788FFFEAE1B58" -- a comparison
    # that claims to be about hex should be about hex.
    String.upcase(common_name, :ascii) == String.upcase(bridge_id, :ascii)
  end

  @doc """
  Parses the cloud endpoint's response body. Pure.

  The live shape, captured 2026-08-06:

      [{"id":"001788fffeae1b58","internalipaddress":"192.168.178.146","port":443}]

  Note `id`, lower case, where `#{@config_path}` reports `bridgeid` upper case.
  Upcased here so the two agree.
  """
  @spec parse_cloud_response(list()) :: [Bridge.Info.t()]
  def parse_cloud_response(entries) when is_list(entries) do
    entries
    |> Enum.filter(&(is_map(&1) and is_binary(&1["internalipaddress"])))
    |> Enum.map(fn entry ->
      %Bridge.Info{
        host: entry["internalipaddress"],
        port: entry["port"] || @default_port,
        bridge_id: upcase(entry["id"]),
        discovered_by: :cloud
      }
    end)
  end

  @doc """
  Parses an mDNS response packet into addresses. Pure.

  Reads the answer, authority, **and additional** sections. A responder answers
  `#{@mdns_service}` with a PTR to the service instance and puts the SRV and A
  records in the additional section, so a parser that reads only `anlist` finds
  the instance name and no address at all.

  Only `A` records are extracted: the CLIP v2 API is IPv4-only in practice, and
  the SRV port is always 443, which is `Hue.Bridge.Info`'s default.

  Decoding is `:inet_dns`, which is undocumented `kernel` internals. Verified
  against OTP 28: `decode/1` defaults to mDNS mode, returns `{:ok, dns_rec}` or
  `{:error, :formerr}`, and `rr/2` reads `:type` and `:data` off a `dns_rr`.
  A packet it cannot decode yields `[]` — a malformed multicast packet from
  something else on the LAN is not this library's problem to report.
  """
  @spec parse_mdns_packet(binary()) :: [String.t()]
  def parse_mdns_packet(packet) when is_binary(packet) do
    case :inet_dns.decode(packet) do
      {:ok, message} ->
        [:anlist, :nslist, :arlist]
        |> Enum.flat_map(&:inet_dns.msg(message, &1))
        |> Enum.filter(&(:inet_dns.rr(&1, :type) == :a))
        |> Enum.map(&address_to_string(:inet_dns.rr(&1, :data)))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  The mDNS query this library multicasts: one PTR question for
  `#{@mdns_service}`. Pure.

  Built with `:inet_dns`'s `make_*` constructors rather than as positional
  tuples. The record shapes are undocumented and they move: on OTP 28
  `dns_header` carries nine fields and `dns_query` four, so the tuples this was
  first written with raise `FunctionClauseError`. The constructors are the only
  form that does not have to be re-verified against every release.
  """
  @spec query_packet() :: binary()
  def query_packet do
    :inet_dns.encode(
      :inet_dns.make_msg(
        header: :inet_dns.make_header(id: 0, qr: false, opcode: :query, rd: false),
        qdlist: [:inet_dns.make_dns_query(domain: @mdns_service, type: :ptr, class: :in)]
      )
    )
  end

  @doc """
  Reads mDNS answers from an already-open UDP socket until `timeout`
  milliseconds have passed, and returns what they name.

  `timeout` is a budget for the whole collection, not for each receive. The
  deadline is absolute for that reason: a responder answers across several
  packets, and restarting the clock on each one turns a 5s budget into 5s *per
  packet*, with no bound on the total.

  Separate from the socket that sends the query so that the collection loop can
  be driven over an ordinary unicast socket, which is the only way to test it
  without standing up a multicast responder.
  """
  @spec collect_answers(:gen_udp.socket(), non_neg_integer()) :: [Bridge.Info.t()]
  def collect_answers(socket, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    socket
    |> collect(deadline, [])
    |> Enum.map(&%Bridge.Info{host: &1, discovered_by: :mdns})
  end

  defp collect(socket, deadline, found) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.uniq(found)
    else
      receive_packet(socket, deadline, found, remaining)
    end
  end

  defp receive_packet(socket, deadline, found, remaining) do
    case :gen_udp.recv(socket, 0, remaining) do
      {:ok, {_address, _port, packet}} ->
        collect(socket, deadline, found ++ parse_mdns_packet(packet))

      {:error, _reason} ->
        Enum.uniq(found)
    end
  end

  # -- first contact ---------------------------------------------------------

  defp pin(host, port, timeout, client_options) do
    cond do
      client_options[:fingerprint] -> {:ok, client_options[:fingerprint], nil}
      stubbed?(client_options) -> {:ok, nil, nil}
      true -> capture(host, port, timeout)
    end
  end

  defp capture(host, port, timeout) do
    case Transport.capture_certificate(host, port, timeout: timeout) do
      {:ok, der} -> {:ok, Transport.fingerprint(der), Transport.common_name(der)}
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  defp stubbed?(client_options) do
    Enum.any?(@stub_options, &Keyword.has_key?(client_options, &1))
  end

  # Both halves of the request need bounding, and they are bounded by different
  # options. `:receive_timeout` covers waiting for a response and nothing else;
  # connecting and the TLS handshake are governed by `connect_options[:timeout]`,
  # which defaults to Finch's five seconds and would otherwise ignore the budget
  # entirely — a host that accepts the connection and then says nothing is
  # exactly the case where that shows.
  #
  # Both are `put_new`, so a caller who set either keeps it. `:connect_options`
  # is left untouched if it is not a keyword list, so `Hue.new/2` still raises
  # its own ArgumentError about it rather than a FunctionClauseError from here.
  defp bound_by(client_options, timeout) do
    client_options
    |> Keyword.put_new(:receive_timeout, timeout)
    |> Keyword.update(:connect_options, [timeout: timeout], fn given ->
      if Keyword.keyword?(given), do: Keyword.put_new(given, :timeout, timeout), else: given
    end)
  end

  # -- the pinned /api/config request ----------------------------------------

  defp read_config(candidate, client_options) do
    options =
      Keyword.merge(client_options, port: candidate.port, fingerprint: candidate.fingerprint)

    {:ok, client} = Hue.new(candidate.host, options)

    Req.request(
      Req.merge(client.req,
        method: :get,
        url: config_url(candidate.host, candidate.port),
        decode_body: false
      )
    )
  end

  # decode_body: false, so a non-2xx body reaches Error.from_response/4 as the
  # binary it documents — the bridge answers some failures with HTML.
  defp config_url(host, @default_port), do: "https://#{host}#{@config_path}"
  defp config_url(host, port), do: "https://#{host}:#{port}#{@config_path}"

  defp interpret({:ok, %Req.Response{status: 200, body: raw}}, candidate) do
    case Jason.decode(raw) do
      {:ok, config} -> configured(config, candidate)
      {:error, _reason} -> {:error, Error.transport(:unexpected_response, description: raw)}
    end
  end

  defp interpret({:ok, %Req.Response{} = response}, _candidate) do
    {:error, Error.from_response(response.status, response.body, content_type(response))}
  end

  defp interpret({:error, exception}, _candidate) do
    {:error, Error.from_transport(exception)}
  end

  defp configured(%{"modelid" => @v1_model}, _candidate) do
    {:error,
     %Error{
       reason: :unsupported_bridge,
       description: "#{@v1_model} is the v1 bridge and has no CLIP v2 API"
     }}
  end

  defp configured(%{"bridgeid" => bridge_id} = config, candidate) when is_binary(bridge_id) do
    if identity_agrees?(candidate.common_name, bridge_id) do
      {:ok,
       %Bridge.Info{
         host: candidate.host,
         port: candidate.port,
         bridge_id: bridge_id,
         model_id: config["modelid"],
         fingerprint: candidate.fingerprint,
         discovered_by: candidate.discovered_by
       }}
    else
      {:error, identity_mismatch(candidate, bridge_id)}
    end
  end

  defp configured(config, _candidate) do
    {:error,
     Error.transport(:unexpected_response,
       description:
         "#{@config_path} did not answer with a bridge configuration: #{inspect(config)}"
     )}
  end

  defp identity_mismatch(candidate, bridge_id) do
    %Error{
      reason: :bridge_identity_mismatch,
      description:
        "the certificate at #{candidate.host} names bridge #{candidate.common_name}, but the " <>
          "bridge reports #{bridge_id} — the pin and the identity would describe different bridges"
    }
  end

  # -- the methods -----------------------------------------------------------

  defp cloud(options, timeout) do
    request =
      options
      |> Keyword.take(@cloud_options)
      |> Keyword.merge(receive_timeout: timeout, connect_options: [timeout: timeout])
      |> Req.new()
      |> Req.merge(method: :get, url: @cloud_url)

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        parse_cloud_response(body)

      other ->
        Logger.debug(
          "Hue.Discovery: the cloud endpoint did not answer usefully: #{inspect(other)}"
        )

        []
    end
  end

  defp mdns(timeout) do
    case :gen_udp.open(0, [:binary, active: false, reuseaddr: true, multicast_loop: true]) do
      {:ok, socket} ->
        try do
          query(socket, timeout)
        after
          :gen_udp.close(socket)
        end

      {:error, reason} ->
        Logger.debug("Hue.Discovery: could not open a multicast socket: #{inspect(reason)}")
        []
    end
  end

  # Bound to an ephemeral port rather than 5353, so responders treat this as a
  # legacy unicast query (RFC 6762 §6.7) and answer directly. That avoids
  # fighting a running avahi or mDNSResponder for port 5353.
  defp query(socket, timeout) do
    case :gen_udp.send(socket, @mdns_address, @mdns_port, query_packet()) do
      :ok ->
        collect_answers(socket, timeout)

      {:error, reason} ->
        Logger.debug("Hue.Discovery: could not send the multicast query: #{inspect(reason)}")
        []
    end
  end

  # -- plumbing --------------------------------------------------------------

  defp run_concurrently(functions, timeout) do
    functions
    |> Enum.map(&Task.async/1)
    |> Task.yield_many(timeout + @task_grace)
    |> Enum.flat_map(fn
      {_task, {:ok, found}} ->
        found

      {task, _unfinished} ->
        Task.shutdown(task, :brutal_kill)
        []
    end)
  end

  defp confirm([], _options), do: []

  defp confirm(candidates, options) do
    # identify/2 spends the budget once per phase, so the ceiling on a whole
    # confirmation is that many budgets, plus room for the task machinery.
    timeout = Keyword.fetch!(options, :timeout) * @identify_phases + @task_grace

    candidates
    |> Task.async_stream(&identify_candidate(&1, options),
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(&confirmed/1)
  end

  defp identify_candidate(candidate, options) do
    identify_options =
      options
      |> Keyword.put(:port, candidate.port)
      |> Keyword.put(:discovered_by, candidate.discovered_by)

    {candidate, identify(candidate.host, identify_options)}
  end

  defp confirmed({:ok, {_candidate, {:ok, bridge}}}), do: [bridge]

  defp confirmed({:ok, {candidate, {:error, error}}}) do
    Logger.warning(
      "Hue.Discovery: found #{candidate.host}:#{candidate.port} via #{candidate.discovered_by} " <>
        "but could not confirm it: #{Exception.message(error)}"
    )

    []
  end

  defp confirmed({:exit, reason}) do
    Logger.warning("Hue.Discovery: confirming a candidate did not finish: #{inspect(reason)}")
    []
  end

  defp best({_key, [only]}), do: only

  defp best({_key, group}) do
    [preferred | displaced] = Enum.sort_by(group, &locality/1)
    Enum.reduce(displaced, preferred, &fill_gaps/2)
  end

  defp locality(%Bridge.Info{discovered_by: :mdns}), do: 0
  defp locality(%Bridge.Info{discovered_by: :manual}), do: 1
  defp locality(%Bridge.Info{}), do: 2

  defp fill_gaps(%Bridge.Info{} = from, %Bridge.Info{} = into) do
    Map.merge(
      into,
      Map.filter(Map.from_struct(from), fn {_key, value} -> not is_nil(value) end),
      fn
        _key, kept, _replacement when not is_nil(kept) -> kept
        _key, _kept, replacement -> replacement
      end
    )
  end

  defp address_to_string({_a, _b, _c, _d} = address) do
    address |> :inet.ntoa() |> to_string()
  end

  defp address_to_string(_other), do: nil

  defp upcase(nil), do: nil
  defp upcase(id) when is_binary(id), do: String.upcase(id, :ascii)

  # :ssl.connect/4 reports a bare reason rather than an exception, so it is
  # shaped like one to reach the same normalisation every other path uses.
  defp transport_error(reason), do: Error.from_transport(%{reason: reason})

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value
      [] -> nil
    end
  end
end
