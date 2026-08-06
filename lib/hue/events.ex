defmodule Hue.Events do
  @moduledoc """
  Decodes the bridge's Server-Sent Events stream.

  `GET /eventstream/clip/v2` pushes every state change, which is what makes a
  correct local model possible without polling. Three properties of the wire
  format catch naive implementations, all observed against a BSB002 on
  2026-08-06:

    * **It is a double array.** One SSE frame carries a list of envelopes, and
      each envelope carries a list of changed resources. One frame is not one
      change, at either level.
    * **Deltas are partial.** Only changed fields arrive, plus identity. See
      `Hue.Event`.
    * **A frame can be split across TCP chunks at any byte.** That is the bug
      class this module exists to prevent, and the reason `server_sent_events`
      is a dependency rather than forty lines of hand-rolled parsing.

  `decode/1` is for a complete buffer. `decode_stream/1` takes an enumerable of
  chunks and carries parser state across them. `stream/2` opens the connection
  and gives back the events lazily.

  ## Silence is not evidence of anything

  The bridge sends a `: hi` comment on connect and then, measured, **nothing at
  all for a hundred seconds** on an idle stream. There is no keepalive to miss,
  so an idle stream is protocol-indistinguishable from a dead one. Nothing here
  can tell them apart, and nothing here pretends to: `stream/2` waits forever by
  default. Liveness is the caller's to define — see `stream/2`'s
  `:receive_timeout`, and expect whatever you set to fire on a healthy bridge
  that simply had nothing to say.

  ## Nothing is dropped silently

  A frame this module cannot make sense of is logged at `:warning` and skipped,
  not raised on. A malformed frame must not take down a stream that is otherwise
  delivering state changes, and a frame that vanishes without trace is the
  hardest kind of eventstream bug to find.
  """

  require Logger

  alias Hue.Client
  alias Hue.Error
  alias Hue.Event

  @resource_path "/clip/v2"
  @eventstream_path "/eventstream/clip/v2"
  @known_options [:receive_timeout]
  @error_body_timeout 1_000

  # The fields Hue.Event declares as String.t() | nil, by the key they arrive
  # under. `data` and `owner` are checked separately: they are objects.
  @envelope_text_fields ~w(type id creationtime)
  @resource_text_fields ~w(type id)

  @envelope_type_names ~w(add update delete error)
  @envelope_types Map.new(@envelope_type_names, &{&1, String.to_atom(&1)})

  # The resource types CLIP v2 documents. Kept as a table rather than reached
  # through String.to_atom/1 so that a name from the network never becomes an
  # atom; see Hue.Event on what happens to the ones that are not here.
  @resource_type_names ~w(
    auth_v1 behavior_instance behavior_script bridge bridge_home button
    camera_motion clip contact device device_mode device_power
    device_software_update entertainment entertainment_configuration geofence
    geofence_client geolocation grouped_light grouped_light_level
    grouped_motion homekit light light_level matter matter_fabric motion
    private_group public_image relative_rotary room scene service_group
    smart_scene tamper taurus_7455 temperature wifi_connectivity
    zgp_connectivity zigbee_bridge_connectivity zigbee_connectivity
    zigbee_device_discovery zone
  )
  @resource_types Map.new(@resource_type_names, &{&1, String.to_atom(&1)})

  @doc "Decodes a complete buffer of SSE bytes."
  @spec decode(binary()) :: [Event.t()]
  def decode(binary) when is_binary(binary), do: decode_stream([binary])

  @doc """
  Decodes an enumerable of byte chunks, tolerating a split at any offset.

  Parser state is carried across chunks, so a frame cut in half by a chunk
  boundary decodes exactly as it would have whole.
  """
  @spec decode_stream(Enumerable.t()) :: [Event.t()]
  def decode_stream(chunks) do
    chunks
    |> ServerSentEvents.decode_stream()
    |> Enum.flat_map(&to_events/1)
  end

  @doc """
  Opens the eventstream and returns a lazy `Enumerable` of `Hue.Event` structs.

      client
      |> Hue.Events.stream()
      |> Enum.each(&handle/1)

  ## It starts no process of its own

  The connection is opened when the stream is first enumerated, in whichever
  process enumerates it, and it is closed when the stream stops — including when
  the consumer halts early, so `Enum.take(stream, 1)` releases the socket rather
  than leaking it. Where the work runs and what happens after a disconnect are
  the caller's decisions; this function reconnects nothing and retries nothing.

  Finch's pools and OTP's TLS processes are still there, exactly as they are for
  `Hue.Resource`. What this function adds is nothing of its own.

  Nothing is received except the connection's own messages. The caller's mailbox
  is a place this library is a guest in, and a bare `receive` here would take
  whatever happened to be at the front of it.

  ## Retry is off, and cannot be turned on

  Req retries `:safe_transient` failures by default, and a `GET` answered 429 or
  5xx is one. That is wrong twice over here. A stream that was partly read
  cannot be resumed by repeating the request, and — measured — each abandoned
  attempt leaves its own `into: :self` chunks behind in the caller's mailbox,
  because the retry step drops the earlier response without cancelling it. A
  consumer whose bridge answered 503 would get the error it expected plus six
  stray messages at `handle_info`.

  So this request is made with `retry: false` regardless of what the client was
  built with. Reconnecting is the caller's job, and it is the only place that
  knows whether the events it already handled make a fresh request the right
  move.

  ## Options

    * `:receive_timeout` — milliseconds to wait for the next byte from the
      bridge, as a non-negative integer or `:infinity`. Defaults to `:infinity`;
      read the moduledoc's "Silence is not evidence of anything" before setting
      it to a number.

  ## Failures

  A stream cannot return `{:error, _}`, so it raises `Hue.Error` — on a bridge
  that refuses the request (`:unauthorized` is the one to expect, and it arrives
  as HTTP 403 with an HTML body) and on a transport failure while streaming. A
  bridge that closes the stream cleanly is not a failure: the enumeration ends.
  """
  @spec stream(Client.t(), keyword()) :: Enumerable.t(Event.t())
  def stream(%Client{} = client, options \\ []) do
    validate_options!(options)

    fn -> open!(client, options) end
    |> Stream.resource(&next_chunk/1, &close/1)
    |> ServerSentEvents.decode_stream()
    |> Stream.flat_map(&to_events/1)
  end

  # -- the connection --------------------------------------------------------

  defp open!(client, options) do
    request =
      Req.merge(client.req,
        method: :get,
        url: eventstream_url(client),
        headers: headers(client),
        into: :self,
        decode_body: false,
        retry: false,
        receive_timeout: Keyword.get(options, :receive_timeout, :infinity)
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {response, :open}

      {:ok, %Req.Response{status: status} = response} ->
        raise refusal(response, status)

      {:error, exception} ->
        raise Error.from_transport(exception)
    end
  end

  # `into: :self` builds the async body whatever the status, so a refusal's body
  # is still on the socket rather than in hand. It is read before the connection
  # is dropped -- bounded, because this must not become a place a caller can
  # hang: a description that does not arrive costs the prose, not the error.
  defp refusal(response, status) do
    deadline = System.monotonic_time(:millisecond) + @error_body_timeout
    body = read_error_body(response, deadline, [])
    Req.cancel_async_response(response)

    Error.from_response(status, body, content_type(response))
  end

  # The deadline is absolute rather than per-receive, for the same reason
  # Hue.Discovery.collect_answers/2's is: a peer that dribbles one byte at a
  # time restarts a per-receive clock forever and the budget bounds nothing.
  defp read_error_body(
         %Req.Response{body: %Req.Response.Async{ref: ref}} = response,
         deadline,
         acc
       ) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      IO.iodata_to_binary(acc)
    else
      receive do
        {^ref, _payload} = message ->
          case Req.parse_message(response, message) do
            {:ok, chunks} -> continue_error_body(response, chunks, deadline, [acc | data(chunks)])
            _other -> IO.iodata_to_binary(acc)
          end
      after
        remaining -> IO.iodata_to_binary(acc)
      end
    end
  end

  defp continue_error_body(response, chunks, deadline, acc) do
    if finished?(chunks) do
      IO.iodata_to_binary(acc)
    else
      read_error_body(response, deadline, acc)
    end
  end

  defp next_chunk({_response, :done} = state), do: {:halt, state}

  defp next_chunk({response, :open} = state) do
    case Req.parse_message(response, await(response)) do
      {:ok, chunks} -> {data(chunks), {response, phase(chunks)}}
      {:error, reason} -> raise transport_error(reason)
      :unknown -> {[], state}
    end
  end

  # Req hands the mid-stream failure back as whatever Finch sent, which is an
  # exception struct rather than the bare atom the rest of this library's error
  # paths carry. Wrapping it in another `%{reason: _}` would bury the atom one
  # level too deep and land every disconnect on `:unknown`, so a term that
  # already reads as a reason is passed straight through.
  defp transport_error(%{reason: _reason} = exception), do: Error.from_transport(exception)
  defp transport_error(reason), do: Error.from_transport(%{reason: reason})

  # Selective, on this response's own reference, so an unrelated message sitting
  # in front of it in the caller's mailbox is stepped over rather than consumed.
  defp await(%Req.Response{body: %Req.Response.Async{ref: ref}}) do
    receive do
      {^ref, _payload} = message -> message
    end
  end

  defp data(chunks), do: for({:data, data} <- chunks, do: data)

  defp phase(chunks), do: if(finished?(chunks), do: :done, else: :open)

  defp finished?(chunks), do: Enum.member?(chunks, :done)

  # Runs however the stream ends, a consumer that halted early included, which is
  # what keeps `Enum.take(stream, 1)` from leaking a socket. Req's cancel also
  # takes the chunks already sitting in the caller's mailbox back out of it
  # (`clean_responses/1` in `Req.Finch`), which matters here more than usual: a
  # consumer slower than the bridge halts with the firehose queued behind it,
  # and those would otherwise surface as unexplained handle_info clauses long
  # after the stream ended. Measured, not assumed -- see the mailbox test.
  defp close({response, _phase}), do: Req.cancel_async_response(response)

  # Hue.new/2 is the only thing that builds a base_url, and it always ends in
  # the resource path, so this rewrites the suffix rather than replacing every
  # occurrence of it.
  defp eventstream_url(%Client{base_url: base_url}) do
    String.replace_suffix(base_url, @resource_path, @eventstream_path)
  end

  defp headers(%Client{application_key: nil}), do: [{"accept", "text/event-stream"}]

  defp headers(%Client{application_key: key}) do
    [{"accept", "text/event-stream"}, {"hue-application-key", key}]
  end

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value
      [] -> nil
    end
  end

  # -- decoding --------------------------------------------------------------

  defp to_events(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, envelopes} when is_list(envelopes) -> Enum.flat_map(envelopes, &from_envelope/1)
      {:ok, other} -> dropped("a frame was not a list of envelopes", other)
      {:error, _reason} -> dropped("a frame was not valid JSON", data)
    end
  end

  defp to_events(event), do: dropped("an event carried no data", event)

  defp from_envelope(%{"data" => resources} = envelope) when is_list(resources) do
    if text_fields?(envelope, @envelope_text_fields) do
      Enum.flat_map(resources, &from_resource(&1, envelope))
    else
      dropped("an envelope's identity was not the text CLIP v2 declares", envelope)
    end
  end

  defp from_envelope(envelope) do
    dropped("an envelope carried no list of changed resources", envelope)
  end

  defp from_resource(resource, envelope) when is_map(resource) do
    if text_fields?(resource, @resource_text_fields) and owner?(resource["owner"]) do
      [
        %Event{
          type: envelope_type(envelope["type"]),
          resource_type: resource_type(resource["type"]),
          rid: resource["id"],
          data: resource,
          owner: resource["owner"],
          id: envelope["id"],
          creationtime: envelope["creationtime"]
        }
      ]
    else
      dropped("a changed resource's identity was not the text CLIP v2 declares", resource)
    end
  end

  defp from_resource(resource, _envelope) do
    dropped("a changed resource was not an object", resource)
  end

  # `Hue.Event`'s declared types are a promise about what a consumer may pattern
  # match on, and the bridge fills every one of these fields. Trusting it to
  # send text here while refusing to trust it to name an atom would be the same
  # misplaced confidence, one line apart -- so a field that arrives as something
  # other than text takes the frame down the same path every other malformed
  # shape takes.
  #
  # Absent is not wrong. A field the bridge did not send is `nil`, which each of
  # these is declared to allow, and a bridge that says nothing has not said
  # something false.
  defp text_fields?(map, keys) do
    Enum.all?(keys, fn key -> is_nil(map[key]) or is_binary(map[key]) end)
  end

  defp owner?(owner), do: is_nil(owner) or is_map(owner)

  defp envelope_type(type) when is_binary(type), do: Map.get(@envelope_types, type, type)
  defp envelope_type(nil), do: nil

  defp resource_type(type) when is_binary(type), do: Map.get(@resource_types, type, type)
  defp resource_type(nil), do: nil

  defp dropped(what, term) do
    Logger.warning(
      "Hue.Events: #{what}, so it was dropped: #{inspect(term, limit: 20, printable_limit: 500)}"
    )

    []
  end

  defp validate_options!(options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, "expected a keyword list of options, got #{inspect(options)}"
    end

    case Keyword.keys(options) -- @known_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown option(s) #{inspect(unknown)} for Hue.Events"
    end

    validate_receive_timeout!(Keyword.fetch(options, :receive_timeout))
  end

  # Checked here rather than left for Finch, which would fail somewhere deep in
  # a request the caller has already stopped being able to relate to this
  # option. Fetched rather than read with a default, so an explicit `nil` is the
  # mistake it is instead of quietly meaning ":infinity".
  defp validate_receive_timeout!(:error), do: :ok
  defp validate_receive_timeout!({:ok, :infinity}), do: :ok

  defp validate_receive_timeout!({:ok, milliseconds})
       when is_integer(milliseconds) and milliseconds >= 0,
       do: :ok

  defp validate_receive_timeout!({:ok, other}) do
    raise ArgumentError,
          "receive_timeout: #{inspect(other)} is not a duration — pass a non-negative number " <>
            "of milliseconds, or :infinity to wait as long as the bridge stays quiet"
  end
end
