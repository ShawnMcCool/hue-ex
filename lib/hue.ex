defmodule Hue do
  @moduledoc """
  A client for the local CLIP v2 API on Philips Hue bridges.

  ## Getting an application key

  Press the round link button on the bridge, then call `Hue.Pairing.pair/2`
  within thirty seconds. Without a key every request fails with
  `%Hue.Error{reason: :unauthorized}` — and note the bridge answers that case
  with an HTML page rather than JSON.

  ## Scope

  This module and everything under it is a stateless protocol client. It starts
  no processes and holds no state between calls.
  """

  require Logger

  alias Hue.Bridge
  alias Hue.Client
  alias Hue.Transport

  @client_options [:application_key, :bridge_id, :fingerprint, :port, :verify]
  @default_port 443
  @path "/clip/v2"

  @doc """
  Builds a client for the bridge at `host`.

  ## Options

    * `:application_key` — required for every request except `/api/config`.
    * `:fingerprint` — the bridge's pinned certificate fingerprint, in any form
      `Hue.Transport.normalize_fingerprint/1` accepts, including the
      colon-separated uppercase one `openssl` prints. Without it, TLS
      verification is disabled; see `Hue.Transport`.
    * `:verify` — `:none` to disable verification explicitly.
    * `:port` — a positive integer, defaults to `#{@default_port}`.

  Any other option goes to `Req.new/1`, including `:connect_options` — with the
  exception of its `:transport_opts`, which this library owns and which
  `:fingerprint` and `:verify` are the way to configure.

  Raises `ArgumentError` rather than returning an error for a TLS configuration
  it cannot honour: in a library whose job is to verify, a rejected option must
  not be mistakable for one that was applied.
  """
  @spec new(String.t(), keyword()) :: {:ok, Client.t()}
  def new(host, options \\ []) when is_binary(host) do
    {mine, req_options} = Keyword.split(options, @client_options)
    ssl = Transport.ssl_options(Keyword.take(mine, [:fingerprint, :verify]))

    req =
      req_options
      |> Keyword.update(:connect_options, [transport_opts: ssl], &pin_transport!(&1, ssl))
      |> Req.new()

    {:ok,
     %Client{
       base_url: base_url(host, port!(Keyword.get(mine, :port, @default_port))),
       application_key: mine[:application_key],
       bridge_id: mine[:bridge_id],
       fingerprint: normalized(mine[:fingerprint]),
       req: req
     }}
  end

  @doc """
  Builds a client from a bridge found by `Hue.Discovery.discover/1`, carrying its
  id, port, and pinned fingerprint across automatically.

  The bridge's fingerprint is the pinned, trusted one, so a `:fingerprint`
  option that disagrees with it raises rather than quietly winning. Re-pin by
  updating the `Hue.Bridge.Info`. Disagreement is judged on the normalised
  fingerprints, so restating the pin in a different letter case or with `:`
  separators is not a disagreement.
  """
  @spec from_bridge(Bridge.Info.t(), keyword()) :: {:ok, Client.t()}
  def from_bridge(%Bridge.Info{} = bridge, options \\ []) do
    options
    |> Keyword.put_new(:bridge_id, bridge.bridge_id)
    |> Keyword.put_new(:port, bridge.port)
    |> carry_pin!(bridge)
    |> then(&new(bridge.host, &1))
  end

  # Matching on the default port is what omits it, so a host that happens to
  # contain ":443" or "443" in its name is left alone.
  defp base_url(host, @default_port), do: "https://#{host}#{@path}"
  defp base_url(host, port), do: "https://#{host}:#{port}#{@path}"

  defp port!(port) when is_integer(port) and port > 0, do: port

  defp port!(port) do
    raise ArgumentError, "port must be a positive integer, got #{inspect(port)}"
  end

  defp normalized(nil), do: nil
  defp normalized(fingerprint), do: Transport.normalize_fingerprint(fingerprint)

  defp pin_transport!(connect_options, ssl) do
    cond do
      not Keyword.keyword?(connect_options) ->
        raise ArgumentError,
              "connect_options must be a keyword list, got #{inspect(connect_options)}"

      Keyword.has_key?(connect_options, :transport_opts) ->
        raise ArgumentError,
              "connect_options[:transport_opts] would replace this library's TLS options, " <>
                "which is where certificate pinning lives — configure TLS with :fingerprint " <>
                "or verify: :none instead"

      true ->
        Keyword.put(connect_options, :transport_opts, ssl)
    end
  end

  # A bridge with no fingerprint was never pinned, so a client built from it
  # verifies nothing -- the trust level every other Hue client settles for.
  # That is legitimate at first contact and nowhere else, and Hue.Discovery
  # never returns such a bridge from a real connection, so reaching here
  # generally means a hand-built Bridge.Info. It is said out loud because the
  # alternative is a downgrade to unverified that is visible only by inspecting
  # the struct, which is the failure mode this module exists to prevent.
  defp carry_pin!(options, %Bridge.Info{fingerprint: nil} = bridge) do
    unless Keyword.has_key?(options, :fingerprint) do
      Logger.warning(
        "Hue: #{bridge.host} has no pinned fingerprint, so this client will not verify the " <>
          "bridge's certificate. Pin it with Hue.Discovery.identify/2, which captures the " <>
          "fingerprint on first contact."
      )
    end

    options
  end

  defp carry_pin!(options, %Bridge.Info{fingerprint: pinned} = bridge) do
    case Keyword.fetch(options, :fingerprint) do
      :error ->
        Keyword.put(options, :fingerprint, pinned)

      {:ok, given} ->
        agrees_with_pin!(options, given, pinned, bridge.host)
    end
  end

  defp agrees_with_pin!(options, given, pinned, host) do
    if normalized(given) == normalized(pinned) do
      options
    else
      raise ArgumentError,
            "#{host} is pinned to #{normalized(pinned)}, but fingerprint: #{inspect(given)} " <>
              "was passed — re-pin by updating the Hue.Bridge.Info, not by overriding it here"
    end
  end
end
