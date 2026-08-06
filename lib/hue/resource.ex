defmodule Hue.Resource do
  @moduledoc """
  Generic access to every CLIP v2 resource type.

  Nothing in this library is a special case of anything else: `light`, `room`,
  `scene`, `behavior_instance`, and the thirty-odd others all go through here, so
  no consumer is ever blocked by a missing wrapper.

      {:ok, lights} = Hue.Resource.list(client, :light)
      :ok = Hue.Resource.update(client, :light, rid, %{"on" => %{"on" => true}})

  ## Partial success

  A bridge response can carry both `data` and `errors` — some of what you asked
  for worked. Pass `return: :detailed` to receive `{:ok, data, errors}` instead
  of having the errors discarded. `get/4` does not accept it: it already
  unwraps to a single resource, and there is no data list left for the errors
  to sit alongside.

  ## Writes

  `update/5` and `delete/4` return plain `:ok` in the default `:simple` mode.
  The bridge answers a write with only the rid it touched, which carries no
  information the caller did not already have — the actual state change
  arrives on the eventstream, not in this response.

  ## Telemetry

  Every call is wrapped in `:telemetry.span/3` under `[:hue, :request]`, so
  `[:hue, :request, :start]` and either `[:hue, :request, :stop]` or
  `[:hue, :request, :exception]` fire around it. Start metadata carries
  `:method` and `:path`; stop metadata adds `:result` (`:ok` or `:error`),
  reflecting what the *caller* receives — including a domain-level
  reinterpretation such as `get/4` collapsing an empty result to `:not_found`,
  not just the wire-level HTTP outcome.

  ## Trust boundary

  `type` and `rid` are interpolated straight into the request path with no
  escaping. A `rid` from a less-trusted source could contain something like
  `../` and redirect the request elsewhere on the same bridge. The blast
  radius is bounded by whatever the application key itself can reach — this
  is not a privilege escalation — but `rid`s are expected to come from the
  bridge (a prior `list/3`, `get/4`, or `create/4` response), not from
  end-user input passed straight through.
  """

  alias Hue.Client
  alias Hue.Error

  @type type :: atom()
  @type rid :: String.t()
  @type return_mode :: :simple | :detailed

  @known_options [:return]
  @return_modes [:simple, :detailed]

  @doc "Lists every resource of one type."
  @spec list(Client.t(), type(), keyword()) ::
          {:ok, list()} | {:ok, list(), list()} | {:error, Error.t()}
  def list(%Client{} = client, type, options \\ []) when is_atom(type) do
    request(client, :get, "/resource/#{type}", nil, nil, options, & &1)
  end

  @doc """
  Fetches one resource by rid.

  Returns `{:error, %Hue.Error{reason: :not_found, rid: rid}}` for a rid that
  does not exist. Observed firmware `1.78.0` on a BSB002 answers a missing
  rid, a malformed rid, and an unknown resource type all with HTTP 404 and a
  JSON `errors` body (probed 2026-08-06) — that is the path this actually
  takes. An HTTP 200 with an empty `data` array is handled too, defensively:
  it is a shape the CLIP v2 schema permits, even though no probe against real
  hardware has produced it.

  Does not accept `return: :detailed` — see the moduledoc.
  """
  @spec get(Client.t(), type(), rid(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Client{} = client, type, rid, options \\ [])
      when is_atom(type) and is_binary(rid) do
    if options[:return] == :detailed do
      raise ArgumentError,
            "return: :detailed is not supported by get/4 — it already unwraps to a single " <>
              "resource, so there is no data list for the errors to sit alongside; call " <>
              "list/3 instead if you need them"
    end

    request(client, :get, "/resource/#{type}/#{rid}", nil, rid, options, &pick_one(&1, rid))
  end

  @doc """
  Updates one resource.

  Returns `:ok` in `:simple` mode (the default) — see the moduledoc's
  "Writes" section for why. Pass `return: :detailed` for `{:ok, data, errors}`.
  """
  @spec update(Client.t(), type(), rid(), map(), keyword()) ::
          :ok | {:ok, list(), list()} | {:error, Error.t()}
  def update(%Client{} = client, type, rid, body, options \\ [])
      when is_atom(type) and is_binary(rid) and is_map(body) do
    request(client, :put, "/resource/#{type}/#{rid}", body, rid, options, &to_write_result/1)
  end

  @doc "Creates a resource."
  @spec create(Client.t(), type(), map(), keyword()) ::
          {:ok, list()} | {:ok, list(), list()} | {:error, Error.t()}
  def create(%Client{} = client, type, body, options \\ [])
      when is_atom(type) and is_map(body) do
    request(client, :post, "/resource/#{type}", body, nil, options, & &1)
  end

  @doc """
  Deletes a resource.

  Returns `:ok` in `:simple` mode (the default) — see the moduledoc's
  "Writes" section for why. Pass `return: :detailed` for `{:ok, data, errors}`.
  """
  @spec delete(Client.t(), type(), rid(), keyword()) ::
          :ok | {:ok, list(), list()} | {:error, Error.t()}
  def delete(%Client{} = client, type, rid, options \\ [])
      when is_atom(type) and is_binary(rid) do
    request(client, :delete, "/resource/#{type}/#{rid}", nil, rid, options, &to_write_result/1)
  end

  defp pick_one({:ok, [resource]}, _rid), do: {:ok, resource}

  # Observed firmware 1.78.0 on a BSB002 answers a missing rid, a malformed
  # rid, and an unknown resource type all with HTTP 404 and a JSON `errors`
  # body (probed 2026-08-06) -- so this clause does not fire against real
  # hardware; that 404 instead becomes `{:error, %Error{reason: :not_found}}`
  # from `Error.from_response/4` by way of `do_request/6`, and reaches
  # `pick_one/2` through its `other -> other` clause below. This clause is
  # retained anyway: an HTTP 200 with an empty `data` array is a shape the
  # CLIP v2 API schema permits, and the cost of handling it is one clause.
  defp pick_one({:ok, []}, rid), do: {:error, %Error{reason: :not_found, rid: rid}}
  defp pick_one(other, _rid), do: other

  defp to_write_result({:ok, _data}), do: :ok
  defp to_write_result(other), do: other

  # Telemetry wraps the whole public call, `interpret` included, so the stop
  # event's `:result` reflects what the caller actually gets back — not just
  # whether the HTTP round trip itself succeeded.
  defp request(%Client{} = client, method, path, body, rid, options, interpret) do
    validate_options!(options)
    metadata = %{method: method, path: path}

    :telemetry.span([:hue, :request], metadata, fn ->
      result = client |> do_request(method, path, body, rid, options) |> interpret.()
      {result, Map.put(metadata, :result, outcome(result))}
    end)
  end

  # :telemetry.span/3 requires its function to return `{result, metadata}`.
  # A first draft read the outcome with `elem(result, 0)`, which raises
  # ArgumentError the instant `result` is the bare atom `:ok` — exactly what
  # `update/5` and `delete/4` return in `:simple` mode. Pattern-matched
  # clauses instead, covering every shape this module actually produces.
  defp outcome(:ok), do: :ok
  defp outcome({:ok, _data}), do: :ok
  defp outcome({:ok, _data, _errors}), do: :ok
  defp outcome({:error, _error}), do: :error

  defp do_request(client, method, path, body, rid, options) do
    request =
      client.req
      |> Req.merge(
        method: method,
        url: client.base_url <> path,
        headers: headers(client),
        decode_body: false
      )
      |> merge_body(body)

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: raw_body}} when status in 200..299 ->
        decode(raw_body, Keyword.get(options, :return, :simple))

      {:ok, %Req.Response{status: status, body: raw_body} = response} ->
        {:error, Error.from_response(status, raw_body, content_type(response), rid: rid)}

      {:error, exception} ->
        {:error, Error.from_transport(exception)}
    end
  end

  defp merge_body(request, nil), do: request
  defp merge_body(request, body) when is_map(body), do: Req.merge(request, json: body)

  # decode_body: false leaves the body as the raw bytes the bridge sent, so a
  # non-2xx body reaches Error.from_response/4 as the binary it documents —
  # never something this module already decoded and would have to re-encode
  # solely so from_response could decode it a second time.
  defp decode(raw_body, return) do
    case Jason.decode(raw_body) do
      {:ok, decoded} -> interpret(decoded, return)
      {:error, _reason} -> {:error, Error.transport(:unexpected_response, description: raw_body)}
    end
  end

  defp interpret(%{"data" => data} = body, :detailed) when is_list(data) do
    {:ok, data, body["errors"] || []}
  end

  defp interpret(%{"data" => data}, _return) when is_list(data) do
    {:ok, data}
  end

  # No "data" key at all — a total failure rather than a partial one. In
  # :detailed mode that is still `{:ok, [], errors}`: an empty result plus the
  # reason, the same shape a partial success has when nothing worked.
  defp interpret(%{"errors" => [_ | _] = errors}, :detailed) do
    {:ok, [], errors}
  end

  # Same case in :simple mode: there is no data to hand back, so this has to
  # surface as an error rather than silently returning an empty list as if
  # nothing had gone wrong.
  defp interpret(%{"errors" => [%{"description" => description} | _]}, _return) do
    {:error, Error.transport(:unexpected_response, description: description)}
  end

  defp interpret(body, _return) do
    {:error, Error.transport(:unexpected_response, description: inspect(body))}
  end

  defp headers(%Client{application_key: nil}), do: []
  defp headers(%Client{application_key: key}), do: [{"hue-application-key", key}]

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value
      [] -> nil
    end
  end

  defp validate_options!(options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, "expected a keyword list of options, got #{inspect(options)}"
    end

    case Keyword.keys(options) -- @known_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown option(s) #{inspect(unknown)} for Hue.Resource"
    end

    validate_return!(options[:return])
  end

  defp validate_return!(nil), do: :ok
  defp validate_return!(mode) when mode in @return_modes, do: :ok

  defp validate_return!(other) do
    raise ArgumentError,
          "return: #{inspect(other)} is not supported — the only values are " <>
            inspect(@return_modes)
  end
end
