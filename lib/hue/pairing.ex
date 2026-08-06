defmodule Hue.Pairing do
  @moduledoc """
  Obtains an application key from a bridge.

  This is the one place the library still speaks the legacy v1 API, because
  pairing was never moved to CLIP v2. It carries v1 semantics with it:

    * The endpoint is `POST /api` — not under `/clip/v2`.
    * **Application errors arrive at HTTP 200 too**, wrapped as
      `[{"error":{"type":101, …}}]` rather than signalled by status. `pair/2`
      routes on the shape of the body, not the status code, and hands the
      error to `Hue.Error.from_pairing/1`.
    * The round link button on the bridge must have been pressed within
      roughly the last thirty seconds.

  <!-- -->

      # Press the round link button on the bridge first.
      {:ok, keys} = Hue.Pairing.pair(bridge)

  `generateclientkey: true` is always sent, so the response also carries the
  key the Entertainment streaming API needs. This library does not implement
  Entertainment, but the key is requested now so pairing never has to be
  repeated later to get it.

  ## First contact has no pin yet

  Pairing typically happens before any certificate has been trusted, so
  `bridge.fingerprint` is usually `nil`. `pair/2` builds its request with
  `Hue.new/2`, which already treats a `nil` fingerprint as "verification off,
  this is first contact" — the same rule `Hue.Transport.ssl_options/1`
  documents. Routing through `Hue.new/2` also means a caller-supplied
  `:connect_options` is merged (and a colliding `:transport_opts` rejected)
  by the same guard `Hue.Client` documents, rather than this module
  reimplementing it and getting it wrong.

  ## Telemetry

  `pair/2` wraps its request in `:telemetry.span/3` under `[:hue, :pairing]`,
  mirroring `Hue.Resource`. Start metadata carries `:method` and `:path`; stop
  metadata adds `:result` (`:ok` or `:error`). The returned application key
  and clientkey are never included — an application key is exactly as
  sensitive as a password, and telemetry handlers are commonly attached
  loggers.
  """

  alias Hue.Bridge
  alias Hue.Client
  alias Hue.Error

  @default_app "elixir"
  @default_port 443
  @default_timeout 60_000
  @default_poll_interval 2_000
  @device_type_byte_limit 40

  @type keys :: %{application_key: String.t(), clientkey: String.t()}

  @doc """
  Presses through to a bridge and exchanges the link-button press for an
  application key and a clientkey.

  Returns `{:error, %Hue.Error{reason: :link_button_not_pressed}}` if the
  button was not pressed recently enough — that is the expected outcome of
  calling this before pressing it, not a bug.

  ## Options

    * `:app` — identifies this pairing in `device_type/1`, e.g. the name of
      the application asking. Defaults to `#{inspect(@default_app)}`.

  Every other option is forwarded to `Hue.new/2` (and from there to
  `Req.new/1`), so `:plug`, `:connect_options`, `:receive_timeout`, `:retry`,
  and so on all work exactly as they do everywhere else in this library.
  `:port` and `:fingerprint` default to the values on `bridge`, but can be
  overridden the same way `Hue.new/2` allows.
  """
  @spec pair(Bridge.Info.t(), keyword()) :: {:ok, keys()} | {:error, Error.t()}
  def pair(%Bridge.Info{} = bridge, options \\ []) do
    {app, client_options} = Keyword.pop(options, :app, @default_app)

    client_options =
      client_options
      |> Keyword.put_new(:port, bridge.port)
      |> Keyword.put_new(:fingerprint, bridge.fingerprint)

    {:ok, client} = Hue.new(bridge.host, client_options)

    request(client, pairing_url(bridge), app)
  end

  @doc """
  Calls `pair/2` repeatedly until it succeeds or `timeout` milliseconds pass.

  This **blocks the calling process** for up to `timeout` (default
  `#{@default_timeout}`ms) via `Process.sleep/1` between attempts, waiting
  `:poll_interval` (default `#{@default_poll_interval}`ms) between them. It
  is meant for a script, an `IEx` session, or a one-off `Task` — never call
  it from inside a `GenServer` callback, where blocking the process for up to
  a minute would also block everything else that process is responsible for.

  Only `:link_button_not_pressed` is retried. Any other error — a transport
  failure, a bad host, a malformed response — returns immediately, since
  waiting and asking again would not change the outcome.

  Accepts `:timeout` and `:poll_interval` in addition to every option
  `pair/2` takes; both are milliseconds.
  """
  @spec pair_when_pressed(Bridge.Info.t(), keyword()) :: {:ok, keys()} | {:error, Error.t()}
  def pair_when_pressed(%Bridge.Info{} = bridge, options \\ []) do
    {timeout, options} = Keyword.pop(options, :timeout, @default_timeout)
    {poll_interval, options} = Keyword.pop(options, :poll_interval, @default_poll_interval)
    deadline = System.monotonic_time(:millisecond) + timeout

    poll(bridge, options, poll_interval, deadline)
  end

  @doc """
  Builds the `devicetype` string a pairing request sends, in the form
  `"hue_ex#\#{app}"`.

  Hue's v1 API limits `devicetype` to #{@device_type_byte_limit} bytes, so a
  long `app` is truncated to fit. The truncation is byte-safe: it never
  splits a multi-byte grapheme, so the result is always valid UTF-8 and
  always at most #{@device_type_byte_limit} bytes — not #{@device_type_byte_limit}
  characters, which is not the same thing for any `app` outside ASCII.
  """
  @spec device_type(String.t()) :: String.t()
  def device_type(app) when is_binary(app) do
    prefix = "hue_ex#"
    prefix <> truncate_bytes(app, @device_type_byte_limit - byte_size(prefix))
  end

  defp poll(bridge, options, poll_interval, deadline) do
    case pair(bridge, options) do
      {:error, %Error{reason: :link_button_not_pressed}} = error ->
        if System.monotonic_time(:millisecond) + poll_interval < deadline do
          Process.sleep(poll_interval)
          poll(bridge, options, poll_interval, deadline)
        else
          error
        end

      result ->
        result
    end
  end

  defp pairing_url(%Bridge.Info{host: host, port: @default_port}), do: "https://#{host}/api"
  defp pairing_url(%Bridge.Info{host: host, port: port}), do: "https://#{host}:#{port}/api"

  defp request(%Client{} = client, url, app) do
    metadata = %{method: :post, path: "/api"}

    :telemetry.span([:hue, :pairing], metadata, fn ->
      result = do_request(client, url, app)
      {result, Map.put(metadata, :result, outcome(result))}
    end)
  end

  defp do_request(%Client{} = client, url, app) do
    request =
      Req.merge(client.req,
        method: :post,
        url: url,
        json: %{"devicetype" => device_type(app), "generateclientkey" => true},
        decode_body: false
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: raw_body}} ->
        decode(raw_body)

      {:ok, %Req.Response{status: status, body: raw_body} = response} ->
        {:error, Error.from_response(status, raw_body, content_type(response))}

      {:error, %{reason: reason}} ->
        {:error, Error.transport(reason)}

      {:error, exception} ->
        {:error, Error.transport(:unknown, description: Exception.message(exception))}
    end
  end

  defp decode(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, decoded} -> interpret(decoded)
      {:error, _reason} -> {:error, Error.transport(:unexpected_response, description: raw_body)}
    end
  end

  defp interpret([%{"success" => success} | _]) do
    {:ok, %{application_key: success["username"], clientkey: success["clientkey"]}}
  end

  defp interpret([%{"error" => _} | _] = body), do: {:error, Error.from_pairing(body)}

  defp interpret(body) do
    {:error, Error.transport(:unexpected_response, description: inspect(body))}
  end

  defp outcome({:ok, _keys}), do: :ok
  defp outcome({:error, _error}), do: :error

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value
      [] -> nil
    end
  end

  defp truncate_bytes(string, max_bytes) do
    string
    |> String.graphemes()
    |> Enum.reduce_while({"", 0}, fn grapheme, {acc, size} ->
      new_size = size + byte_size(grapheme)

      if new_size > max_bytes do
        {:halt, {acc, size}}
      else
        {:cont, {acc <> grapheme, new_size}}
      end
    end)
    |> elem(0)
  end
end
