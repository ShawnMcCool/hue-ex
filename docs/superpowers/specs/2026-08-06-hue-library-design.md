# Design: `hue` — an Elixir client for the Philips Hue CLIP v2 API

**Date:** 2026-08-06
**Status:** Approved
**Repo:** `~/src/hue-ex` · **Hex package:** `hue` · **Namespace:** `Hue`

## Problem

Philips Hue bridges expose a local JSON REST API — CLIP v2 — plus a Server-Sent
Events stream that pushes every state change. There is no usable Elixir client.
The three on Hex all target the deprecated v1 API and are abandoned: `huex`
(0.8.0, Dec 2018), `exhue` (0.1.7, Mar 2018), and `hue_sdk` (0.1.1, Aug 2022,
whose surface is `HueSDK.API.Lights.get_all_lights/1` over `/api/<username>/lights`).
The Hex name `hue` is unclaimed as of 2026-08-06.

Fae wants to drive lighting, and lighting is the natural second consumer of the
`Sun` phase automation that currently drives only the television. But the
library boundary is worth drawing on its own terms, because Hue is a
substantially larger and stranger surface than the BRAVIA set was.

**The shape of the problem is not HTTP.** It is that Hue models a home as a
graph of 38 cross-linked resource types, and every question a developer actually
asks requires resolving that graph. "Dim the living room" is: find the `room` by
name → walk `room.services` → select `rtype: grouped_light` → PUT that rid.
Done per-call, that is several round trips for one dim. The eventstream is what
makes it tractable: fetch the graph once, then apply deltas.

## Goals

- Reach **every** resource type, so no consumer is blocked by a missing wrapper.
- Address things by name — "Living Room", "Desk Lamp" — not UUIDs.
- Maintain a live, correct local model of the bridge, updated by the eventstream.
- Make color work: hex, RGB, and Kelvin in; gamut-correct xy out, per light.
- React to input — switches and sensors — since that is what makes Hue
  programmable rather than merely remotely controllable.
- Never flood the bridge; pace and coalesce writes by construction.
- Work on real-world networks, including the ones where mDNS silently fails.
- Testable without hardware, from responses recorded off a real bridge.

## Non-goals (0.1)

- **The Entertainment streaming API.** 50 fps colour over DTLS-PSK on UDP is a
  separate protocol with its own handshake and its own failure modes. The
  `clientkey` needed for it is captured during pairing so this stays additive,
  but it is not in this release.
- **The v1 API**, except the one v1 endpoint pairing still requires.
- **Bridge configuration**: adding/removing lights, Zigbee touchlink, firmware
  updates, and `behavior_instance` authoring. Readable, not writable.
- **Hue cloud / remote access.** Local only.
- **A UI, persistence, or scheduling.** Those belong to the consumer.

## Verified bridge facts

Confirmed live on 2026-08-06 against a **BSB002 (Bridge v2)**, firmware
`1.78.0`, holding 178 resources across 22 types. These are measurements, not
assumptions.

### Transport and trust

- Control API is HTTPS on **port 443**. Base path `/clip/v2/resource`.
- The certificate is `subject: C=NL, O=Philips Hue, CN=001788FFFEAE1B58` —
  **the CN is the bridge ID** — issued by `C=NL, O=Philips Hue, CN=root-bridge`,
  valid to 2038, and carries **no subjectAltName**.
- Therefore **ordinary TLS hostname verification cannot succeed**. Modern
  verifiers reject SAN-less certificates, and the CN is not an address.
- **The bridge sends only its leaf certificate.** No intermediate, no root:
  `openssl s_client` reports `verify error:num=20: unable to get local issuer
  certificate`. The issuing root cannot be obtained from the connection, and
  Signify publishes it only behind a developer-portal login.
- For reference, `aiohue` — the client Home Assistant ships, and the most mature
  implementation in any language — sets `ssl=False` and does not verify the
  bridge at all. The de facto industry practice is no verification.
- `GET /api/config` responds **unauthenticated, HTTP 200, `application/json`**
  with `bridgeid`, `modelid`, `apiversion`, and `mac`. This is what makes
  pinning bootstrappable.
- **`BSB001` (the square Bridge v1) has no CLIP v2 at all.** `modelid` is the
  check.

### Authentication

- Reads and writes both require a `hue-application-key` header. Unlike the
  BRAVIA set, **nothing is readable unauthenticated** except `/api/config`.
- Pairing is a `POST /api` with `{"devicetype": "...", "generateclientkey": true}`
  within ~30 s of the physical link button being pressed. It returns
  `username` (40 chars — the application key) and `clientkey` (32 chars, for
  Entertainment).

### The three wire formats

A client that assumes one of these breaks on the others.

1. **CLIP v2 success/failure** — HTTP status carries the signal, body is
   `{"errors": [{"description": "..."}], "data": [...]}`. Both keys may be
   populated at once: partial success is real. **There are no numeric error
   codes**, only prose — so reasons must be derived from HTTP status, not the body.
2. **CLIP v2 auth failure** — `GET /clip/v2/resource` without a valid key returns
   **HTTP 403 with `Content-Type: text/html`**, a Hue-branded HTML page. Not
   JSON. A client that calls `Jason.decode!/1` on the error path crashes on the
   single most likely first-run failure.
3. **v1 pairing** — `POST /api` returns **HTTP 200** carrying
   `[{"error":{"type":101,"address":"","description":"link button not pressed"}}]`.
   Application errors at HTTP 200, with numeric types, exactly the model CLIP v2
   abandoned.

### The resource graph

- Everything references everything by `{rid, rtype}`, where `rid` is a UUID.
- `room.children` holds **device** rids; `room.services` holds the services that
  aggregate them, including `grouped_light`. Control goes through the service;
  enumeration goes through the children.
- **`room.services` may contain no `grouped_light`.** Two of the six rooms on
  the reference bridge are empty and have none. The obvious implementation
  crashes on them.
- `light.metadata.name` is populated and matches its device's name, but the
  schema marks it *"Deprecated, use metadata on device level"*. Resolve through
  `light.owner` → `device.metadata.name`.
- A **capability manifest exists**: the `clip` resource lists the 38 resource
  types the bridge supports. This is the analogue of BRAVIA's
  `getSupportedApiInfo` — check once at startup and degrade gracefully.

### Device capability spread (reference bridge)

- 19 lights: **15** `dimming`+`color_temperature`+`color`, **2**
  `dimming`+`color_temperature`, and **2 with no `dimming` object at all**.
  Code that assumes every light dims fails on real hardware.
- Gamut types present: **A×3, B×6, C×6** — the complete matrix.
- Gamuts are arbitrary xy triangles, e.g.
  `{"red":{"x":0.675,"y":0.322},"green":{"x":0.409,"y":0.518},"blue":{"x":0.167,"y":0.04}}`.
- 6 rooms, 3 zones, 34 scenes, 8 grouped_lights.
- One `ZGPSWITCH` Hue Tap switch over `zgp_connectivity`, 4 buttons, reporting
  `event_values: ["initial_press"]` and `repeat_interval: 0`. Button capability
  is per-model and must be read, not assumed.
- **No `device_power`, `motion`, `temperature`, or `light_level` resources.** The
  dimmer-switch event vocabulary (`short_release`, `long_press`, `long_release`,
  `repeat`) is therefore **written from the OpenAPI schema and marked
  unverified** until a dimmer switch is paired.

### The eventstream

`GET /eventstream/clip/v2` with `Accept: text/event-stream`. Observed:

```
: hi                                    ← comment, sent on connect
                                        ← blank line
id: 1786031432:0                        ← <unix_ts>:<seq>
data: [{envelope}, …]
```

Each envelope is
`{"creationtime": …, "id": "<uuid>", "type": "update", "data": [<resource>, …]}`.

- **It is a double array.** One frame carries many envelopes; each envelope
  carries many resource deltas. One frame ≠ one change, at either level.
- **Deltas are partial.** An observed light event carried only `on: {on: true}`
  plus identity fields — no brightness, no colour, no name. State must be
  deep-merged, never replaced.
- `type` means two different things in one payload: `"update"` on the envelope,
  `"light"` on the resource.
- **One action fans out.** A single light switching on also produced a
  `grouped_light` update on `bridge_home` with a recomputed aggregate brightness.
- **No keepalive arrived within a 100-second window** beyond the initial `: hi`.
  An idle stream is protocol-indistinguishable from a dead one; liveness needs
  TCP-level detection or our own timeout.

## Architecture

Two layers. The lower is complete and stateless; the upper is what most people
use.

```
── Layer 1: protocol ──────────────────────────────────────────
Hue                 new/2, from_bridge/2
Hue.Client          struct: base_url, application_key, bridge_id, Req.Request
Hue.Transport       TLS: SPKI pinning via verify_fun, trust-on-first-use
Hue.Resource        generic CRUD, all types: list/2 get/3 update/4 create/3 delete/3
Hue.Pairing         link-button flow → application_key + clientkey
Hue.Discovery       mDNS ‖ cloud ‖ manual → %Hue.Bridge.Info{}
Hue.Events          decode/1 (pure) · stream/2 (lazy Enumerable)
Hue.Error           reason atoms across all three wire formats
Hue.Color           hex/RGB/Kelvin → gamut-clamped xy

── Layer 2: live model ────────────────────────────────────────
Hue.Bridge          Supervisor; child_spec for your tree
  ├─ Registry             subscription filtering (type/name/rid)
  ├─ Task.Supervisor      stream + write tasks, off the server's stack
  └─ Hue.Bridge.Server    the GenServer: sync, reconnect, dispatch, writes
       ├─ Hue.Bridge.Cache    the named ETS table; every read path
       ├─ Hue.Bridge.Graph    name-or-rid → resource; room/zone → grouped_light
       ├─ Hue.Bridge.Body     write options → CLIP v2 body, capability-checked
       ├─ Hue.Bridge.Writes   coalescing, per-type-paced write queue
       └─ Hue.Bridge.Merge    deep-merge of an event delta into a cached resource
  (Hue.Bridge.Names builds the two name indexes Cache keeps; pure, no process)
Hue.Light  Hue.Room  Hue.Zone  Hue.Scene    name-addressable operations
```

> **Corrected after implementation.** This diagram originally listed
> `Hue.Bridge` alone for layer 2, as a single GenServer + ETS. The built shape
> is a `Supervisor` (`Hue.Bridge`) over a `Registry`, a `Task.Supervisor`, and
> one `Hue.Bridge.Server` GenServer, with `Cache`, `Graph`, `Body`, `Writes`,
> `Merge`, and `Names` beneath it — see "`Hue.Bridge` internals" below for why
> each of those is its own module rather than code inside the server.

Layer 1 starts no processes and holds no state between calls. Layer 2 never
starts itself — it hands you a `child_spec` and you place it in your own
supervision tree, as Finch, Redix, and Postgrex do.

```elixir
# Layer 2 — the normal path
{:ok, light} = Hue.Light.get(bridge, "Desk Lamp")
:ok = Hue.Room.set(bridge, "Living Room", on: false)
:ok = Hue.Light.set(bridge, "Iris", color: "#ff8800", brightness: 40)

# Layer 1 — the escape hatch, no process required
{:ok, resources} = Hue.Resource.list(client, :behavior_instance)
:ok = Hue.Resource.update(client, :light, rid, %{"on" => %{"on" => true}})
```

Targets accept a name or a rid interchangeably. Names are convenient; rids
survive someone renaming a room in the Hue app.

### Discovery and TLS are one problem

The bridge cannot be verified by any conventional means: its certificate has no
SAN, its CN is an opaque bridge ID rather than an address, and the issuing root
is neither sent on the wire nor publicly downloadable. Verification therefore
has to be bootstrapped from the first connection.

**The library pins the bridge's public key on first use** — the SSH host-key
model, not the web PKI model. This needs no bundled certificate authority, keeps
working if Signify rotates its root, and detects interception on every connection
after the first.

1. Obtain a candidate address by any method below.
2. `GET /api/config` with verification disabled — confirms it is a Hue bridge,
   yields `bridgeid` and `modelid`.
3. Reject `BSB001`.
4. Capture the leaf certificate's **SHA-256 DER fingerprint**, and check its CN
   equals the reported `bridgeid`. Persist host, `bridgeid`, and fingerprint
   together. **This is the trust decision**, and it happens exactly once.
5. Every subsequent connection verifies the presented certificate against the
   stored fingerprint via a `verify_fun`, and fails closed with
   `:certificate_changed` on mismatch.

Pinning the whole certificate rather than its public key is the right trade here:
the bridge's certificate is issued at manufacture and runs to 2038, so key
rotation behind a stable certificate is not a case that occurs, and whole-DER
comparison is markedly simpler to implement correctly against OTP's `:ssl`
records.

Trust-on-first-use is weaker than a real chain: an attacker present *during*
pairing is not detected. It is materially stronger than what every other Hue
client does, and the honest framing belongs in the README rather than in a claim
that the connection is authenticated. The window is one request on a home LAN,
at a moment the user chose.

A changed fingerprint is not silently accepted. It means either a factory-reset
bridge or an interception attempt, and the two are indistinguishable from here,
so it surfaces as an error the consumer must resolve by explicitly re-trusting.
`verify: :none` remains available for people who want `aiohue`'s behaviour, and
is never the default.

> **Corrected after implementation.** This referenced
> `Hue.Client.trust_new_certificate/1`, which was never built — there is no
> separate re-trust function. Re-trusting a bridge is re-running
> `Hue.Discovery.identify/2`: it repeats the same first-contact capture this
> section already describes, records whatever fingerprint the bridge presents
> this time, and the caller persists it, knowingly, exactly as they did on
> first pairing. A dedicated function would have to do the same thing under a
> different name.

**Discovered during implementation: TLS session resumption silently bypasses the
pin.** Installing a `verify_fun` is necessary but not sufficient. Once one
`verify_peer` connection to a `host:port` succeeds, OTP caches the session, and
the next connection to the same endpoint resumes it through an abbreviated
handshake in which the server presents **no certificate at all**. `verify_fun` is
therefore never called, and the stored fingerprint is never consulted: a second
client carrying a completely wrong pin connects and talks to the bridge, with no
error and no alert. The pin degrades to a one-shot check on the first connection
of the run. The bridge negotiates TLS 1.2 with session-id resumption — confirmed
independently of this library with `openssl s_client -reconnect`, which reports
`Reused` against an identical Session-ID. The constraint is therefore that
**every** branch of `Hue.Transport.ssl_options/1`, the unpinned first-contact
branch included, must carry `reuse_sessions: false` and `session_tickets:
:disabled` — the first covers TLS 1.2 session ids, the second TLS 1.3 PSK
tickets. The cost is a full handshake per connection rather than only the first,
which on a LAN is a few round trips and one RSA verification. A fixture suite
cannot catch this: each synthetic listener gets a fresh port and so has no
session to resume.

| Method | Works on | Fails on | Cost |
|---|---|---|---|
| mDNS `_hue._tcp.local` | Flat home LAN | Routed subnets, VLANs, containers | None |
| `discovery.meethue.com` | Anything sharing a public IP | No internet | Signify learns the IP; ~1 req/15 min |
| Manual host | Always | — | User must know the address |

`Hue.Discovery.discover/1` runs mDNS and cloud **concurrently**, merges by
`bridgeid`, and reports which method found each. Cloud discovery is **on by
default and disableable**: silently finding nothing is the worse outcome, and
the README states the trade plainly.

This is not hypothetical. The reference bridge sits at `192.168.178.146` while
the developing host is `192.168.68.67/22`, routed via `192.168.68.1`. mDNS is
link-local multicast and does not cross a router; `avahi-browse` returned
nothing while cloud discovery resolved the bridge instantly. Double-NAT behind
an ISP router, IoT VLANs, and containerised deployments all land in this case.

### `Hue.Bridge` internals

**State.** One ETS table owned by the GenServer, `:protected` with
`read_concurrency: true`, keyed `{type, rid}` → resource, plus a name index
`{type, name}` → rid rebuilt whenever a `metadata.name` changes.

**Reads bypass the process.** `Hue.Light.get(bridge, "Desk Lamp")` is an
`:ets.lookup` plus a graph walk, executed in the calling process. No message
passing, no serialisation, fully concurrent. This is what keeps the GenServer
from being the bottleneck that a naive cache process becomes.

**Writes go through the process.** Deliberately: it is the only place rate
limiting can live. See the write path below.

**Startup never blocks on the bridge.** `start_link/1` succeeds if the config
parses, then connects with backoff. A bridge that is rebooting must not stop the
consuming application from booting. `Hue.Bridge.status/1` reports
`:connecting | :syncing | :live | {:error, reason}`, and reads return
`{:error, :not_synced}` until the first full fetch completes.

**Reconnect always refetches.** No `Last-Event-ID` resumption. The full state is
154 KB in one request; refetching is always correct and eliminates the class of
bug where resumption appears to succeed while events were missed. Reconnect
backoff bounds how often it can happen on a flapping link. (`aiohue` keeps
resumption and refetches only past a 60-second gap — reasonable for a hub
tracking many bridges, but complexity bought for a 154 KB saving on an event
that should be rare.)

**Merging is recursive for maps, replacement for lists.** The distinction is
load-bearing: an event carrying `{"dimming": {"brightness": 86.11}}` must not
wipe the cached `min_dim_level` beside it, but a `services` list arriving in an
event is authoritative. Envelope types: `update` merges, `add` inserts, `delete`
removes, `error` is logged and surfaced through telemetry.

**Subscriptions** use `Registry`, which ships with Elixir:

```elixir
Hue.Bridge.subscribe(bridge)                    # everything
Hue.Bridge.subscribe(bridge, type: :button)     # just switches
Hue.Bridge.subscribe(bridge, name: "Iris")      # one light
```

Delivers `{:hue, %Hue.Event{}}` to the calling process, monitored so
subscriptions clean themselves up. Filtering happens at the registry: a consumer
waiting on button presses must not wake for all 19 lights when a scene runs.

Multiple bridges are multiple named children; no special casing.

#### Discovered during implementation (layer 2)

**Connect ordering.** The stream is opened before the full fetch, and its
events are buffered rather than applied until the seed completes, then
replayed on top of it. Fetching first would lose every change that happens in
the gap between the fetch and the stream opening — the state those events
modify would already be in the cache, with no path left to update it.
Buffer-then-replay narrows that window without closing it:
`Hue.Events.stream/2` connects lazily, on first enumeration, so there is a
moment between "the connect task started" and "the socket is actually open"
that the server cannot observe from the outside. That moment is smaller than
the fetch it replaces — request headers versus 154 KB of response — and
narrowing it costs nothing, but it is a narrowing, not a guarantee.

**Insert before pruning a reseed.** The cache's `seed/2` was first written to
clear the table and reinsert, restoring the lifecycle rows (`:__seeded__`,
`:__status__`) afterwards. That is wrong for a **reconnecting** bridge — not
the first sync, a later reseed after a stream drop — because reads happen in
other processes, concurrently with the server's own writes. A reader could
land in the gap between "table cleared" and "table refilled" and see
`status/1` answer `:not_started` and every read `:not_synced`, for a bridge
that had synced an hour ago and was merely refreshing its state. "Stale beats
refusing to answer" became, for that instant, "refuse to answer." The fix
generalises across the module: insert the new rows first, then prune whatever
the new state does not contain — never the reverse — which is also why
`@seeded_key` is written last rather than restored: there is nothing to
restore if it was never removed.

**Backoff must not reset on a successful fetch alone.** A bridge whose fetch
works every cycle but whose eventstream is refused (`eventstream_status: 403`
on the stub; a bridge with a working `/clip/v2/resource` but a broken
`/eventstream/clip/v2` in practice) would otherwise reconnect every ~20ms
forever: `seed/3` runs to completion, including a successful fetch, before the
server can process any message from the stream task it just spawned —
including that task immediately crashing — so a version that reset the
backoff on every successful seed reset it every single cycle, whether or not
the stream that just failed had ever been live. The fix is a `live_since`
guard: backoff only resets to its base value if the stream that just
disconnected had been up for at least one full `reconnect_after` interval,
which is the only evidence available that the failure is a fresh problem
rather than the same one repeating.

**`subscribe/2` had to be made idempotent by hand.** The subscription registry
is `:duplicate` (deliberately — one process can hold several distinct
subscriptions, one per filter), and a `:duplicate` registry's `register/3`
never returns `{:error, {:already_registered, pid}}` — every call succeeds and
adds its own entry, even for a key the calling process already holds. Nothing
in `Registry` itself makes calling `subscribe/2` twice with the same filter a
no-op; without an explicit check, a `mount/3` that runs twice (LiveView's
usual case) silently doubles delivery, permanently, with no error to notice it
by. `Hue.Bridge.subscribe/2` checks the registry's own entry list for the
calling pid under that key before registering.

**Partial write success was silently treated as success**, until the write
path started asking `Hue.Resource.update/5` for `return: :detailed`. CLIP v2
can answer a `PUT` with HTTP 200, a non-empty `data`, **and** a non-empty
`errors` — the bridge accepted part of the write and rejected the rest.
`Resource.interpret/2`'s default `:simple` mode was built for a caller who is
still there to inspect the result and matches on `%{"data" => data}` alone,
discarding `errors`; a write server has no caller left by the time the
response arrives; `[:hue, :write, :failed]` and the `error` event it produces
are the only two ways a rejection can surface, so silently discarding the
`errors` list that is the only evidence of one silently turned "the bridge
refused half of what you asked for" into "the write succeeded."

**`Req.Plug` batches chunks.** Req's test adapter runs a function plug to
completion and only converts the accumulated `Plug.Conn.chunk/2` calls into
delivered frames once the plug function *returns* — a frame sent on a
connection the stub is holding open is not observed by the client until the
connection closes (measured: a frame sent alone was still unobserved 1.5
seconds later). `Hue.Stub`'s eventstream therefore cannot be scripted as
"push one frame, assert, push another, assert" the way a real reconnect test
would want. The tests are written to the protocol's real shape instead — one
frame carries many envelopes, and each envelope carries many resource deltas,
which is what the reference bridge actually sends — so a test needing three
distinguishable events sends one frame containing three envelopes, and the
handful of tests that genuinely need separate deliveries close the connection
between them rather than relying on two frames staying apart on one open
connection.

### The write path

```elixir
:ok = Hue.Light.set(bridge, "Iris", on: true, color: "#ff8800", brightness: 40)
:ok = Hue.Light.set(bridge, "Overhead", kelvin: 2700, transition: 400)
:ok = Hue.Room.set(bridge, "Living Room", on: false)
:ok = Hue.Scene.recall(bridge, "Relax")
```

Options translate to CLIP v2 bodies — `brightness: 40` →
`%{"dimming" => %{"brightness" => 40.0}}`, `transition: 400` →
`%{"dynamics" => %{"duration" => 400}}`. `Hue.Resource.update/4` remains
available for anything not wrapped.

**Two kinds of wrongness, handled differently.** `brightness: "loud"` is a caller
bug and **raises**. `color:` sent to a white-only bulb is a capability mismatch
the caller could not have known about, and **returns**
`{:error, %Hue.Error{reason: :not_color_capable}}`. Because the cache holds every
light's capabilities, capability errors are caught **before the request leaves** —
strictly better than watching the bridge reject it. The reference bridge's two
non-dimmable lights make `:not_dimmable` a case that fires in real use.

**Writes are asynchronous by default.** `set` validates locally, returns `:ok`,
and queues. This is deliberate on two counts:

- The PUT response is not the truth. The state change arrives as an event a
  moment later, and blocking on the response would pretend otherwise.
- It is what makes coalescing possible. Twenty slider drags on one light collapse
  to the last value; the bridge sees one write. Pacing is per target type —
  roughly 10/s for lights, 1/s for grouped_lights, per Hue's guidance.

The errors worth catching are local and therefore still synchronous. Transport
failures surface via telemetry and as an `error` event to subscribers. `await: true`
blocks until the matching event lands, for callers that need confirmation.

### Color

For `color: "#ff8800"` against a specific light:

1. `Color.convert("#ff8800", Color.XyY)` — the `color` library performs sRGB
   gamma linearisation and the XYZ matrix, which is where hand-rolled
   implementations go subtly wrong.
2. Read that light's **own** `color.gamut` from cache.
3. Clamp: point-in-triangle test; if outside, project to the nearest point on the
   triangle's perimeter. Roughly 20 lines, and genuinely Hue-specific — `color`
   targets named working spaces, not arbitrary triangles.
4. Emit `%{"color" => %{"xy" => %{"x" => x, "y" => y}}}`.

Lights reporting no `gamut` fall back to the standard A/B/C triangles keyed off
`gamut_type`. All three types exist on the reference bridge, so every branch is
exercised against real hardware.

`kelvin: 2700` → `round(1_000_000 / 2700)` = 370 mirek, clamped to that light's
`color_temperature.mirek_schema` bounds rather than a hardcoded 153–500.

`Hue.Color.to_hex/2` exists for UIs needing a swatch. It is **approximate** — xy
carries no luminance — and the documentation says so rather than implying
round-tripping is lossless.

### Error model

`%Hue.Error{reason: atom, status: integer | nil, description: String.t() | nil,
type: String.t() | nil, rid: String.t() | nil}`.

Reasons are derived from HTTP status and local knowledge, because **CLIP v2 has
no numeric error codes**:

| Reason | Source |
|---|---|
| `:unauthorized` | HTTP 403, including the HTML-bodied form |
| `:link_button_not_pressed` | v1 pairing `type: 101` |
| `:not_found` | HTTP 404 |
| `:rate_limited` | HTTP 429 |
| `:bridge_busy` | HTTP 503 |
| `:unsupported_bridge` | `modelid` is `BSB001` |
| `:certificate_changed` | presented certificate ≠ pinned fingerprint |
| `:not_synced` | `Hue.Bridge` has not completed its first fetch |
| `:not_dimmable`, `:not_color_capable` | local capability check |
| `:no_grouped_light` | room or zone exposes no `grouped_light` service |
| `:timeout`, `:econnrefused`, `:closed`, `:nxdomain` | transport |

`:unauthorized` documents the fix in its own docstring — press the link button
and pair — because it is the most likely first-run failure and it arrives as an
HTML page rather than anything self-describing.

Partial success is represented, not flattened: a response carrying both `data`
and `errors` returns `{:ok, data, errors}` from `Hue.Resource` rather than
discarding either.

### Telemetry

```
[:hue, :request, :start | :stop | :exception]     duration, type, rid, status
[:hue, :pairing, :start | :stop | :exception]     duration, method, path, result
[:hue, :stream, :connected | :disconnected]       reason, downtime
[:hue, :sync, :stop]                              resource_count, duration
[:hue, :write, :coalesced]                        collapsed_count
[:hue, :write, :failed]                           reason
```

> **Corrected after implementation.** `[:hue, :write, :failed]` was missing
> from this list despite being emitted (`Hue.Bridge.Server`'s
> `report_write_failure/3`), tested, and described in "The write path" above
> — the prose already promised it. It fires whenever a queued write's PUT
> fails outright or comes back partly rejected, since by then `write/4` has
> already returned `:ok` to a caller who is long gone; telemetry and an
> `error` event to subscribers are the only two ways the failure can surface
> at all.
>
> **Corrected again, during layer 2.** `[:hue, :pairing]` was also missing,
> despite `Hue.Pairing.pair/2` wrapping its request in `:telemetry.span/3`
> since it was written. Start metadata carries `:method` and `:path`; stop
> metadata adds `:result` (`:ok` or `:error`) — the same shape as
> `[:hue, :request]`, since `Hue.Pairing` mirrors `Hue.Resource`'s span here
> even though it cannot reuse the code (pairing speaks the legacy v1 API, not
> CLIP v2). The application key and clientkey a successful pairing returns
> are deliberately never included in either event's metadata: an application
> key is exactly as sensitive as a password, and telemetry handlers are
> commonly attached loggers.

`[:hue, :stream, :disconnected]` is the important one. The characteristic failure
of this library is silence: a dead stream means every read is quietly stale, and
nothing else reveals it.

## Testing

Unit tests run against **responses recorded from the reference bridge**, served
through `Req.Test` stubs. No hardware required.

Fixtures are **sanitised before they are committed**, which `bravia` did not need
to do — its fixtures were picture settings, whereas a Hue full-state dump is a map
of a home. `bin/capture-fixtures` records; `bin/sanitize-fixtures` replaces every
UUID with a deterministic synthetic one, every `metadata.name` with a generic
label, and all bridge IDs, MACs, IP addresses, and coordinates with fixed
placeholders. Product names and model IDs are **kept** — they identify commercial
products, not households, and code may branch on them. Structure, capability
spread, gamut types, and the empty-room case all survive; the committed
`full_state.json` holds 178 resources across 22 types.

Coverage must include:

- All three wire formats, including the **HTML 403** and the **HTTP 200 v1
  pairing error**.
- **SSE chunk-boundary invariance**: the same frame split at every byte offset
  must decode identically. This is the bug class that costs days in production.
- Double-array frames — many envelopes, many resources each.
- Deep-merge correctness, specifically that a partial `dimming` does not erase
  `min_dim_level`.
- Graph resolution: name → room → `grouped_light`, and the two rooms where that
  service does not exist.
- Lights with no `dimming` and lights with no `color`.
- Colour clamping as a **property test**: for any input colour and any of the
  three real gamuts, the result lies inside the triangle.
- Certificate pinning: fingerprinting the real leaf, acceptance on match, and
  `:certificate_changed` on a substituted certificate.
- Reconnect: stream drop → backoff → full refetch → cache correctness.

A `@tag :live` suite is excluded by default and runs against real hardware with
`mix test --include live`, configured by `HUE_HOST` and `HUE_KEY`.

## Dependencies

Runtime: `req ~> 0.7`, `jason ~> 1.4`, `server_sent_events ~> 1.1`,
`telemetry ~> 1.0`, `color ~> 0.13`.

- `req` brings Finch, which is what makes the TLS `verify_fun` reachable via
  `connect_options: [transport_opts: …]`, and `Req.Test` is the stubbing seam.
- `server_sent_events` (251k recent downloads, MIT, maintained) is taken rather
  than hand-rolled: line-ending variants, multi-line `data:` accumulation,
  comment lines, and fields split across chunk boundaries are exactly the details
  a tested parser should own.
- `color` has **zero runtime dependencies of its own** and supplies `Color.XyY`
  and CCT ↔ chromaticity. The arbitrary-triangle clamp remains ours.
- No mDNS package: `mdns_lite` is Nerves-oriented and starts its own supervision
  tree, which a library must not do. Discovery uses `:gen_udp` with OTP's
  `:inet_dns` for packet coding.
- No `castore`, and no bundled certificate authority of any kind: trust is
  pinned per bridge on first use, so there is nothing to ship or keep current.

Development: `ex_doc`, `credo`, `dialyxir`, `plug` (test only, for `Req.Test`).

Targets Elixir `~> 1.17`, as `color` requires 1.17+/OTP 26+.

## Publishing

MIT. Semantic versioning from `0.1.0`. Docs on HexDocs via `ex_doc`, with a
README quickstart covering discovery and the link-button pairing flow — the two
steps most likely to block a new user. The `precommit` alias mirrors `bravia`:
`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `credo --strict`,
`dialyzer`, `test`.

## Consuming from Fae

Out of scope here; Fae's integration is its own piece of work. During
development Fae uses `{:hue, path: "../hue-ex"}`, moving to
`{:hue, "~> 0.1"}` once published. Fae will own a `Hue.Bridge` child in the
`Fae.HomeAutomation` subtree, subscribe, and rebroadcast onto `Phoenix.PubSub`
per decisions 006, 015, and 027 — the library never learns that Phoenix exists.

Two consequences belong to Fae rather than to this library: the application key
is a stored credential needing the same treatment decision-044 gave the BRAVIA
PSK, and lighting makes `NightDimming` an automation with several targets rather
than one, which is a redesign of that module rather than an addition to it. The
second is the one worth thinking about before writing code; whether either
warrants a decision record is a call for whoever does the work.

Fae currently resolves `req` at 0.5.17. Its `~> 0.5` requirement permits 0.7.x,
so there is no constraint conflict, but the lock will need `mix deps.update req`.
