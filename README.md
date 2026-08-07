# hue

An Elixir client for the **Philips Hue CLIP v2** API — local, event-driven,
certificate-pinned, and gamut-correct.

Three Hue clients already exist on Hex. All three target the v1 API that Signify
has since deprecated, and all three are abandoned: `huex` (last released 2018),
`exhue` (2018), and `hue_sdk` (2022). This one speaks CLIP v2, the API the
bridge actually documents today — over TLS, with the bridge's certificate
pinned rather than ignored.

Everything it claims about the protocol was measured against a real BSB002
running firmware `1.78.0`, not read off a documentation page. Where a
measurement contradicted the documentation, the measurement is what the code
does, and the moduledoc says so.

## Install

```elixir
def deps do
  [{:hue, "~> 0.1"}]
end
```

**This is not on Hex yet.** Until it is, depend on the tag:

```elixir
def deps do
  [{:hue, github: "ShawnMcCool/hue-ex", tag: "v0.1.0"}]
end
```

Requires Elixir 1.17 or later.

## Quickstart

The order below is the real one, and step four is the one people skip.

**1. Find the bridge.**

```elixir
{:ok, [bridge]} = Hue.Discovery.discover()

bridge
# %Hue.Bridge.Info{
#   host: "192.168.178.146",
#   port: 443,
#   bridge_id: "001788FFFEAE1B58",
#   model_id: "BSB002",
#   fingerprint: "21cdf48f…",
#   discovered_by: :cloud
# }
```

If you already know the address, skip discovery and confirm it directly —
`Hue.Discovery.identify("192.168.178.146")` returns the same struct.

**2. Press the round link button on the bridge.** Physically. This is the
authorisation step; there is no other one.

**3. Pair, within about thirty seconds of pressing it.**

```elixir
{:ok, keys} = Hue.Pairing.pair_when_pressed(bridge)

keys
# %{
#   application_key: "40-character-secret",
#   clientkey: "32-character-hex"
# }
```

`pair_when_pressed/2` blocks and retries, so you can start it and then walk over
and press the button. `Hue.Pairing.pair/2` is the single-shot version, and
returns `{:error, %Hue.Error{reason: :link_button_not_pressed}}` when it is too
early.

**4. Store the application key *and* the fingerprint.**

```elixir
%{
  host: bridge.host,
  bridge_id: bridge.bridge_id,
  fingerprint: bridge.fingerprint,
  application_key: keys.application_key
}
```

Everybody stores the application key, because nothing works without it. The
fingerprint is the half that gets dropped, and a client rebuilt without it
verifies nothing — it still works, silently, which is exactly why it goes
unnoticed. Persist both together or the pin does not survive a restart.

Treat the application key like a password. It is a bearer credential with full
control of the bridge, and it never expires on its own.

**5. Build a client and make a request.**

```elixir
{:ok, client} =
  Hue.new("192.168.178.146",
    application_key: application_key,
    fingerprint: fingerprint
  )

{:ok, lights} = Hue.Resource.list(client, :light)
:ok = Hue.Resource.update(client, :light, rid, %{"on" => %{"on" => true}})
```

If you still have the `Hue.Bridge.Info` from discovery, `Hue.from_bridge/2`
carries the id, port, and pin across for you:

```elixir
{:ok, client} = Hue.from_bridge(bridge, application_key: application_key)
```

Every CLIP v2 resource type goes through `Hue.Resource` — `light`, `room`,
`scene`, `grouped_light`, `behavior_instance`, and the thirty-odd others — so
nothing is ever blocked on a missing wrapper. `list/3` and `create/4` return
`{:ok, data}`, `get/4` returns `{:ok, resource}`, and `update/5` and `delete/4`
return a bare `:ok`, because the bridge answers a write with only the rid you
already had. The state change itself arrives on the eventstream.

## Layer 2 — the live model

Layer 1 is a protocol client: every call is a request. That is the right shape
for a script and the wrong shape for an application, because "dim the living
room" over layer 1 means listing rooms, finding one by name, walking its
services, and then writing — several round trips, every time.

`Hue.Bridge` keeps a live model instead. It fetches the full state once, follows
the eventstream, and answers reads from ETS.

```elixir
children = [
  {Hue.Bridge, name: MyApp.Hue, client: client}
]
```

It never starts itself. You place it in your supervision tree, the way you place
Finch or Redix.

```elixir
{:ok, light} = Hue.Light.get(MyApp.Hue, "Desk Lamp")
:ok = Hue.Light.set(MyApp.Hue, "Iris", color: "#ff8800", brightness: 40)
:ok = Hue.Room.set(MyApp.Hue, "Living Room", on: false)
:ok = Hue.Scene.recall(MyApp.Hue, "Relax")
```

Targets are names or rids, interchangeably. `Hue.Light`, `Hue.Room`, `Hue.Zone`,
and `Hue.Scene` cover the name-addressable operations; `Hue.Bridge.write/4` and
`Hue.Resource` remain available underneath for anything not wrapped.

### Reads do not touch the process

`Hue.Light.get/2` is an `:ets.lookup` in your process. It does not message the
bridge, does not serialise against other readers, and does not queue behind an
eventstream frame being merged.

Writes are the opposite, deliberately: they go through the process because that
is the only place coalescing and Hue's rate limits can live. Twenty slider drags
on one light become one request carrying the last value.

`set` returns `:ok` once the write is queued, not once it is applied — the PUT's
response is not the truth, and the state change arrives as an event a moment
later. Pass `await: true` when you need confirmation:

```elixir
:ok = Hue.Light.set(MyApp.Hue, "Iris", on: true, await: true)
```

A room or zone with no `grouped_light` service — two of the six rooms on the
reference bridge are like this — answers
`{:error, %Hue.Error{reason: :no_grouped_light}}` rather than inventing one to
write to. A capability mismatch, like `brightness:` against a non-dimmable
light, is caught from the cache before the request leaves at all.

### Subscribing

```elixir
Hue.Bridge.subscribe(MyApp.Hue, type: :button)

def handle_info({:hue, %Hue.Event{} = event}, state), do: ...
```

Filtering happens at the registry. A process waiting on button presses is not
woken when a scene changes nineteen lights. Subscribe with no filter for
everything, or with `name:` / `rid:` for one resource.

### The failure that is silent

A dead eventstream does not announce itself. Every read keeps answering, and
every answer is quietly stale — the bridge sends no keepalive, so an idle stream
is indistinguishable from a dead one at the protocol level. `Hue.Bridge` detects
it at the transport layer and reconnects with backoff, refetching the full state
each time rather than resuming from an event id.

Attach to `[:hue, :stream, :disconnected]` if you want to know. It is the single
most useful thing to monitor about this library.

## Telemetry

```
[:hue, :request, :start | :stop | :exception]   duration, type, rid, status
[:hue, :sync, :stop]                            duration, resource_count
[:hue, :stream, :connected]                     downtime
[:hue, :stream, :disconnected]                  reason
[:hue, :write, :coalesced]                      collapsed_count
[:hue, :write, :failed]                         reason
```

`[:hue, :request, *]` (layer 1, via `:telemetry.span/3`) fires around every
`Hue.Resource` call. Everything else is layer 2, emitted by the `Hue.Bridge`
process for whichever bridge it concerns (`metadata.bridge` is the name you
gave `Hue.Bridge`'s `:name` option).

`[:hue, :stream, :disconnected]` is the one worth attaching to unconditionally.
This library's characteristic failure mode is silent: a dropped eventstream
leaves every read answering, and every answer quietly stale, because there is
no keepalive to miss and reads never ask the process how current its data is.
That event is the only thing that reveals it.

## Trust model

Be clear-eyed about this one, because the honest version is genuinely useful and
the marketing version is not.

A Hue bridge presents a certificate whose common name is its bridge id — not a
hostname — with **no subjectAltName**, signed by a Signify root that is neither
sent on the wire nor published anywhere you can download it. There is no name to
match and no certificate authority to bundle. Ordinary TLS verification cannot
succeed against a Hue bridge, by construction.

So this library pins instead. The first connection to a bridge records the
SHA-256 fingerprint of the certificate it presented, and every connection after
that requires the same one. That is the SSH host-key model, and it has the same
shape of guarantee:

- **An attacker present during first contact is not detected.** Whatever answers
  at that moment becomes the trusted certificate. Pair over a network you trust,
  which for a home LAN and a bridge you just plugged in is a low bar, but it is a
  bar. There is no getting around this — you cannot bootstrap trust out of
  nothing.
- **Every interception after first contact is detected**, and fails closed with
  `{:error, %Hue.Error{reason: :certificate_changed}}`.

For comparison: `aiohue`, the client Home Assistant ships and the most mature
implementation in any language, sets `ssl=False` and verifies nothing at all.
That is the de facto industry practice, and it is a defensible reading of a
protocol that makes verification this hard. Pinning is materially stronger — it
turns an indefinitely open window into a single moment — but it is stronger than
nothing rather than strong in the way a web PKI chain is strong.

`:certificate_changed` means one of two things: your traffic is being
intercepted, or the bridge was factory-reset and issued a new certificate. **This
library cannot tell those apart, and neither can you from the error alone.** It
refuses the connection and leaves the decision to you. Re-trusting is deliberate:
capture the new fingerprint with `Hue.Discovery.identify/2` and store it,
knowingly.

`verify: :none` is available if you want `aiohue`'s behaviour. It is never the
default, and `Hue.new/2` raises rather than quietly accepting a TLS option it
cannot honour — in a library whose job is to verify, a rejected option must not
be mistakable for an applied one.

One implementation note worth knowing, because it is a trap: **TLS session
resumption silently bypasses a pin.** A resumed session presents no certificate,
so `verify_fun` is never called and the fingerprint is never compared. Every
connection this library makes therefore performs a full handshake
(`reuse_sessions: false`, `session_tickets: :disabled`). The cost is a few round
trips on a LAN. The alternative is a pin that stops being enforced after the
first connection, which is no pin at all. See `Hue.Transport`.

## Discovery on real networks

mDNS is link-local multicast. It does not cross a router, and when it fails it
fails silently — no error, no packet, just an empty list that looks exactly like
"you have no bridge". Double-NAT behind an ISP router, an IoT VLAN, and a
container all land in this case, and it is common enough that this library was
developed on such a network: host on `192.168.68.0/22`, bridge on
`192.168.178.146`. `avahi-browse` found nothing at all; the cloud endpoint
answered instantly.

So `Hue.Discovery.discover/1` runs mDNS and the cloud endpoint **concurrently by
default** and merges the results, preferring the mDNS record because it proves
link-local reachability that a cloud answer does not.

```elixir
Hue.Discovery.discover(cloud: false)  # mDNS only
Hue.Discovery.discover(mdns: false)   # cloud only
```

Cloud discovery contacts `discovery.meethue.com`, which matches on your public IP
and returns local addresses. No credentials are sent and no bridge data leaves
your network, but **Signify learns your IP address**. If that is not a trade you
want, pass `cloud: false` and accept that on a routed network you will have to
supply the host yourself.

Every candidate, whichever method found it, is confirmed by
`Hue.Discovery.identify/2` before it is returned, and confirming is where the
certificate is pinned. A candidate that cannot be confirmed is not returned — but
it is logged at `:warning` with its address and the reason, because "found it,
could not reach it" and "found nothing" call for completely different fixes.

## The eventstream

`GET /eventstream/clip/v2` pushes every state change, which is what makes a
correct local model possible without polling.

```elixir
client
|> Hue.Events.stream()
|> Enum.each(fn %Hue.Event{} = event ->
  IO.inspect({event.type, event.resource_type, event.rid, event.data})
  # {:update, :light, "8b8ea3f2-…", %{"on" => %{"on" => true}, …}}
end)
```

`stream/2` returns a lazy `Enumerable` and **starts no process of its own**. The
connection opens when the stream is first enumerated, in whichever process
enumerates it, and closes when the stream stops — including when the consumer
halts early, so `Enum.take(stream, 1)` releases the socket rather than leaking
it. Where that enumeration runs is your decision: a `Task`, a `GenServer` doing
nothing else, whatever fits your supervision tree.

**It does not reconnect.** A dropped connection raises `Hue.Error` out of the
enumeration and that is the end of it. Reconnecting is the caller's job, because
the caller is the only thing that knows whether the events it already handled
make a fresh request the right move. Req's retry is force-disabled on this
request for the same reason: a partly-read stream cannot be resumed by repeating
it, and each abandoned attempt leaves its own chunks in your mailbox.

**Silence is not evidence of anything.** The bridge sends a `: hi` comment on
connect and then, measured, nothing at all for a hundred seconds on an idle
stream. There is no keepalive to miss, so an idle stream is
protocol-indistinguishable from a dead one. `stream/2` waits forever by default.
You can set `receive_timeout: 30_000` and treat silence as death, and that is a
reasonable policy — just know that it will sometimes fire on a perfectly healthy
bridge that simply had nothing to say. No liveness policy over this protocol is
correct; pick the way you prefer to be wrong.

`Hue.Events.decode/1` and `decode_stream/1` decode bytes without opening
anything, if you would rather own the connection yourself. Both handle a frame
split across chunk boundaries at any byte, which is the bug class that eats
hand-rolled SSE parsers.

## Colour

You think in hex, RGB, and Kelvin. Hue speaks CIE xy and mirek, and the
representable range differs **per light**: gamut arrives as three arbitrary xy
primaries that vary by model, and a single bridge commonly hosts several kinds at
once. A colour outside a particular light's triangle is not approximately right,
it is unreachable on that light.

So every conversion here takes the target light's own resource and clamps into
its own gamut:

```elixir
{:ok, light} = Hue.Resource.get(client, :light, rid)

{:ok, body} = Hue.Color.payload("#ff8800", light)
# %{"color" => %{"xy" => %{"x" => 0.5336217655640444, "y" => 0.41447683322855305}}}
:ok = Hue.Resource.update(client, :light, rid, body)

{:ok, mirek} = Hue.Color.mirek_for(2700, light)   # clamped to this light's range
:ok = Hue.Resource.update(client, :light, rid, %{"color_temperature" => %{"mirek" => mirek}})
```

`Hue.Color.to_xy/2` gives you the clamped pair without the payload wrapper, and
accepts `"#ff8800"`, `{255, 136, 0}`, or an explicit `{:xy, x, y}`.

Going the other way, `Hue.Color.to_hex/1` is **for swatches only**. An xy pair
carries no luminance, so converting back invents one — the maximum — and the
result is always the brightest colour of that hue. `#000000`, `#808080`, and
`#ffffff` are all achromatic, share one chromaticity, and all come back
`"#ffffff"`. Use it to show *which* colour a light is set to. Never to show *how
bright*.

Bridge-data problems come back as errors (`:not_color_capable` for a light with
no colour support, `:invalid_gamut` for gamut data that cannot be parsed). Input
that could never have been valid — an RGB component outside `0..255`, a hex
string that is not hex, a non-positive Kelvin — raises. That split holds
throughout the library: `Hue.Error` means something outside the process refused
you; a caller bug raises.

## Scope

Layer 1 (`Hue`, `Hue.Client`, `Hue.Resource`, and friends) is a **stateless
protocol client**: it starts no processes, holds no state between calls,
caches nothing, and reconnects nothing. It reaches every CLIP v2 resource type
generically, so it is never the thing blocking you. Layer 2 (`Hue.Bridge` and
the name-addressable modules above it) opts into exactly one supervised
process per bridge you configure — see "Layer 2" above. Neither layer starts
anything you did not ask for.

What this library deliberately does not do:

- **No Entertainment streaming.** The DTLS-based low-latency protocol is out of
  scope. Pairing does request `generateclientkey: true` and hands you the
  `clientkey`, so adding Entertainment later stays additive and nobody has to
  re-pair to get a key they were never given.
- **No configuration system beyond `Hue.Bridge`'s own options.** `Hue.Client`
  wraps a `Req.Request`, so your timeouts, your retry policy, and your test
  stubs are configured the way you already configure Req.

## Testing

```
mix test                  # offline, no network, 516 tests
mix test --include live   # adds 17 tests against real hardware
mix precommit             # compile --warnings-as-errors, format, credo --strict, dialyzer, test
```

The offline suite runs against bytes recorded from a real BSB002 — a full
178-resource state dump, real eventstream frames, and the bridge's actual HTML
403 page — plus synthetic certificates generated at test time for the pinning
paths, and `Hue.Stub`'s function-plug bridge for `Hue.Bridge`. It touches no
network.

Point the live suite at your own bridge:

```
HUE_HOST=192.168.178.146 HUE_KEY=your-application-key mix test --include live
```

It is excluded by default, so an ordinary `mix test` never reaches for the
network. The layer-1 tests in it are read-only — every request is a `GET`; it
never pairs, never writes, never deletes. The layer-2 tests are
**read-and-restore**: `Hue.Bridge` exists to be written to, so those tests
toggle a real light or nudge a real brightness and use `on_exit/1` to put it
back before the test process ends, win or lose. Nothing it touches is left
changed.

The live suite earns its keep. The session-resumption bypass described above
was found by a live test and cannot be reproduced against fixtures, because
each synthetic listener gets a fresh port and so has no session to resume —
and the layer-2 tests exist to check `Hue.Bridge.Writes`'s coalescing and
pacing against a real bridge's actual rate limit, rather than trusting that
`Hue.Stub`'s model of one agrees with it.

## Licence

MIT. See [LICENSE](https://github.com/ShawnMcCool/hue-ex/blob/main/LICENSE).
