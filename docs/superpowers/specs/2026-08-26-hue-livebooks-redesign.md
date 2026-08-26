# Design: two Livebooks — a walkthrough that teaches, a panel that controls

## Goal

The single `examples/hue.livemd` serves two purposes that pull its form in
opposite directions, and a README restructure is waiting on the result. Split
it:

- `examples/walkthrough.livemd` — live documentation for the developer
  adopting the package. Read top to bottom, prose between cells, one API idiom
  per cell. The current notebook minus its control-panel section.
- `examples/control_panel.livemd` — a fully featured interface to the user's
  own Hue setup: the Hue mobile app's job, scoped to what Livebook does well.
  "Run all", then everything is on screen.

Both read and write the same `examples/.hue.json`, so pairing once in either
notebook connects both.

## The control panel

Built around the property the Hue app itself lacks a window into: the bridge
pushes every state change and `Hue.Bridge` models it live, so the panel is
continuously true — a light flipped from the phone app updates the panel.
One subscriber task re-renders the affected frame on every event. Controls
write through layer 2; confirmation arrives back through the eventstream, so
using the panel demonstrates the library's actual write architecture.

Tabs (`Kino.Layout.tabs`), room-centric like the Hue app:

- **Rooms** — one row per room and zone: name, aggregate state from
  `grouped_light`, on/off, brightness.
- **Lights** — pick a light: on/off, brightness, colour (`Kino.Input.color`),
  colour temperature, transition, live state readout.
- **Scenes** — one recall button per scene, grouped by room.
- **Activity** — the event feed with resolved names and human phrasing
  ("Desk Lamp → on, 40%"), not `inspect(data)`.
- **Management** — everything below.

### Management scope

Management operations go through `Hue.Resource` with raw CLIP v2 payloads —
the library deliberately has no layer-2 wrappers for them, and the panel
thereby documents the layer-1 escape hatch alongside the layer-2 control
tabs.

Included, tiered by consequence:

| Tier | Operations |
|---|---|
| Instant | rename light/room/zone/scene · blink-to-identify · save current room state as a scene |
| Confirm click | delete scene · delete room/zone (lights survive, ungrouped) |
| Type-to-confirm | delete device — unpairs the bulb; recovery can require a physical bulb reset, and the prose says so |

Also included: room/zone create (name, archetype, members) and membership
editing. Kino likely has no multi-select input, so membership is
add/remove-one-at-a-time against a live members list — verify at
implementation. Device add runs through the `zigbee_device_discovery`
resource: trigger a search, watch its status, and new devices arrive on the
event feed the panel already renders.

Excluded: `behavior_instance` (automations). The payloads are per-vendor
blobs the API does not document, which makes a UI over them guesswork.

Free-form scene editing (designing per-light colours in a form) is also out:
that is a colour-wheel UI, which Livebook cannot do well. Scene creation is
snapshot-only.

### What Livebook cannot do well, so the panel does not attempt

Colour wheels, drag-to-dim on a row, sub-second slider feedback. Sliders,
buttons, and live numbers are the ceiling.

## Phase 0 — experiments before the design is final

Three mechanics must be measured against the real bridge before the
management tab is designed, in the repo's tradition of measuring rather than
trusting documentation:

1. **`zigbee_device_discovery`** — how a search is triggered on the reference
   firmware, what its status looks like while running, and how new devices
   announce themselves on the eventstream.
2. **Device-move-between-rooms semantics** — a device belongs to exactly one
   room; does adding it to room B auto-remove it from room A, or reject?
3. **Grouping lifecycle through the cache** — do room/zone create and delete
   events flow through `Hue.Bridge`'s cache cleanly (names resolvable
   immediately, no stale entries)?

Findings land in this spec. Anything the library handles badly (a cache gap,
an unrecognised event type) becomes library work before panel work.

### Findings

**Experiment 3 (grouping lifecycle) — passed, no library work needed.**
Measured 2026-08-26 against the reference bridge, via an empty room created,
renamed, and deleted through layer 1 while a `Hue.Bridge` watched:

- `create` answers `{:ok, [%{"rid" => ..., "rtype" => "room"}]}` and produces
  an `add :room` event carrying the full resource. The cache resolves the new
  room by name immediately. Creation fans out: `grouped_light` (group 0) and
  `bridge_home` also emit updates.
- A rename's `update :room` event carries only the metadata delta. The cache
  drops the old name and resolves the new one — `:not_found` under the old
  name, correct rid under the new.
- `delete` emits `delete :room`; the cache forgets both the name and the rid.
  No stale entries.
- An empty room answers `Hue.Room.set/3` with
  `{:error, %Hue.Error{reason: :no_grouped_light}}`, as documented.

**Experiment 2 (device move) — passed: the bridge auto-moves.** Measured
with the user-nominated "overhead" device (Kitchen). Writing the device into
a second room's `children` returns `:ok` and the bridge removes it from
Kitchen in the same stroke — no rejection, no explicit removal step. A move
in the panel is therefore a single write to the destination room. Two
side effects the management tab's prose must own:

- The old room's **scenes are rewritten by the bridge** — seven `update
  :scene` events arrived as Kitchen's scenes dropped the departed light's
  actions. Moving a device out of a room edits that room's scenes.
- A room that gains its first light **gains a `grouped_light` service**, as
  an `add :grouped_light` event — `:no_grouped_light` is a state a room
  leaves the moment a light arrives, not a permanent property.

The cache tracked all of it correctly (both rooms' children, the new
`grouped_light`), and restoring the original membership put Kitchen back
byte-for-byte. No library work needed.

**Experiment 1 (`zigbee_device_discovery`) — read-only probe done.** The
bridge exposes one singleton resource, owned by the bridge device:
`%{"action" => %{"action_type_values" => ["search"]}, "status" => "ready"}`.
So a search is triggered by an `update` with
`%{"action" => %{"action_type" => "search"}}`, and `status` should move off
`"ready"` while searching. The live observation of a joining bulb remains to
be run with the user.

## Panel structure (designed with the user after phase 0; approved)

**Composition.** Sections hold the code (Connect · Helpers · Panel); the
final cell renders one `Kino.Layout.tabs` output — Rooms | Lights | Scenes |
Management | Activity. App settings are declared so the notebook deploys as
a Livebook app: full-screen UI, no visible code.

**Rooms** — the home surface. One row per room and zone, all visible at once
(homes have few rooms): name, live aggregate from `grouped_light`, On and
Off buttons, brightness slider. Zones follow rooms, visually identical. A
room with no `grouped_light` shows "no lights" as its state. Its controls
stay active rather than disabled — controls are built once, so a disabled
row could never wake when a light arrives, and phase 0 measured that a room
gaining its first light gains a `grouped_light` in the same stroke; until
then a write fails visibly in the status line.

**Lights** — a picker plus one control cluster (homes have many lights):
select light → on/off, brightness, colour picker, colour-temperature slider,
transition input, live state line (on, brightness, xy/mirek, reachable).
Blink-to-identify lives here, not in Management — it is used while picking.

**Scenes** — recall buttons grouped by room, plus a per-room "save current
state as scene" form, since scenes are room-owned. Scene delete stays in
Management behind its gate.

**Management** — sub-tabs: Rename (type → resource → name form) · Rooms &
zones (create with name/archetype; membership add/remove-one-at-a-time
against a live members list; a note that moving a device rewrites the old
room's scenes) · Devices (search trigger with `zigbee_device_discovery`
status; delete behind type-the-name) · Delete (scenes, rooms, zones behind
confirm clicks).

**Activity** — the event feed, newest first, human phrasing, capped at the
last ~50 events.

**Live-sync.** One subscriber task; per-tab `Kino.Frame`s. Controls are
created once per topology; state lives in frames; an event re-renders the
affected state frame from the cache. Topology events (add/delete of rooms,
lights, scenes) rebuild the affected tab's controls — accepted listener
churn on rare events, never on state events. Writes go through layer 2 and
the UI never optimistically updates: it shows what the eventstream confirms,
making the library's write architecture visible.

**Error visibility.** Every control's result lands in a status line at the
top of the panel ("Kitchen → off" / "Desk Lamp: not dimmable"). A rejected
write is never silent.

## README restructure

Follows the notebooks, since it documents them. Agreed structure:

1. Brief description — no commentary on other packages (goes out of date).
2. Feature list.
3. Livebooks — copy-paste quick start first (escript install, `curl` the
   notebook, `livebook server`), badge second, clone third. Both notebooks
   listed with their purposes.
4. Install and in-app usage — current Install + Quickstart, editorial
   sentences removed.
5. Mental model — layers 1 and 2 merged from the current "Layer 2" intro and
   "Scope" sections.
6. Reference sections retained: Telemetry (correction blockquotes removed —
   that history lives in the specs), Trust model, Discovery on real networks,
   The eventstream, Colour, Testing, Licence. Flourish sentences removed
   throughout.

## Mechanical consequences of the split

- Rename `examples/hue.livemd` → `examples/walkthrough.livemd`; drop its
  control-panel section, leaving a one-line pointer to the panel notebook.
- `mix.exs` docs extras: two entries with explicit filenames (`walkthrough`,
  `control_panel`).
- README badge URLs updated to both notebooks.
- Everything stays on the `livebook-example` branch; nothing merges to `main`
  until the redesign is complete, so the badge URLs go live exactly once.
- `mix hex.publish docs` refresh happens after the merge, not before.

## Sequencing

1. Phase 0 experiments (needs the user at the bridge for device search).
2. Panel structure design session.
3. Split and rename; walkthrough trimmed.
4. Control panel implementation.
5. Hardware verification of both notebooks.
6. README restructure.
7. Merge, push, `mix hex.publish docs`.
