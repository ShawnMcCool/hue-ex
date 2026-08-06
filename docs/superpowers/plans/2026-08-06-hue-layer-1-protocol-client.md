# Hue Layer 1 — Protocol Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `hue` 0.1.0 to Hex — a stateless Elixir client for the Philips Hue CLIP v2 API that reaches every resource type, pins the bridge certificate on first use, decodes the eventstream correctly, and converts colour into any light's own gamut.

**Architecture:** Pure protocol layer. No processes, no supervision, no state between calls. A `%Hue.Client{}` carries a `Req.Request` so consumers inject test stubs and set their own timeouts. Every network-facing module is split into a thin I/O shell over public pure functions, which is what makes the whole thing testable against bytes recorded from a real bridge.

**Tech Stack:** Elixir ~> 1.17, `req ~> 0.7`, `jason ~> 1.4`, `server_sent_events ~> 1.1`, `telemetry ~> 1.0`, `color ~> 0.13`. Dev: `ex_doc`, `credo`, `dialyxir`, `plug` (test only).

**Source of truth:** `docs/superpowers/specs/2026-08-06-hue-library-design.md`. Layer 2 (the live bridge model) is a separate plan and must not be started here.

---

## File Structure

| File | Responsibility |
|---|---|
| `mix.exs` | Project, deps, `precommit` alias, Hex package, ExDoc groups |
| `lib/hue.ex` | Entry point: `new/2`, `from_bridge/2` |
| `lib/hue/client.ex` | `%Hue.Client{}` struct; `Inspect` redacts the key |
| `lib/hue/error.ex` | `%Hue.Error{}`; maps all three wire formats to reasons |
| `lib/hue/transport.ex` | TLS options, certificate fingerprinting, pinning `verify_fun` |
| `lib/hue/resource.ex` | Generic CRUD over every resource type |
| `lib/hue/pairing.ex` | Link-button flow → application key + clientkey |
| `lib/hue/bridge.ex` | `%Hue.Bridge.Info{}` struct (data only — no process in layer 1) |
| `lib/hue/discovery.ex` | mDNS ‖ cloud ‖ manual, merged by bridge id |
| `lib/hue/event.ex` | `%Hue.Event{}` struct |
| `lib/hue/events.ex` | `decode/1` (pure) and `stream/2` |
| `lib/hue/color.ex` | Public colour API: hex/RGB/Kelvin in, Hue payloads out |
| `lib/hue/color/gamut.ex` | Triangle containment and projection |
| `test/support/fixtures.ex` | Fixture loader |
| `test/support/certificates.ex` | Generates synthetic certs for pinning tests |

Task order is the dependency order. Error and Transport come first because nothing can reach the bridge without them.

---

### Task 1: Project scaffold

**Files:**
- Create: `mix.exs`, `.formatter.exs`, `lib/hue.ex`, `test/test_helper.exs`

- [ ] **Step 1: Generate the project**

Run from `~/src/hue-ex`. The directory already contains `README.md`, `LICENSE`, `.gitignore`, `docs/`, and `test/support/fixtures/`, so generate in place and keep those.

```bash
cd ~/src/hue-ex
mix new . --module Hue --app hue
```

Answer `y` when it asks to overwrite `README.md`, then restore ours:

```bash
git checkout README.md
```

- [ ] **Step 2: Write `mix.exs`**

```elixir
defmodule Hue.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ShawnMcCool/hue-ex"

  def project do
    [
      app: :hue,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Hue",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :ssl, :public_key, :crypto]]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:server_sent_events, "~> 1.1"},
      {:telemetry, "~> 1.0"},
      {:color, "~> 0.13"},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "dialyzer",
        "test"
      ]
    ]
  end

  defp description do
    "A client for the Philips Hue CLIP v2 local API — resources, eventstream, " <>
      "discovery, certificate pinning, and gamut-correct colour."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Shawn McCool"],
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [Hue, Hue.Client, Hue.Resource, Hue.Error],
        Setup: [Hue.Discovery, Hue.Bridge.Info, Hue.Pairing, Hue.Transport],
        Events: [Hue.Events, Hue.Event],
        Colour: [Hue.Color, Hue.Color.Gamut]
      ]
    ]
  end
end
```

- [ ] **Step 3: Fetch dependencies and confirm they resolve**

```bash
mix deps.get
```

Expected: resolves `req`, `jason`, `server_sent_events`, `telemetry`, `color` and their transitive deps with no conflicts.

- [ ] **Step 4: Confirm it compiles clean**

```bash
mix compile --warnings-as-errors
```

Expected: `Compiling N files (.ex)` and no warnings.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Scaffold the mix project with its dependency set"
```

---

### Task 2: Fixture loader

**Files:**
- Create: `test/support/fixtures.ex`
- Test: exercised by every later task

- [ ] **Step 1: Write the loader**

```elixir
defmodule Hue.Fixtures do
  @moduledoc """
  Loads bytes recorded from a real BSB002 bridge on 2026-08-06 and sanitised by
  `bin/sanitize-fixtures`. These are real responses, not invented shapes.
  """

  @dir Path.join(__DIR__, "fixtures")

  @doc "Raw fixture contents as a binary."
  def raw(name), do: File.read!(Path.join(@dir, name))

  @doc "A fixture parsed as JSON."
  def json(name), do: name |> raw() |> Jason.decode!()

  @doc "The full-state dump: 178 resources across 22 types."
  def full_state, do: json("full_state.json")

  @doc "Every resource of one type from the full-state dump."
  def resources(type) do
    full_state()["data"] |> Enum.filter(&(&1["type"] == type))
  end

  @doc "The first resource of one type."
  def resource(type), do: type |> resources() |> hd()
end
```

- [ ] **Step 2: Write a test proving the fixtures are intact**

Create `test/hue/fixtures_test.exs`:

```elixir
defmodule Hue.FixturesTest do
  use ExUnit.Case, async: true

  test "the full state holds the recorded resource population" do
    data = Hue.Fixtures.full_state()["data"]
    assert length(data) == 178
    assert data |> Enum.map(& &1["type"]) |> Enum.uniq() |> length() == 22
  end

  test "the recorded capability spread is preserved" do
    lights = Hue.Fixtures.resources("light")
    assert length(lights) == 19
    assert Enum.count(lights, &(not Map.has_key?(&1, "dimming"))) == 2
    assert Enum.count(lights, &Map.has_key?(&1, "color")) == 15
  end

  test "all three gamut types are represented" do
    types =
      "light"
      |> Hue.Fixtures.resources()
      |> Enum.filter(&Map.has_key?(&1, "color"))
      |> Enum.map(& &1["color"]["gamut_type"])
      |> Enum.uniq()
      |> Enum.sort()

    assert types == ["A", "B", "C"]
  end

  test "two rooms have no grouped_light service" do
    empty =
      "room"
      |> Hue.Fixtures.resources()
      |> Enum.filter(fn room ->
        not Enum.any?(room["services"], &(&1["rtype"] == "grouped_light"))
      end)

    assert length(empty) == 2
  end
end
```

- [ ] **Step 3: Run the tests**

```bash
mix test test/hue/fixtures_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Add the fixture loader and pin the recorded bridge population"
```

---

### Task 3: The error model

Three wire formats reach this module. See the spec's "The three wire formats".

**Files:**
- Create: `lib/hue/error.ex`
- Test: `test/hue/error_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hue.ErrorTest do
  use ExUnit.Case, async: true

  alias Hue.Error

  describe "from_response/3 — CLIP v2" do
    test "403 with an HTML body is unauthorized, not a decode crash" do
      html = Hue.Fixtures.raw("unauthorized_403.html")
      error = Error.from_response(403, html, "text/html")

      assert %Error{reason: :unauthorized, status: 403} = error
    end

    test "404 is not_found" do
      body = ~s({"errors":[{"description":"resource not available"}],"data":[]})
      error = Error.from_response(404, body, "application/json")

      assert %Error{reason: :not_found, description: "resource not available"} = error
    end

    test "429 is rate_limited" do
      assert %Error{reason: :rate_limited} = Error.from_response(429, "", "text/html")
    end

    test "503 is bridge_busy" do
      assert %Error{reason: :bridge_busy} = Error.from_response(503, "", "text/html")
    end
  end

  describe "from_pairing/1 — the v1 envelope at HTTP 200" do
    test "type 101 is link_button_not_pressed" do
      body = Hue.Fixtures.json("pairing_link_button_not_pressed.json")

      assert %Error{
               reason: :link_button_not_pressed,
               type: 101,
               description: "link button not pressed"
             } = Error.from_pairing(body)
    end

    test "an unrecognised type falls back to :unknown but keeps the detail" do
      body = [%{"error" => %{"type" => 7, "description" => "unauthorized user"}}]

      assert %Error{reason: :unknown, type: 7, description: "unauthorized user"} =
               Error.from_pairing(body)
    end
  end

  describe "transport/2" do
    test "carries a reason with no status" do
      assert %Error{reason: :timeout, status: nil} = Error.transport(:timeout)
    end
  end

  describe "message/1" do
    test "reads as a sentence" do
      error = Error.from_response(403, "", "text/html")
      assert Exception.message(error) =~ "unauthorized"
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
mix test test/hue/error_test.exs
```

Expected: FAIL — `Hue.Error.from_response/3 is undefined`.

- [ ] **Step 3: Implement**

```elixir
defmodule Hue.Error do
  @moduledoc """
  A normalised failure from a Hue bridge.

  Three different wire formats end up here, and a client that assumes one of them
  breaks on the others:

    * **CLIP v2** puts the signal in the HTTP status and the detail in
      `{"errors":[{"description": …}]}`. There are **no numeric error codes** —
      reasons are derived from status, never from the prose.
    * **CLIP v2 auth failure** returns HTTP 403 with a `text/html` body. Decoding
      that as JSON crashes on the single most likely first-run failure.
    * **v1 pairing** returns HTTP 200 carrying
      `[{"error":{"type":101, …}}]` — application errors at 200, with numeric types.

  Match on `:reason`. It is stable across all three.

  ## What this struct does and does not mean

  An `Error` means something outside the process refused the call — the bridge or
  the transport — or that a locally-known capability makes the call impossible.
  It is never used for an argument that could not have been valid: `brightness:
  "loud"` is a caller bug and raises.

  The reason worth handling explicitly is `:unauthorized`. It means no valid
  application key was sent. Get one with `Hue.Pairing.pair/2` after pressing the
  round link button on the bridge.
  """

  @type reason ::
          :unauthorized
          | :link_button_not_pressed
          | :not_found
          | :rate_limited
          | :bridge_busy
          | :unsupported_bridge
          | :certificate_changed
          | :not_dimmable
          | :not_color_capable
          | :no_grouped_light
          | :timeout
          | :econnrefused
          | :closed
          | :nxdomain
          | :unknown
          | atom()

  @type t :: %__MODULE__{
          reason: reason(),
          status: pos_integer() | nil,
          description: String.t() | nil,
          type: integer() | nil,
          rid: String.t() | nil
        }

  defexception [:reason, :status, :description, :type, :rid]

  @statuses %{
    400 => :bad_request,
    401 => :unauthorized,
    403 => :unauthorized,
    404 => :not_found,
    405 => :method_not_allowed,
    409 => :conflict,
    429 => :rate_limited,
    500 => :bridge_error,
    503 => :bridge_busy,
    507 => :insufficient_storage
  }

  @pairing_types %{101 => :link_button_not_pressed}

  @doc """
  Builds an error from a CLIP v2 response.

  `content_type` matters: the bridge answers an unauthenticated request with an
  HTML page, so the body is only parsed when it claims to be JSON.
  """
  @spec from_response(pos_integer(), binary(), String.t() | nil, keyword()) :: t()
  def from_response(status, body, content_type, opts \\ []) do
    %__MODULE__{
      reason: Map.get(@statuses, status, :unknown),
      status: status,
      description: describe(body, content_type),
      rid: opts[:rid]
    }
  end

  @doc """
  Builds an error from the v1 pairing envelope, which arrives at HTTP 200.
  """
  @spec from_pairing(list() | map()) :: t()
  def from_pairing([%{"error" => error} | _]), do: from_pairing(error)

  def from_pairing(%{"type" => type} = error) do
    %__MODULE__{
      reason: Map.get(@pairing_types, type, :unknown),
      status: 200,
      description: error["description"],
      type: type
    }
  end

  @doc "Builds an error for a failure below the application layer."
  @spec transport(atom(), keyword()) :: t()
  def transport(reason, opts \\ []) when is_atom(reason) do
    %__MODULE__{reason: reason, description: opts[:description]}
  end

  defp describe(body, "application/json" <> _) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, %{"errors" => [%{"description" => description} | _]}} -> description
      _ -> nil
    end
  end

  defp describe(_body, _content_type), do: nil

  @impl true
  def message(%__MODULE__{} = error) do
    [status_part(error), error.description]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" - ")
  end

  defp status_part(%{reason: reason, status: nil}), do: to_string(reason)
  defp status_part(%{reason: reason, status: status}), do: "#{reason} (HTTP #{status})"
end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/hue/error_test.exs
```

Expected: 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add the error model covering all three Hue wire formats"
```

---

### Task 4: Certificate pinning

The bridge sends only its leaf certificate, signed by a root that is neither on
the wire nor publicly downloadable. Trust is pinned on first use.

**Files:**
- Create: `lib/hue/transport.ex`, `test/support/certificates.ex`
- Test: `test/hue/transport_test.exs`

- [ ] **Step 1: Write the synthetic certificate helper**

Real bridge certificates identify a real home, so tests generate their own.

```elixir
defmodule Hue.Certificates do
  @moduledoc """
  Generates self-signed certificates shaped like a Hue bridge's: CN is a bridge
  id, and there is no subjectAltName.
  """

  @doc "Returns `{der, fingerprint}` for a certificate with the given CN."
  def bridge_certificate(common_name \\ "0011223344556677") do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    subject =
      {:rdnSequence,
       [
         [{:AttributeTypeAndValue, {2, 5, 4, 6}, <<19, 2, ?N, ?L>>}],
         [{:AttributeTypeAndValue, {2, 5, 4, 3}, <<19, byte_size(common_name)>> <> common_name}]
       ]}

    tbs =
      {:TBSCertificate, :v3, 1, {:SHA256WithRSAEncryption, :asn1_NOVALUE}, subject,
       {:Validity, {:utcTime, ~c"250101000000Z"}, {:utcTime, ~c"380101000000Z"}}, subject,
       public_key_info(private_key), :asn1_NOVALUE, :asn1_NOVALUE, :asn1_NOVALUE}

    der = :public_key.pkix_sign(tbs, private_key)
    {der, fingerprint(der)}
  end

  @doc "The SHA-256 fingerprint of a DER certificate, lowercase hex."
  def fingerprint(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  defp public_key_info(private_key) do
    public_key = :public_key.der_encode(:RSAPublicKey, extract_public(private_key))

    {:SubjectPublicKeyInfo,
     {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 1}, <<5, 0>>}, public_key}
  end

  defp extract_public(
         {:RSAPrivateKey, _v, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _o}
       ),
       do: {:RSAPublicKey, modulus, exponent}
end
```

- [ ] **Step 2: Write the failing test**

```elixir
defmodule Hue.TransportTest do
  use ExUnit.Case, async: true

  alias Hue.Transport

  test "fingerprint/1 is a stable lowercase sha256 hex digest" do
    {der, expected} = Hue.Certificates.bridge_certificate()

    assert Transport.fingerprint(der) == expected
    assert Transport.fingerprint(der) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "common_name/1 extracts the bridge id from the subject" do
    {der, _} = Hue.Certificates.bridge_certificate("00AABBCCDDEEFF00")

    assert Transport.common_name(der) == "00AABBCCDDEEFF00"
  end

  test "verify_pinned/3 accepts an unknown CA when the fingerprint matches" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()

    assert {:valid, ^fingerprint} =
             Transport.verify_pinned(der, {:bad_cert, :selfsigned_peer}, fingerprint)

    assert {:valid, ^fingerprint} =
             Transport.verify_pinned(der, {:bad_cert, :unknown_ca}, fingerprint)
  end

  test "verify_pinned/3 fails closed when the certificate changed" do
    {der, _} = Hue.Certificates.bridge_certificate("0011223344556677")
    {_other, other_fingerprint} = Hue.Certificates.bridge_certificate("FFFFFFFFFFFFFFFF")

    assert {:fail, :certificate_changed} =
             Transport.verify_pinned(der, {:bad_cert, :unknown_ca}, other_fingerprint)
  end

  test "verify_pinned/3 rejects genuinely bad certificates regardless of the pin" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()

    assert {:fail, _} = Transport.verify_pinned(der, {:bad_cert, :cert_expired}, fingerprint)
  end

  test "verify_pinned/3 defers on extensions it does not understand" do
    {der, fingerprint} = Hue.Certificates.bridge_certificate()

    assert {:unknown, ^fingerprint} =
             Transport.verify_pinned(der, {:extension, :undefined}, fingerprint)
  end

  test "ssl_options/1 pins when given a fingerprint" do
    options = Transport.ssl_options(fingerprint: "abc123")

    assert options[:verify] == :verify_peer
    assert {fun, "abc123"} = options[:verify_fun]
    assert is_function(fun, 3)
  end

  test "ssl_options/1 disables verification only when explicitly asked" do
    assert Transport.ssl_options(verify: :none)[:verify] == :verify_none
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
mix test test/hue/transport_test.exs
```

Expected: FAIL — `Hue.Transport.fingerprint/1 is undefined`.

- [ ] **Step 4: Implement**

```elixir
defmodule Hue.Transport do
  @moduledoc """
  TLS for Hue bridges, which cannot be verified the ordinary way.

  A bridge presents a certificate whose CN is its bridge id, with **no
  subjectAltName**, signed by a Signify root that is neither sent on the wire nor
  publicly downloadable. Hostname verification therefore cannot succeed, and
  there is no certificate authority to bundle.

  This module pins instead: the first connection records the certificate's
  SHA-256 fingerprint, and every connection afterwards requires the same one.
  That is the SSH host-key model. It does not detect an attacker present during
  the very first contact, and the README says so — but it detects every
  interception after it, which is more than any other Hue client does.

  A changed fingerprint means either a factory-reset bridge or an interception,
  and those are indistinguishable from here, so it fails closed.
  """

  @doc "The SHA-256 fingerprint of a DER-encoded certificate, lowercase hex."
  @spec fingerprint(binary()) :: String.t()
  def fingerprint(der) when is_binary(der) do
    :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)
  end

  @doc """
  The common name of a DER-encoded certificate.

  For a Hue bridge this is its bridge id, e.g. `"001788FFFEAE1B58"`.
  """
  @spec common_name(binary()) :: String.t() | nil
  def common_name(der) when is_binary(der) do
    {:OTPCertificate, tbs, _signature_algorithm, _signature} =
      :public_key.pkix_decode_cert(der, :otp)

    {:rdnSequence, rdns} = elem(tbs, 5)

    rdns
    |> List.flatten()
    |> Enum.find_value(fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, value} -> to_string_value(value)
      _ -> nil
    end)
  end

  @doc """
  The `:ssl` verify_fun callback. Accepts an unknown or self-signed issuer only
  when the certificate's fingerprint matches the pin.
  """
  @spec verify_pinned(binary() | tuple(), term(), String.t()) ::
          {:valid, String.t()} | {:unknown, String.t()} | {:fail, term()}
  def verify_pinned(certificate, event, pinned) do
    case event do
      {:bad_cert, reason} when reason in [:unknown_ca, :selfsigned_peer] ->
        if fingerprint(der(certificate)) == pinned do
          {:valid, pinned}
        else
          {:fail, :certificate_changed}
        end

      {:bad_cert, reason} ->
        {:fail, reason}

      {:extension, _} ->
        {:unknown, pinned}

      valid when valid in [:valid, :valid_peer] ->
        {:valid, pinned}
    end
  end

  @doc """
  Builds `:ssl` options.

  ## Options

    * `:fingerprint` — pin to this certificate. The normal path.
    * `:verify` — pass `:none` to disable verification entirely. This is what
      every other Hue client does; it is never the default here.
  """
  @spec ssl_options(keyword()) :: keyword()
  def ssl_options(options \\ []) do
    cond do
      options[:verify] == :none ->
        [verify: :verify_none]

      fingerprint = options[:fingerprint] ->
        [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 2,
          verify_fun: {&__MODULE__.verify_pinned/3, fingerprint},
          customize_hostname_check: [match_fun: fn _reference, _presented -> true end]
        ]

      true ->
        [verify: :verify_none]
    end
  end

  # `verify_fun` receives an already-decoded OTPCertificate in some OTP versions
  # and raw DER in others. Normalise to DER.
  defp der(certificate) when is_binary(certificate), do: certificate

  defp der({:OTPCertificate, _, _, _} = certificate) do
    :public_key.pkix_encode(:OTPCertificate, certificate, :otp)
  end

  defp to_string_value({:printableString, value}), do: to_string(value)
  defp to_string_value({:utf8String, value}), do: to_string(value)
  defp to_string_value(value) when is_binary(value), do: strip_asn1_prefix(value)
  defp to_string_value(value) when is_list(value), do: to_string(value)

  # Bare ASN.1 strings arrive tag-and-length prefixed.
  defp strip_asn1_prefix(<<_tag, length, rest::binary>>) when byte_size(rest) == length, do: rest
  defp strip_asn1_prefix(value), do: value
end
```

- [ ] **Step 5: Run the tests**

```bash
mix test test/hue/transport_test.exs
```

Expected: 8 tests, 0 failures. If `common_name/1` fails on the ASN.1 shape, inspect the decoded value with `IEx` and extend `to_string_value/1` — do **not** loosen the assertion.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Pin bridge certificates on first use instead of trusting a CA"
```

---

### Task 5: Client struct and entry point

**Files:**
- Create: `lib/hue/client.ex`
- Modify: `lib/hue.ex`
- Test: `test/hue/client_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hue.ClientTest do
  use ExUnit.Case, async: true

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
    {:ok, client} = Hue.new("192.0.2.10", application_key: "k", fingerprint: "abc")

    transport = client.req.options[:connect_options][:transport_opts]
    assert transport[:verify] == :verify_peer
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
mix test test/hue/client_test.exs
```

Expected: FAIL — `Hue.new/2 is undefined`.

- [ ] **Step 3: Implement the struct**

```elixir
defmodule Hue.Client do
  @moduledoc """
  A configured connection to one bridge.

  Holds a `Req.Request`, which is deliberate: consumers inject `plug:` for test
  stubs and set their own timeout and retry policy, so this library invents no
  configuration system of its own.

  The application key is redacted by `Inspect` so it cannot reach logs or crash
  dumps.
  """

  @type t :: %__MODULE__{
          base_url: String.t(),
          application_key: String.t() | nil,
          bridge_id: String.t() | nil,
          fingerprint: String.t() | nil,
          req: Req.Request.t()
        }

  @derive {Inspect, except: [:application_key]}
  defstruct [:base_url, :application_key, :bridge_id, :fingerprint, :req]
end
```

`@derive {Inspect, except: …}` omits the field. The test also wants the word
`[REDACTED]` present, so implement `Inspect` explicitly instead:

```elixir
defimpl Inspect, for: Hue.Client do
  import Inspect.Algebra

  def inspect(client, opts) do
    fields = [
      base_url: client.base_url,
      bridge_id: client.bridge_id,
      application_key: if(client.application_key, do: "[REDACTED]"),
      fingerprint: client.fingerprint
    ]

    concat(["#Hue.Client<", to_doc(fields, opts), ">"])
  end
end
```

Put the `defimpl` in the same file, below the module, and drop the `@derive` line.

- [ ] **Step 4: Implement the entry point in `lib/hue.ex`**

```elixir
defmodule Hue do
  @moduledoc """
  A client for the local CLIP v2 API on Philips Hue bridges.

      {:ok, bridge} = Hue.Discovery.discover() |> then(fn {:ok, [b | _]} -> {:ok, b} end)
      {:ok, key} = Hue.Pairing.pair(bridge)
      {:ok, client} = Hue.from_bridge(bridge, application_key: key.application_key)

      {:ok, lights} = Hue.Resource.list(client, :light)

  ## Getting an application key

  Press the round link button on the bridge, then call `Hue.Pairing.pair/2`
  within thirty seconds. Without a key every request fails with
  `%Hue.Error{reason: :unauthorized}` — and note the bridge answers that case
  with an HTML page rather than JSON.

  ## Scope

  This module and everything under it is a stateless protocol client. It starts
  no processes and holds no state between calls.
  """

  alias Hue.Bridge
  alias Hue.Client
  alias Hue.Transport

  @client_options [:application_key, :bridge_id, :fingerprint, :port, :verify]

  @doc """
  Builds a client for the bridge at `host`.

  ## Options

    * `:application_key` — required for every request except `/api/config`.
    * `:fingerprint` — the bridge's pinned certificate fingerprint. Without it,
      TLS verification is disabled; see `Hue.Transport`.
    * `:verify` — `:none` to disable verification explicitly.
    * `:port` — defaults to `443`.

  Any other option goes to `Req.new/1`:

      Hue.new("192.0.2.10", application_key: key, receive_timeout: 2_000)
  """
  @spec new(String.t(), keyword()) :: {:ok, Client.t()}
  def new(host, options \\ []) when is_binary(host) do
    {mine, req_options} = Keyword.split(options, @client_options)
    port = Keyword.get(mine, :port, 443)

    base_url = "https://#{host}:#{port}/clip/v2" |> String.replace(":443/", "/")

    ssl = Transport.ssl_options(Keyword.take(mine, [:fingerprint, :verify]))

    req =
      req_options
      |> Keyword.put_new(:connect_options, transport_opts: ssl)
      |> Req.new()

    {:ok,
     %Client{
       base_url: base_url,
       application_key: mine[:application_key],
       bridge_id: mine[:bridge_id],
       fingerprint: mine[:fingerprint],
       req: req
     }}
  end

  @doc """
  Builds a client from a bridge found by `Hue.Discovery.discover/1`, carrying its
  id and pinned fingerprint across automatically.
  """
  @spec from_bridge(Bridge.Info.t(), keyword()) :: {:ok, Client.t()}
  def from_bridge(%Bridge.Info{} = bridge, options \\ []) do
    options
    |> Keyword.put_new(:bridge_id, bridge.bridge_id)
    |> Keyword.put_new(:fingerprint, bridge.fingerprint)
    |> then(&new(bridge.host, &1))
  end
end
```

- [ ] **Step 5: Run the tests**

```bash
mix test test/hue/client_test.exs
```

Expected: 4 tests, 0 failures. `from_bridge/2` will not compile until Task 7 creates `Hue.Bridge.Info` — if the compiler objects now, create the struct stub from Task 7 Step 3 first, then return here.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add the client struct and entry point with key redaction"
```

---

### Task 6: Generic resource CRUD

**Files:**
- Create: `lib/hue/resource.ex`
- Test: `test/hue/resource_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
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

  test "update/4 PUTs and returns :ok", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "PUT"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"on" => %{"on" => true}}
      Req.Test.json(conn, %{"errors" => [], "data" => [%{"rid" => "x", "rtype" => "light"}]})
    end)

    assert :ok = Resource.update(client, :light, "abc", %{"on" => %{"on" => true}})
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

  test "a transport failure is normalised", %{client: client} do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %Error{reason: :econnrefused}} = Resource.list(client, :light)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
mix test test/hue/resource_test.exs
```

Expected: FAIL — `Hue.Resource.list/2 is undefined`.

- [ ] **Step 3: Implement**

```elixir
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
  of having the errors discarded.
  """

  alias Hue.Client
  alias Hue.Error

  @type type :: atom()
  @type rid :: String.t()

  @doc "Lists every resource of one type."
  @spec list(Client.t(), type(), keyword()) :: {:ok, list()} | {:error, Error.t()}
  def list(%Client{} = client, type, options \\ []) do
    request(client, :get, "/resource/#{type}", nil, options)
  end

  @doc "Fetches one resource by rid."
  @spec get(Client.t(), type(), rid(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Client{} = client, type, rid, options \\ []) do
    case request(client, :get, "/resource/#{type}/#{rid}", nil, options) do
      {:ok, [resource]} -> {:ok, resource}
      {:ok, []} -> {:error, %Error{reason: :not_found, rid: rid}}
      other -> other
    end
  end

  @doc """
  Updates one resource.

  Returns `:ok` — the bridge answers a write with the rid it touched, which
  carries no information the caller did not already have. The actual state change
  arrives on the eventstream.
  """
  @spec update(Client.t(), type(), rid(), map(), keyword()) ::
          :ok | {:ok, list(), list()} | {:error, Error.t()}
  def update(%Client{} = client, type, rid, body, options \\ []) do
    case request(client, :put, "/resource/#{type}/#{rid}", body, options) do
      {:ok, _data} -> :ok
      other -> other
    end
  end

  @doc "Creates a resource."
  @spec create(Client.t(), type(), map(), keyword()) :: {:ok, list()} | {:error, Error.t()}
  def create(%Client{} = client, type, body, options \\ []) do
    request(client, :post, "/resource/#{type}", body, options)
  end

  @doc "Deletes a resource."
  @spec delete(Client.t(), type(), rid(), keyword()) :: :ok | {:error, Error.t()}
  def delete(%Client{} = client, type, rid, options \\ []) do
    case request(client, :delete, "/resource/#{type}/#{rid}", nil, options) do
      {:ok, _data} -> :ok
      other -> other
    end
  end

  defp request(client, method, path, body, options) do
    metadata = %{method: method, path: path}

    :telemetry.span([:hue, :request], metadata, fn ->
      result = do_request(client, method, path, body, options)
      {result, Map.put(metadata, :result, elem(result, 0))}
    end)
  end

  defp do_request(client, method, path, body, options) do
    request =
      client.req
      |> Req.merge(
        method: method,
        url: client.base_url <> path,
        headers: headers(client)
      )
      |> then(fn request -> if body, do: Req.merge(request, json: body), else: request end)

    case Req.request(request) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        interpret(response.body, Keyword.get(options, :return, :simple))

      {:ok, response} ->
        {:error,
         Error.from_response(
           response.status,
           to_binary(response.body),
           content_type(response)
         )}

      {:error, %{reason: reason}} ->
        {:error, Error.transport(reason)}

      {:error, exception} ->
        {:error, Error.transport(:unknown, description: Exception.message(exception))}
    end
  end

  defp interpret(%{"data" => data} = body, :detailed), do: {:ok, data, body["errors"] || []}
  defp interpret(%{"data" => data}, :simple), do: {:ok, data}
  defp interpret(body, _), do: {:error, Error.transport(:unexpected_response,
                                  description: inspect(body))}

  defp headers(%Client{application_key: nil}), do: []
  defp headers(%Client{application_key: key}), do: [{"hue-application-key", key}]

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value
      [] -> nil
    end
  end

  defp to_binary(body) when is_binary(body), do: body
  defp to_binary(body), do: Jason.encode!(body)
end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/hue/resource_test.exs
```

Expected: 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add generic CRUD reaching every CLIP v2 resource type"
```

---

### Task 7: Bridge info and pairing

**Files:**
- Create: `lib/hue/bridge.ex`, `lib/hue/pairing.ex`
- Test: `test/hue/pairing_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hue.PairingTest do
  use ExUnit.Case, async: true

  alias Hue.Error
  alias Hue.Pairing

  setup do
    bridge = %Hue.Bridge.Info{host: "192.0.2.10", bridge_id: "0011223344556677"}
    {:ok, bridge: bridge}
  end

  test "pair/2 returns both keys on success", %{bridge: bridge} do
    plug =
      fn conn ->
        assert conn.request_path == "/api"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["generateclientkey"] == true
        assert decoded["devicetype"] =~ "#"

        Req.Test.json(conn, [
          %{"success" => %{"username" => "APP-KEY-40", "clientkey" => "CLIENT-KEY-32"}}
        ])
      end

    Req.Test.stub(__MODULE__, plug)

    assert {:ok, %{application_key: "APP-KEY-40", clientkey: "CLIENT-KEY-32"}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "the unpressed link button is a typed error, not a crash", %{bridge: bridge} do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, Hue.Fixtures.raw("pairing_link_button_not_pressed.json"))
    end)

    assert {:error, %Error{reason: :link_button_not_pressed, type: 101}} =
             Pairing.pair(bridge, plug: {Req.Test, __MODULE__})
  end

  test "device_type/1 is within Hue's 40-character limit" do
    assert byte_size(Pairing.device_type("fae")) <= 40
    assert Pairing.device_type("fae") =~ ~r/\Ahue_ex#/
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
mix test test/hue/pairing_test.exs
```

Expected: FAIL — `Hue.Bridge.Info.__struct__/1 is undefined`.

- [ ] **Step 3: Implement `Hue.Bridge.Info`**

```elixir
defmodule Hue.Bridge do
  @moduledoc "Namespace for bridge identity. Layer 1 defines only `Hue.Bridge.Info`."

  defmodule Info do
    @moduledoc """
    An identified bridge: where it is, which one it is, and the certificate that
    was pinned when it was first trusted.

    `discovered_by` records which method found it — useful because mDNS silently
    finds nothing on routed networks, and telling those cases apart matters when
    a user reports "it can't find my bridge".
    """

    @type t :: %__MODULE__{
            host: String.t(),
            port: pos_integer(),
            bridge_id: String.t() | nil,
            model_id: String.t() | nil,
            fingerprint: String.t() | nil,
            discovered_by: :mdns | :cloud | :manual | nil
          }

    defstruct [:host, :bridge_id, :model_id, :fingerprint, :discovered_by, port: 443]
  end
end
```

- [ ] **Step 4: Implement pairing**

```elixir
defmodule Hue.Pairing do
  @moduledoc """
  Obtains an application key from a bridge.

  This is the one place the library still speaks the legacy v1 API, because
  pairing was never moved to CLIP v2. It carries v1 semantics with it:
  **application errors arrive at HTTP 200**, wrapped as
  `[{"error":{"type":101, …}}]`.

      # Press the round link button on the bridge first.
      {:ok, keys} = Hue.Pairing.pair(bridge)

  The window is about thirty seconds. `pair_when_pressed/2` polls for you.
  """

  alias Hue.Bridge
  alias Hue.Error
  alias Hue.Transport

  @poll_interval 2_000
  @default_timeout 60_000

  @doc """
  Requests an application key. The link button must have been pressed within the
  last thirty seconds.

  Returns `%{application_key: String.t(), clientkey: String.t()}`. The clientkey
  is only needed for the Entertainment streaming API, which this library does not
  yet implement — it is requested now so pairing never has to be repeated.
  """
  @spec pair(Bridge.Info.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def pair(%Bridge.Info{} = bridge, options \\ []) do
    {app, req_options} = Keyword.pop(options, :app, "elixir")

    request =
      req_options
      |> Keyword.put_new(:connect_options,
        transport_opts: Transport.ssl_options(fingerprint: bridge.fingerprint)
      )
      |> Req.new()
      |> Req.merge(
        method: :post,
        url: "https://#{bridge.host}:#{bridge.port}/api",
        json: %{"devicetype" => device_type(app), "generateclientkey" => true}
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} -> interpret(body)
      {:ok, response} -> {:error, Error.from_response(response.status, "", nil)}
      {:error, %{reason: reason}} -> {:error, Error.transport(reason)}
    end
  end

  @doc """
  Polls `pair/2` until the link button is pressed or `:timeout` elapses.

  Useful for a setup flow that says "press the button now" and waits.
  """
  @spec pair_when_pressed(Bridge.Info.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def pair_when_pressed(%Bridge.Info{} = bridge, options \\ []) do
    {timeout, options} = Keyword.pop(options, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(bridge, options, deadline)
  end

  @doc """
  The `devicetype` string sent to the bridge, which limits it to 40 characters.
  """
  @spec device_type(String.t()) :: String.t()
  def device_type(app) do
    "hue_ex##{app}" |> String.slice(0, 40)
  end

  defp poll(bridge, options, deadline) do
    case pair(bridge, options) do
      {:error, %Error{reason: :link_button_not_pressed}} = error ->
        if System.monotonic_time(:millisecond) + @poll_interval < deadline do
          Process.sleep(@poll_interval)
          poll(bridge, options, deadline)
        else
          error
        end

      result ->
        result
    end
  end

  defp interpret([%{"success" => success} | _]) do
    {:ok, %{application_key: success["username"], clientkey: success["clientkey"]}}
  end

  defp interpret([%{"error" => _} | _] = body), do: {:error, Error.from_pairing(body)}
  defp interpret(body), do: {:error, Error.transport(:unexpected_response,
                             description: inspect(body))}
end
```

- [ ] **Step 5: Run the tests**

```bash
mix test test/hue/pairing_test.exs test/hue/client_test.exs
```

Expected: 7 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Add bridge identity and the link-button pairing flow"
```

---

### Task 8: Discovery

Three methods, because mDNS silently fails on routed networks — the network the
library was developed on.

**Files:**
- Create: `lib/hue/discovery.ex`
- Test: `test/hue/discovery_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hue.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Hue.Bridge
  alias Hue.Discovery

  test "identify/2 confirms a candidate and captures its identity" do
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

  test "identify/2 rejects a v1 bridge, which has no CLIP v2 at all" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"bridgeid" => "0011223344556677", "modelid" => "BSB001"})
    end)

    assert {:error, %Hue.Error{reason: :unsupported_bridge}} =
             Discovery.identify("192.0.2.10", plug: {Req.Test, __MODULE__})
  end

  test "merge/1 deduplicates by bridge id and prefers the local method" do
    found = [
      %Bridge.Info{host: "192.0.2.10", bridge_id: "AAA", discovered_by: :cloud},
      %Bridge.Info{host: "192.0.2.10", bridge_id: "AAA", discovered_by: :mdns},
      %Bridge.Info{host: "192.0.2.11", bridge_id: "BBB", discovered_by: :cloud}
    ]

    merged = Discovery.merge(found)

    assert length(merged) == 2
    assert Enum.find(merged, &(&1.bridge_id == "AAA")).discovered_by == :mdns
  end

  test "parse_cloud_response/1 reads the discovery endpoint's shape" do
    body = [%{"id" => "001788fffeae1b58", "internalipaddress" => "192.0.2.10", "port" => 443}]

    assert [%Bridge.Info{host: "192.0.2.10", port: 443, discovered_by: :cloud}] =
             Discovery.parse_cloud_response(body)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
mix test test/hue/discovery_test.exs
```

Expected: FAIL — `Hue.Discovery.identify/2 is undefined`.

- [ ] **Step 3: Implement**

`discover/1` runs mDNS and cloud concurrently. The mDNS query is a thin
`:gen_udp` shell over pure parse functions, matching how the rest of this library
separates I/O from logic.

```elixir
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
  error to explain why. That case is common enough that cloud discovery runs by
  default; disable it with `cloud: false`.

  Cloud discovery contacts `discovery.meethue.com`, which matches on public IP
  and returns local addresses. No credentials are involved, but Signify learns
  the requesting IP.

  Whatever the method, every result is confirmed by `identify/2` before it is
  returned, which is also where the certificate gets pinned.
  """

  alias Hue.Bridge
  alias Hue.Error

  @cloud_url "https://discovery.meethue.com"
  @mdns_service ~c"_hue._tcp.local"
  @mdns_address {224, 0, 0, 251}
  @mdns_port 5353
  @discover_timeout 5_000

  @doc """
  Finds every reachable bridge.

  ## Options

    * `:cloud` — set `false` to skip the cloud endpoint. Defaults to `true`.
    * `:mdns` — set `false` to skip multicast. Defaults to `true`.
    * `:timeout` — per-method budget in milliseconds. Defaults to 5000.
  """
  @spec discover(keyword()) :: {:ok, [Bridge.Info.t()]} | {:error, Error.t()}
  def discover(options \\ []) do
    timeout = Keyword.get(options, :timeout, @discover_timeout)

    tasks =
      [
        if(Keyword.get(options, :mdns, true), do: fn -> mdns(timeout) end),
        if(Keyword.get(options, :cloud, true), do: fn -> cloud(options) end)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Task.async/1)

    candidates =
      tasks
      |> Task.await_many(timeout + 1_000)
      |> List.flatten()
      |> merge()

    {:ok, confirm(candidates, options)}
  end

  @doc """
  Confirms a candidate address is a CLIP v2 bridge and captures its identity.

  `GET /api/config` needs no application key, which is what makes trust
  bootstrappable: it yields the bridge id needed to make sense of the
  certificate's common name.
  """
  @spec identify(String.t(), keyword()) :: {:ok, Bridge.Info.t()} | {:error, Error.t()}
  def identify(host, options \\ []) do
    request =
      options
      |> Keyword.put_new(:connect_options, transport_opts: [verify: :verify_none])
      |> Req.new()
      |> Req.merge(method: :get, url: "https://#{host}/api/config")

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"modelid" => "BSB001"}}} ->
        {:error, %Error{reason: :unsupported_bridge, description:
          "BSB001 is the v1 bridge and has no CLIP v2 API"}}

      {:ok, %{status: 200, body: %{"bridgeid" => bridge_id} = body}} ->
        {:ok,
         %Bridge.Info{
           host: host,
           bridge_id: bridge_id,
           model_id: body["modelid"],
           discovered_by: Keyword.get(options, :discovered_by, :manual)
         }}

      {:ok, response} ->
        {:error, Error.from_response(response.status, "", nil)}

      {:error, %{reason: reason}} ->
        {:error, Error.transport(reason)}
    end
  end

  @doc """
  Deduplicates by bridge id, preferring the locally-discovered record.

  A bridge found by both methods is one bridge. mDNS wins because it proves
  link-local reachability, which the cloud endpoint does not.
  """
  @spec merge([Bridge.Info.t()]) :: [Bridge.Info.t()]
  def merge(bridges) do
    bridges
    |> Enum.group_by(& &1.bridge_id)
    |> Enum.map(fn {_id, group} ->
      Enum.min_by(group, fn
        %{discovered_by: :mdns} -> 0
        %{discovered_by: :manual} -> 1
        _ -> 2
      end)
    end)
  end

  @doc "Parses the cloud endpoint's response body. Pure."
  @spec parse_cloud_response(list()) :: [Bridge.Info.t()]
  def parse_cloud_response(entries) when is_list(entries) do
    Enum.map(entries, fn entry ->
      %Bridge.Info{
        host: entry["internalipaddress"],
        port: entry["port"] || 443,
        bridge_id: entry["id"] && String.upcase(entry["id"]),
        discovered_by: :cloud
      }
    end)
  end

  @doc "Parses an mDNS response packet into hosts. Pure."
  @spec parse_mdns_packet(binary()) :: [String.t()]
  def parse_mdns_packet(packet) do
    case :inet_dns.decode(packet) do
      {:ok, record} ->
        record
        |> :inet_dns.msg(:anlist)
        |> Enum.filter(&(:inet_dns.rr(&1, :type) == :a))
        |> Enum.map(&:inet_dns.rr(&1, :data))
        |> Enum.map(&:inet.ntoa/1)
        |> Enum.map(&to_string/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp cloud(options) do
    request = options |> Keyword.take([:plug]) |> Req.new()

    case Req.request(Req.merge(request, method: :get, url: @cloud_url)) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> parse_cloud_response(body)
      _ -> []
    end
  end

  defp mdns(timeout) do
    case :gen_udp.open(0, [:binary, active: false, reuseaddr: true, multicast_loop: true]) do
      {:ok, socket} ->
        try do
          :gen_udp.send(socket, @mdns_address, @mdns_port, query_packet())
          collect_mdns(socket, timeout, [])
        after
          :gen_udp.close(socket)
        end

      {:error, _} ->
        []
    end
  end

  defp query_packet do
    :inet_dns.encode(
      {:dns_rec, {:dns_header, 0, false, :query, false, false, true, false, 0},
       [{:dns_query, @mdns_service, :ptr, :in}], [], [], []}
    )
  end

  defp collect_mdns(socket, timeout, found) do
    case :gen_udp.recv(socket, 0, timeout) do
      {:ok, {_address, _port, packet}} ->
        hosts = parse_mdns_packet(packet)
        collect_mdns(socket, timeout, found ++ hosts)

      {:error, :timeout} ->
        found |> Enum.uniq() |> Enum.map(&%Bridge.Info{host: &1, discovered_by: :mdns})

      {:error, _} ->
        found |> Enum.uniq() |> Enum.map(&%Bridge.Info{host: &1, discovered_by: :mdns})
    end
  end

  defp confirm(candidates, options) do
    candidates
    |> Task.async_stream(
      fn candidate ->
        case identify(candidate.host,
               Keyword.put(options, :discovered_by, candidate.discovered_by)) do
          {:ok, bridge} -> bridge
          {:error, _} -> nil
        end
      end,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, bridge} -> [bridge]
      {:exit, _} -> []
    end)
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/hue/discovery_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add discovery over mDNS, cloud, and manual with v1 bridge rejection"
```

---

### Task 9: Eventstream decoding

The bug class this task exists to prevent is a frame split across chunk
boundaries. It is the reason `server_sent_events` is a dependency rather than
forty lines of hand-rolled parsing.

**Files:**
- Create: `lib/hue/event.ex`, `lib/hue/events.ex`
- Test: `test/hue/events_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hue.EventsTest do
  use ExUnit.Case, async: true

  alias Hue.Event
  alias Hue.Events

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
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
mix test test/hue/events_test.exs
```

Expected: FAIL — `Hue.Events.decode/1 is undefined`.

- [ ] **Step 3: Implement the event struct**

```elixir
defmodule Hue.Event do
  @moduledoc """
  One resource change.

  A bridge frame nests two arrays deep — a list of envelopes, each holding a list
  of changed resources — and this struct is the flattened result: one struct per
  changed resource, carrying its envelope's identity.

  `data` is a **partial** resource. An observed light event carried only
  `%{"on" => %{"on" => true}}` plus identity fields: no brightness, no colour, no
  name. Merge it into known state; never treat it as the whole resource.
  """

  @type t :: %__MODULE__{
          type: :update | :add | :delete | :error,
          resource_type: atom(),
          rid: String.t(),
          data: map(),
          owner: map() | nil,
          id: String.t(),
          creationtime: String.t()
        }

  defstruct [:type, :resource_type, :rid, :data, :owner, :id, :creationtime]
end
```

- [ ] **Step 4: Implement decoding**

```elixir
defmodule Hue.Events do
  @moduledoc """
  Decodes the bridge's Server-Sent Events stream.

  `GET /eventstream/clip/v2` pushes every state change, which is what makes a
  correct local model possible without polling.

  Two properties of the wire format catch naive implementations:

    * **It is a double array.** One SSE frame carries a list of envelopes, and
      each envelope carries a list of changed resources. One frame is not one
      change, at either level.
    * **Deltas are partial.** Only changed fields arrive, plus identity.

  A third catches everyone eventually: a frame can be split across TCP chunks at
  any byte. `decode_stream/1` handles that; `decode/1` is for whole buffers and
  tests.
  """

  alias Hue.Client
  alias Hue.Event

  @doc "Decodes a complete buffer of SSE bytes."
  @spec decode(binary()) :: [Event.t()]
  def decode(binary) when is_binary(binary), do: decode_stream([binary])

  @doc """
  Lazily decodes an enumerable of byte chunks, tolerating splits at any offset.
  """
  @spec decode_stream(Enumerable.t()) :: [Event.t()]
  def decode_stream(chunks) do
    chunks
    |> ServerSentEvents.decode_stream()
    |> Enum.flat_map(&to_events/1)
  end

  @doc """
  Opens the eventstream and returns a lazy `Enumerable` of `%Hue.Event{}`.

  This starts no process of its own — the caller decides where the work runs, and
  is responsible for reconnecting. Layer 2's bridge process is built on this.

      client
      |> Hue.Events.stream()
      |> Enum.each(&handle/1)
  """
  @spec stream(Client.t(), keyword()) :: Enumerable.t()
  def stream(%Client{} = client, options \\ []) do
    Stream.resource(
      fn -> open(client, options) end,
      &next_chunk/1,
      &close/1
    )
    |> decode_lazily()
  end

  defp decode_lazily(chunks) do
    chunks
    |> ServerSentEvents.decode_stream()
    |> Stream.flat_map(&to_events/1)
  end

  defp open(client, options) do
    url = String.replace(client.base_url, "/clip/v2", "/eventstream/clip/v2")

    Req.merge(client.req,
      method: :get,
      url: url,
      headers: [
        {"hue-application-key", client.application_key},
        {"accept", "text/event-stream"}
      ],
      into: :self,
      receive_timeout: Keyword.get(options, :receive_timeout, :infinity)
    )
    |> Req.request!()
  end

  defp next_chunk(response) do
    case Req.parse_message(response, receive_message(response)) do
      {:ok, [data: data]} -> {[data], response}
      {:ok, [:done]} -> {:halt, response}
      {:ok, _other} -> {[], response}
      :unknown -> {[], response}
    end
  end

  defp receive_message(response) do
    receive do
      message -> message
    after
      :infinity -> {:error, :timeout}
    end
    |> tap(fn _ -> response end)
  end

  defp close(response), do: Req.cancel_async_response(response)

  defp to_events(%{data: data}) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, envelopes} when is_list(envelopes) -> Enum.flat_map(envelopes, &from_envelope/1)
      _ -> []
    end
  end

  defp to_events(_), do: []

  defp from_envelope(%{"data" => resources} = envelope) when is_list(resources) do
    Enum.map(resources, fn resource ->
      %Event{
        type: envelope_type(envelope["type"]),
        resource_type: resource["type"] && String.to_atom(resource["type"]),
        rid: resource["id"],
        data: resource,
        owner: resource["owner"],
        id: envelope["id"],
        creationtime: envelope["creationtime"]
      }
    end)
  end

  defp from_envelope(_), do: []

  defp envelope_type("update"), do: :update
  defp envelope_type("add"), do: :add
  defp envelope_type("delete"), do: :delete
  defp envelope_type(_), do: :error
end
```

- [ ] **Step 5: Run the tests**

```bash
mix test test/hue/events_test.exs
```

Expected: 5 tests, 0 failures. The chunk-boundary test runs 657 assertions on its
own; if any split fails, the bug is in `decode_stream/1`, not the test.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Decode the eventstream, proving invariance to chunk boundaries"
```

---

### Task 10: Gamut mathematics

**Files:**
- Create: `lib/hue/color/gamut.ex`
- Test: `test/hue/color/gamut_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hue.Color.GamutTest do
  use ExUnit.Case, async: true

  alias Hue.Color.Gamut

  @gamut_c %{
    red: {0.6915, 0.3083},
    green: {0.1700, 0.7000},
    blue: {0.1532, 0.0475}
  }

  test "contains?/2 accepts a point inside the triangle" do
    assert Gamut.contains?(@gamut_c, {0.35, 0.35})
  end

  test "contains?/2 rejects a point outside the triangle" do
    refute Gamut.contains?(@gamut_c, {0.9, 0.9})
  end

  test "clamp/2 leaves an interior point untouched" do
    assert Gamut.clamp(@gamut_c, {0.35, 0.35}) == {0.35, 0.35}
  end

  test "clamp/2 pulls an exterior point onto the triangle" do
    clamped = Gamut.clamp(@gamut_c, {0.9, 0.9})

    assert Gamut.contains?(@gamut_c, clamped)
  end

  test "from_light/1 reads the gamut a light reports for itself" do
    light =
      "light"
      |> Hue.Fixtures.resources()
      |> Enum.find(&(&1["color"]["gamut_type"] == "C"))

    assert %{red: {_, _}, green: {_, _}, blue: {_, _}} = Gamut.from_light(light)
  end

  test "from_light/1 falls back to the standard triangle when none is reported" do
    light = %{"color" => %{"gamut_type" => "B"}}

    assert Gamut.from_light(light) == Gamut.standard("B")
  end

  test "every clamped point lands inside every real gamut" do
    gamuts =
      "light"
      |> Hue.Fixtures.resources()
      |> Enum.filter(&Map.has_key?(&1, "color"))
      |> Enum.map(&Gamut.from_light/1)
      |> Enum.uniq()

    points = for x <- 0..10, y <- 0..10, do: {x / 10, y / 10}

    for gamut <- gamuts, point <- points do
      clamped = Gamut.clamp(gamut, point)

      assert Gamut.contains?(gamut, clamped),
             "clamping #{inspect(point)} into #{inspect(gamut)} produced #{inspect(clamped)}"
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
mix test test/hue/color/gamut_test.exs
```

Expected: FAIL — `Hue.Color.Gamut.contains?/2 is undefined`.

- [ ] **Step 3: Implement**

```elixir
defmodule Hue.Color.Gamut do
  @moduledoc """
  The triangle of colours a particular light can actually produce.

  Hue reports gamut per light as three arbitrary CIE xy primaries, and they
  differ by model — a bridge commonly hosts several. A colour outside a light's
  triangle is not merely approximate, it is unrepresentable, so it is projected
  onto the nearest point the light can reach.

  This is the part of colour handling the `color` library cannot do: it maps
  between *named* working spaces, and these triangles are per-device.
  """

  @type point :: {float(), float()}
  @type t :: %{red: point(), green: point(), blue: point()}

  # Published fallbacks for lights that report a gamut_type but no gamut.
  @standard %{
    "A" => %{red: {0.7040, 0.2960}, green: {0.2151, 0.7106}, blue: {0.1380, 0.0800}},
    "B" => %{red: {0.6750, 0.3220}, green: {0.4090, 0.5180}, blue: {0.1670, 0.0400}},
    "C" => %{red: {0.6915, 0.3083}, green: {0.1700, 0.7000}, blue: {0.1532, 0.0475}}
  }

  @doc "The published triangle for a gamut type."
  @spec standard(String.t()) :: t()
  def standard(type), do: Map.fetch!(@standard, type)

  @doc """
  The gamut a light reports for itself, falling back to the standard triangle for
  its type when it reports none.
  """
  @spec from_light(map()) :: t() | nil
  def from_light(%{"color" => %{"gamut" => gamut}}) when is_map(gamut) do
    %{
      red: {gamut["red"]["x"], gamut["red"]["y"]},
      green: {gamut["green"]["x"], gamut["green"]["y"]},
      blue: {gamut["blue"]["x"], gamut["blue"]["y"]}
    }
  end

  def from_light(%{"color" => %{"gamut_type" => type}}) when is_map_key(@standard, type),
    do: standard(type)

  def from_light(_), do: nil

  @doc "Whether a point lies inside the triangle."
  @spec contains?(t(), point()) :: boolean()
  def contains?(%{red: r, green: g, blue: b}, point) do
    d1 = cross(point, r, g)
    d2 = cross(point, g, b)
    d3 = cross(point, b, r)

    negative = d1 < 0 or d2 < 0 or d3 < 0
    positive = d1 > 0 or d2 > 0 or d3 > 0

    not (negative and positive)
  end

  @doc """
  Returns the point itself when it is inside the gamut, and otherwise the closest
  point on the triangle's perimeter.
  """
  @spec clamp(t(), point()) :: point()
  def clamp(gamut, point) do
    if contains?(gamut, point) do
      point
    else
      %{red: r, green: g, blue: b} = gamut

      [{r, g}, {g, b}, {b, r}]
      |> Enum.map(&closest_on_segment(&1, point))
      |> Enum.min_by(&distance(&1, point))
    end
  end

  defp cross({px, py}, {ax, ay}, {bx, by}), do: (px - bx) * (ay - by) - (ax - bx) * (py - by)

  defp closest_on_segment({{ax, ay}, {bx, by}}, {px, py}) do
    abx = bx - ax
    aby = by - ay
    length_squared = abx * abx + aby * aby

    t =
      if length_squared == 0 do
        0.0
      else
        ((px - ax) * abx + (py - ay) * aby) / length_squared
      end
      |> max(0.0)
      |> min(1.0)

    {ax + t * abx, ay + t * aby}
  end

  defp distance({ax, ay}, {bx, by}), do: :math.pow(ax - bx, 2) + :math.pow(ay - by, 2)
end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/hue/color/gamut_test.exs
```

Expected: 7 tests, 0 failures. The last test is the important one — it clamps 121
points into every distinct gamut on the reference bridge and asserts each result
is inside.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add gamut containment and projection with a property test"
```

---

### Task 11: The colour API

**Files:**
- Create: `lib/hue/color.ex`
- Test: `test/hue/color_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Hue.ColorTest do
  use ExUnit.Case, async: true

  alias Hue.Color
  alias Hue.Color.Gamut

  setup do
    light =
      "light"
      |> Hue.Fixtures.resources()
      |> Enum.find(&(&1["color"]["gamut_type"] == "C"))

    {:ok, light: light}
  end

  test "to_xy/2 converts hex into the light's own gamut", %{light: light} do
    {:ok, {x, y}} = Color.to_xy("#ff8800", light)

    assert Gamut.contains?(Gamut.from_light(light), {x, y})
  end

  test "to_xy/2 accepts an RGB tuple", %{light: light} do
    assert {:ok, {_x, _y}} = Color.to_xy({255, 136, 0}, light)
  end

  test "to_xy/2 passes an explicit xy pair through the clamp", %{light: light} do
    assert {:ok, clamped} = Color.to_xy({:xy, 0.9, 0.9}, light)
    assert Gamut.contains?(Gamut.from_light(light), clamped)
  end

  test "to_xy/2 refuses a light with no colour support" do
    white = "light" |> Hue.Fixtures.resources() |> Enum.find(&(not Map.has_key?(&1, "color")))

    assert {:error, %Hue.Error{reason: :not_color_capable}} = Color.to_xy("#ff8800", white)
  end

  test "kelvin_to_mirek/1 inverts correctly" do
    assert Color.kelvin_to_mirek(2700) == 370
    assert Color.kelvin_to_mirek(6500) == 154
  end

  test "mirek_for/2 clamps to the light's reported schema", %{light: light} do
    schema = light["color_temperature"]["mirek_schema"]

    assert {:ok, mirek} = Color.mirek_for(1_000_000, light)
    assert mirek >= schema["mirek_minimum"]
    assert mirek <= schema["mirek_maximum"]
  end

  test "to_hex/1 round-trips approximately" do
    {:ok, hex} = Color.to_hex({0.5, 0.4})

    assert hex =~ ~r/\A#[0-9a-f]{6}\z/
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
mix test test/hue/color_test.exs
```

Expected: FAIL — `Hue.Color.to_xy/2 is undefined`.

- [ ] **Step 3: Implement**

```elixir
defmodule Hue.Color do
  @moduledoc """
  Colour conversion for Hue lights.

  Developers think in hex, RGB, and Kelvin. Hue speaks CIE xy and mirek, and the
  representable range differs per light. This module bridges the two, always
  against the gamut of the light being addressed rather than a generic one.

      {:ok, xy} = Hue.Color.to_xy("#ff8800", light)
      370 = Hue.Color.kelvin_to_mirek(2700)

  ## On accuracy

  `to_hex/1` is **approximate**. A chromaticity pair carries no luminance, so
  converting back to RGB requires inventing one. It is good enough for a swatch
  in a user interface and is not a lossless round trip.
  """

  alias Hue.Color.Gamut
  alias Hue.Error

  @type input :: String.t() | {0..255, 0..255, 0..255} | {:xy, float(), float()}

  @doc """
  Converts a colour into an xy pair inside `light`'s gamut.

  Accepts a hex string, an RGB tuple, or `{:xy, x, y}`.
  """
  @spec to_xy(input(), map()) :: {:ok, Gamut.point()} | {:error, Error.t()}
  def to_xy(input, light) do
    case Gamut.from_light(light) do
      nil ->
        {:error,
         %Error{
           reason: :not_color_capable,
           description: "this light reports no colour support",
           rid: light["id"]
         }}

      gamut ->
        with {:ok, point} <- to_chromaticity(input) do
          {:ok, Gamut.clamp(gamut, point)}
        end
    end
  end

  @doc "Builds the CLIP v2 body for setting a colour on `light`."
  @spec payload(input(), map()) :: {:ok, map()} | {:error, Error.t()}
  def payload(input, light) do
    with {:ok, {x, y}} <- to_xy(input, light) do
      {:ok, %{"color" => %{"xy" => %{"x" => x, "y" => y}}}}
    end
  end

  @doc """
  Converts a colour temperature in Kelvin to mirek, Hue's reciprocal unit.

      iex> Hue.Color.kelvin_to_mirek(2700)
      370
  """
  @spec kelvin_to_mirek(pos_integer()) :: pos_integer()
  def kelvin_to_mirek(kelvin) when is_integer(kelvin) and kelvin > 0 do
    round(1_000_000 / kelvin)
  end

  @doc """
  Converts Kelvin to mirek and clamps it to the range `light` reports for itself,
  rather than to a hardcoded 153–500.
  """
  @spec mirek_for(pos_integer(), map()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def mirek_for(kelvin, light) do
    case light["color_temperature"] do
      nil ->
        {:error,
         %Error{reason: :not_color_capable, description: "no colour temperature support"}}

      temperature ->
        schema = temperature["mirek_schema"] || %{}
        minimum = schema["mirek_minimum"] || 153
        maximum = schema["mirek_maximum"] || 500

        {:ok, kelvin |> kelvin_to_mirek() |> max(minimum) |> min(maximum)}
    end
  end

  @doc """
  Converts an xy pair to an approximate hex string, for display only.
  """
  @spec to_hex(Gamut.point()) :: {:ok, String.t()} | {:error, Error.t()}
  def to_hex({x, y}) do
    case Color.convert(%Color.XyY{x: x, y: y, luminance: 1.0}, Color.SRGB) do
      {:ok, srgb} -> {:ok, Color.to_hex(srgb)}
      {:error, reason} -> {:error, Error.transport(:color_conversion_failed,
                            description: inspect(reason))}
    end
  end

  defp to_chromaticity({:xy, x, y}), do: {:ok, {x, y}}

  defp to_chromaticity({r, g, b}) do
    to_chromaticity("#" <> Base.encode16(<<r, g, b>>, case: :lower))
  end

  defp to_chromaticity("#" <> _ = hex) do
    case Color.convert(hex, Color.XyY) do
      {:ok, %{x: x, y: y}} -> {:ok, {x, y}}
      {:error, reason} -> {:error, Error.transport(:color_conversion_failed,
                            description: inspect(reason))}
    end
  end
end
```

- [ ] **Step 4: Run the tests**

```bash
mix test test/hue/color_test.exs
```

Expected: 7 tests, 0 failures. The `color` library's exact struct and function
names must be confirmed against `mix deps.get`-installed docs — run
`h Color.convert` in `iex -S mix` and adjust the two `Color.convert/2` call sites
if the arity or return shape differs. Do not change what the tests assert.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add the colour API converting hex, RGB, and Kelvin per light"
```

---

### Task 12: Live suite against real hardware

**Files:**
- Create: `test/live/live_test.exs`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Exclude live tests by default**

`test/test_helper.exs`:

```elixir
ExUnit.start(exclude: [:live])
```

- [ ] **Step 2: Write the live suite**

```elixir
defmodule Hue.LiveTest do
  @moduledoc """
  Runs against real hardware:

      HUE_HOST=192.168.1.10 HUE_KEY=... mix test --include live

  Read-only. Nothing here changes a light.
  """

  use ExUnit.Case, async: false

  @moduletag :live

  setup_all do
    host = System.get_env("HUE_HOST") || flunk("HUE_HOST is not set")
    key = System.get_env("HUE_KEY") || flunk("HUE_KEY is not set")

    {:ok, bridge} = Hue.Discovery.identify(host)
    {:ok, client} = Hue.from_bridge(bridge, application_key: key)

    {:ok, client: client, bridge: bridge}
  end

  test "the bridge is a CLIP v2 model", %{bridge: bridge} do
    assert bridge.model_id == "BSB002"
    assert bridge.bridge_id =~ ~r/\A[0-9A-F]{16}\z/
  end

  test "every light can be listed and has a resolvable owner", %{client: client} do
    {:ok, lights} = Hue.Resource.list(client, :light)
    {:ok, devices} = Hue.Resource.list(client, :device)

    device_ids = MapSet.new(devices, & &1["id"])

    assert lights != []

    for light <- lights do
      assert MapSet.member?(device_ids, light["owner"]["rid"]),
             "light #{light["id"]} has an owner that is not a known device"
    end
  end

  test "an unauthenticated request fails with :unauthorized", %{bridge: bridge} do
    {:ok, anonymous} = Hue.new(bridge.host, application_key: "not-a-real-key")

    assert {:error, %Hue.Error{reason: :unauthorized}} =
             Hue.Resource.list(anonymous, :light)
  end

  test "the eventstream connects and stays open", %{client: client} do
    task =
      Task.async(fn ->
        client |> Hue.Events.stream() |> Enum.take(0)
      end)

    assert :ok = Task.await(task, 10_000) |> then(fn _ -> :ok end)
  end

  test "colour converts into every real gamut on this bridge", %{client: client} do
    {:ok, lights} = Hue.Resource.list(client, :light)

    colour_lights = Enum.filter(lights, &Map.has_key?(&1, "color"))

    for light <- colour_lights do
      assert {:ok, xy} = Hue.Color.to_xy("#ff8800", light)
      assert Hue.Color.Gamut.contains?(Hue.Color.Gamut.from_light(light), xy)
    end
  end
end
```

- [ ] **Step 3: Run the offline suite and confirm live is excluded**

```bash
mix test
```

Expected: all tests pass, and the summary reports excluded tests.

- [ ] **Step 4: Run against the real bridge**

```bash
HUE_HOST=192.168.178.146 HUE_KEY=$(cat ~/.config/hue/key) mix test --include live
```

Expected: 5 additional tests pass. If `HUE_KEY` is not filed yet, take it from
the pairing performed during the design session.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add a read-only live suite, excluded by default"
```

---

### Task 13: Documentation and release

**Files:**
- Modify: `README.md`, `lib/hue.ex`

- [ ] **Step 1: Rewrite the README for a shipped library**

Replace the "design complete, implementation not started" banner with a
quickstart. It must cover, in order: discovery, pressing the link button,
pairing, storing the key and fingerprint, and a first request. State plainly
that trust is pinned on first use and that an attacker present during pairing is
not detected — that honesty is the point, given every other client verifies
nothing at all.

- [ ] **Step 2: Run the full precommit gate**

```bash
mix precommit
```

Expected: compiles with no warnings, formats clean, `credo --strict` reports no
issues, dialyzer passes, all tests pass.

- [ ] **Step 3: Build the docs and read them**

```bash
mix docs && xdg-open doc/index.html
```

Check that the four module groups are populated and that `Hue.Error`,
`Hue.Transport`, and `Hue.Events` read as explanations rather than lists.

- [ ] **Step 4: Publish**

```bash
mix hex.publish
```

- [ ] **Step 5: Tag and commit**

```bash
git tag v0.1.0
git push && git push --tags
```

---

## Self-Review

**Spec coverage.** Every layer-1 section of the spec maps to a task: three wire
formats → Task 3; certificate pinning → Task 4; client and key redaction →
Task 5; generic CRUD and partial success → Task 6; pairing's v1 semantics →
Task 7; three discovery methods and `BSB001` rejection → Task 8; double-array
frames, partial deltas, and chunk-boundary invariance → Task 9; per-light gamut
clamping and mirek → Tasks 10 and 11; recorded fixtures → Task 2; live suite →
Task 12; publishing → Task 13.

Deliberately deferred to the layer-2 plan, and not gaps in this one: the
`Hue.Bridge` process, ETS caching, delta merging into cached state,
subscriptions, name-based addressing, write coalescing and pacing, and the
`:not_dimmable`, `:no_grouped_light`, and `:not_synced` reasons, which only have
meaning once a cache exists. `Hue.Error` declares them now so the type does not
churn later.

**Telemetry** is emitted from `Hue.Resource` (Task 6) via `:telemetry.span/3`.
The stream and sync events in the spec belong to layer 2.

**Naming consistency.** `%Hue.Bridge.Info{}` is defined in Task 7 and used in
Tasks 5, 7, and 8. `Hue.Transport.fingerprint/1` is defined in Task 4 and used in
Tasks 5 and 7. `Hue.Color.Gamut.from_light/1` and `contains?/2` are defined in
Task 10 and used in Tasks 11 and 12. `Hue.Events.decode_stream/1` is defined in
Task 9 and used by its own chunk-split test.

**Known risk, flagged rather than hidden.** Task 4's `common_name/1` and Task
11's `Color.convert/2` calls depend on record shapes and an API this plan could
not execute against. Both steps say to verify in `iex` and adjust the
implementation — never the assertion.
