# hue

An Elixir client for the **Philips Hue CLIP v2** API — local, event-driven, and
gamut-correct.

> **Status: design complete, implementation not started.**
> The design is at
> [`docs/superpowers/specs/2026-08-06-hue-library-design.md`](docs/superpowers/specs/2026-08-06-hue-library-design.md),
> and every fact in it was measured against a real bridge rather than taken from
> documentation.

## What it will do

Hue models a home as a graph of 38 cross-linked resource types, so the useful
operations are all joins. "Dim the living room" means: find the `room` by name,
walk its services, select the `grouped_light`, and write to that. Done per call,
that is several round trips for one dim.

This library resolves the graph once and keeps it current from the bridge's
Server-Sent Events stream, in two layers:

- **A stateless protocol client** reaching every resource type. Starts no
  processes, holds no state, and is the escape hatch when a wrapper is missing.
- **An optional live model** — a supervised process you place in your own tree.
  Reads come from ETS in the calling process, so they are concurrent and cheap.
  Writes are serialised through the process, which is the only place rate
  limiting and coalescing can live.

```elixir
{:ok, light} = Hue.Light.get(bridge, "Desk Lamp")
:ok = Hue.Room.set(bridge, "Living Room", on: false)
:ok = Hue.Light.set(bridge, "Iris", color: "#ff8800", brightness: 40)
```

Colour accepts hex, RGB, or Kelvin and is clamped into the *target light's own*
gamut, because Hue reports gamut per light as three arbitrary xy primaries.

## Why not one of the existing packages

The three Hue clients on Hex all target the deprecated v1 API and are abandoned:
`huex` (2018), `exhue` (2018), and `hue_sdk` (2022). Signify has deprecated v1.

## Licence

MIT.
