# Livebook Example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One notebook, `examples/hue.livemd`, that walks a new user through discover → pair → control → live events against their real bridge, doubling as an interactive light-control tool.

**Architecture:** A single Livebook file consuming the *published* `hue 0.2.0` package via `Mix.install`. Pairing output is persisted to a gitignored `examples/.hue.json` so later runs skip discovery and pairing. The notebook also becomes an `ex_doc` extra so the walkthrough appears on HexDocs. Spec: `docs/superpowers/specs/2026-08-25-hue-livebook-example-design.md`.

**Tech Stack:** Livebook (`.livemd` markdown), `{:hue, "~> 0.2"}`, `{:kino, "~> 0.19"}` (tables, forms, frames, `start_child`), `Jason` (already a hue dependency) for the credentials file.

**Conventions that bind every task:**

- Every code cell must use only these verified APIs: `Hue.Discovery.discover/1`, `Hue.Pairing.pair_when_pressed/2` (options `:app`, `:timeout`), `Hue.from_bridge/2`, `{Hue.Bridge, name: ..., client: ...}` child spec, `Hue.Bridge.status/1` (`:connecting | :syncing | :live | {:error, _} | :not_started`), `Hue.Light.list/1`, `Hue.Light.set/3` (options `:on`, `:brightness`, `:color`, `:kelvin`, `:transition`, `:await`), `Hue.Room.list/1`, `Hue.Scene.list/1`, `Hue.Scene.recall/3`, `Hue.Bridge.subscribe/2`, `Hue.Bridge.name_of/3`.
- Light names come from `Hue.Bridge.name_of(LivebookHue, :light, rid)` — a light's own `metadata` is deprecated in CLIP v2; the owning device's name is authoritative. Rooms, zones, and scenes are named by their own `metadata.name`.
- Events are delivered as `{:hue, %Hue.Event{}}` with fields `type`, `resource_type`, `rid`, `data`.
- The application key is a secret: no cell may end with an expression whose printed result contains it (Livebook renders the last expression). Cells that bind it end with a throwaway atom.
- Notebook cells cannot be executed by CI. Tasks 1–4 are verified by proofreading against the APIs above; Task 6 is the real verification, top-to-bottom against hardware. Do not claim the notebook "works" before Task 6.

---

### Task 1: Notebook scaffold — setup, credentials, discover, pair

**Files:**
- Create: `examples/hue.livemd`
- Modify: `.gitignore`

- [ ] **Step 1: Create `examples/hue.livemd`** with exactly this content (the first code cell is Livebook's setup cell):

````markdown
# Controlling Philips Hue

```elixir
Mix.install([
  {:hue, "~> 0.2"},
  {:kino, "~> 0.19"}
])
```

## What this notebook does

This is the [hue](https://hexdocs.pm/hue) library's worked example: it finds
your bridge, pairs with it, controls lights by name, and watches state
changes stream in live. Run it top to bottom against a real bridge on your
network.

The first run pairs — you'll press the bridge's round link button once. The
result is saved beside this notebook, so every later run reconnects without
asking.

## Saved credentials

An application key is a password. This cell keeps it out of the notebook
file itself, in `.hue.json` next to the notebook (gitignored in the hue
repository). Delete that file to start over from discovery.

```elixir
creds_path = Path.join(__DIR__, ".hue.json")

saved =
  case File.read(creds_path) do
    {:ok, json} -> Jason.decode!(json)
    {:error, :enoent} -> nil
  end

if saved, do: :reconnecting, else: :first_run
```

## Find the bridge

`Hue.Discovery.discover/1` runs mDNS and Philips' cloud endpoint in
parallel, then verifies each candidate with a real connection and pins the
certificate it finds — the SSH host-key model, because a Hue bridge's
certificate can't be verified any conventional way. The pin rides along in
the returned `Hue.Bridge.Info` and every later connection checks against it.

On a re-run this cell rebuilds that `Info` from the saved file instead.

```elixir
bridge_info =
  if saved do
    %Hue.Bridge.Info{
      host: saved["host"],
      port: saved["port"],
      bridge_id: saved["bridge_id"],
      fingerprint: saved["fingerprint"]
    }
  else
    {:ok, [first | _]} = Hue.Discovery.discover()
    first
  end
```

## Pair

**Press the round link button on your bridge, then run this cell** — the
bridge only honours pairing requests for about thirty seconds after a
press, and this cell polls for up to a minute, so either order works if
you're quick.

On a re-run, the saved key is used and nothing is sent to the bridge.

```elixir
application_key =
  if saved do
    saved["application_key"]
  else
    {:ok, %{application_key: key}} =
      Hue.Pairing.pair_when_pressed(bridge_info, app: "livebook")

    File.write!(
      creds_path,
      Jason.encode!(%{
        host: bridge_info.host,
        port: bridge_info.port,
        bridge_id: bridge_info.bridge_id,
        fingerprint: bridge_info.fingerprint,
        application_key: key
      })
    )

    key
  end

:paired
```
````

- [ ] **Step 2: Add the credentials file to `.gitignore`** — append after the `hue-*.tar` line:

```
# The Livebook example's saved pairing (an application key is a password).
/examples/.hue.json
```

- [ ] **Step 3: Proofread the cells against the library** — check each call in the cells above against `lib/hue/discovery.ex`, `lib/hue/pairing.ex`, and `lib/hue/bridge.ex` (the `Info` struct: fields `host`, `port`, `bridge_id`, `model_id`, `fingerprint`, `discovered_by`). Confirm no cell ends by printing the key (`:paired` guards the pairing cell).

- [ ] **Step 4: Commit**

```bash
git add examples/hue.livemd .gitignore
git commit -m "Begin the Livebook example: discover and pair"
```

---

### Task 2: Start the bridge and explore the cache

**Files:**
- Modify: `examples/hue.livemd` (append)

- [ ] **Step 1: Append these sections** to `examples/hue.livemd`:

````markdown
## Start the live bridge

`Hue.Bridge` never starts itself — it's a `child_spec` you place in your own
supervision tree, the way Finch or Redix are. In an application that looks
like:

<!-- livebook:{"force_markdown":true} -->

```elixir
children = [
  {Hue.Bridge, name: MyApp.Hue, client: client}
]
```

In Livebook, `Kino.start_child/1` is that same placement. On start the
bridge fetches everything once to seed its cache, then holds an eventstream
open to keep it current; `:live` means both are done. Re-running this cell
errors with `:already_started` — that's your supervision tree telling the
truth, not a bug. Restart the runtime to start over.

```elixir
{:ok, client} = Hue.from_bridge(bridge_info, application_key: application_key)
{:ok, _supervisor} = Kino.start_child({Hue.Bridge, name: LivebookHue, client: client})

Enum.reduce_while(1..50, nil, fn _, _ ->
  case Hue.Bridge.status(LivebookHue) do
    :live -> {:halt, :live}
    status -> Process.sleep(200) && {:cont, status}
  end
end)
```

## What's in the house

Reads are `:ets.lookup` calls in your own process — they never touch the
bridge or even the bridge's process. A light's own `metadata` is deprecated
in CLIP v2, so names are resolved through the owning device, which
`Hue.Bridge.name_of/3` does for you.

```elixir
{:ok, lights} = Hue.Light.list(LivebookHue)

lights
|> Enum.map(fn light ->
  %{
    name: Hue.Bridge.name_of(LivebookHue, :light, light["id"]),
    on: get_in(light, ["on", "on"]),
    brightness: get_in(light, ["dimming", "brightness"])
  }
end)
|> Enum.sort_by(& &1.name)
|> Kino.DataTable.new(name: "Lights")
```

Rooms and scenes carry their own authoritative names:

```elixir
{:ok, rooms} = Hue.Room.list(LivebookHue)
{:ok, scenes} = Hue.Scene.list(LivebookHue)

Kino.Layout.grid(
  [
    Kino.DataTable.new(
      Enum.map(rooms, &%{room: get_in(&1, ["metadata", "name"])}),
      name: "Rooms"
    ),
    Kino.DataTable.new(
      Enum.map(scenes, &%{scene: get_in(&1, ["metadata", "name"])}),
      name: "Scenes"
    )
  ],
  columns: 2
)
```
````

- [ ] **Step 2: Proofread** — `Hue.from_bridge/2` carries the pin and raises on disagreement; `Kino.start_child/1` returns `{:ok, pid}`; `status/1` values match `lib/hue/bridge.ex:174`. The resource maps are raw CLIP JSON with string keys.

- [ ] **Step 3: Commit**

```bash
git add examples/hue.livemd
git commit -m "Livebook example: start the bridge and explore the cache"
```

---

### Task 3: Control by name, then a control panel

**Files:**
- Modify: `examples/hue.livemd` (append)

- [ ] **Step 1: Append these sections:**

````markdown
## Control, by name

Pick one of your lights from the table above and use its name here. Writes
accept `:on`, `:brightness` (percent), `:color` (hex, RGB tuple, or xy),
`:kelvin`, and `:transition` (milliseconds). A capability the light doesn't
have — colour on a white-only bulb — returns `{:error, %Hue.Error{}}`; a
malformed value raises, because that's a bug in the code, not a fact about
the bulb.

```elixir
light = "Desk Lamp"

:ok = Hue.Light.set(LivebookHue, light, on: true, brightness: 40)
```

`set` returns when the write is accepted, not when the light has changed —
writes are coalesced and paced so a burst never floods the bridge. When you
need confirmation, `await: true` blocks until the confirming event comes
back down the eventstream:

```elixir
Hue.Light.set(LivebookHue, light, color: "#ff8800", transition: 400, await: true)
```

Rooms, zones, and scenes work the same way — `Hue.Room.set/3`,
`Hue.Zone.set/3`, `Hue.Scene.recall/3`:

```elixir
# :ok = Hue.Room.set(LivebookHue, "Living Room", on: false)
# :ok = Hue.Scene.recall(LivebookHue, "Relax")
:skipped
```

## A little control panel

The example turns tool here: pick a light and drive it. This is nothing but
the calls you just made, wired to a form.

```elixir
light_names =
  lights
  |> Enum.map(&Hue.Bridge.name_of(LivebookHue, :light, &1["id"]))
  |> Enum.sort()

form =
  Kino.Control.form(
    [
      light: Kino.Input.select("Light", Enum.map(light_names, &{&1, &1})),
      on: Kino.Input.checkbox("On", default: true),
      brightness: Kino.Input.range("Brightness", min: 1, max: 100, default: 50)
    ],
    submit: "Apply"
  )

Kino.listen(form, fn %{data: data} ->
  Hue.Light.set(LivebookHue, data.light, on: data.on, brightness: data.brightness)
end)

form
```
````

- [ ] **Step 2: Proofread** — option names against `lib/hue/bridge/body.ex:88` (`@known_options [:on, :brightness, :color, :kelvin, :transition]`) plus `:await` from `Hue.Light.set/3`. `Kino.Input.range` yields a float; confirm `Body` accepts a float brightness (CLIP brightness is a float percentage) by checking `validate_option!/1`'s brightness clause — if it requires an integer, add `round()` in the listener instead.

- [ ] **Step 3: Commit**

```bash
git add examples/hue.livemd
git commit -m "Livebook example: control by name and a control panel"
```

---

### Task 4: Live events and the closing section

**Files:**
- Modify: `examples/hue.livemd` (append)

- [ ] **Step 1: Append these sections:**

````markdown
## Watch it live

Subscribing delivers `{:hue, %Hue.Event{}}` to the calling process, and the
subscription dies with that process — so the listener below is a supervised
task that subscribes itself. Flip a light in the Hue app, or use the control
panel above, and watch the deltas arrive. Notice a single change fans out:
the bridge also recomputes group aggregates, so one light produces a
`grouped_light` event too.

```elixir
frame = Kino.frame(placeholder: false)

{:ok, _listener} =
  Kino.start_child(
    {Task,
     fn ->
       :ok = Hue.Bridge.subscribe(LivebookHue)

       Stream.repeatedly(fn ->
         receive do
           {:hue, event} ->
             name = Hue.Bridge.name_of(LivebookHue, event.resource_type, event.rid)

             Kino.Frame.append(
               frame,
               Kino.Markdown.new(
                 "`#{event.resource_type}` **#{name || event.rid}** → `#{inspect(event.data)}`"
               )
             )
         end
       end)
       |> Stream.run()
     end}
  )

frame
```

## Where to next

Everything this notebook did, your application does with the same calls:
put `{Hue.Bridge, name: MyApp.Hue, client: client}` in your supervision
tree, store the application key like the password it is, and read the
[moduledocs](https://hexdocs.pm/hue) — `Hue.Bridge` for the live model and
its failure semantics, `Hue.Light` for writes, `Hue.Resource` for the
stateless layer-1 escape hatch this notebook never needed.
````

- [ ] **Step 2: Proofread** — subscription message shape and process-lifetime semantics against `lib/hue/bridge.ex:300-346`; `Hue.Event` fields against `lib/hue/event.ex:52`. Confirm the filter-by-name example isn't used here (the listener wants everything, to show fan-out).

- [ ] **Step 3: Commit**

```bash
git add examples/hue.livemd
git commit -m "Livebook example: live events and the closing pointer"
```

---

### Task 5: README and HexDocs integration

**Files:**
- Modify: `README.md` (after the Quickstart section)
- Modify: `mix.exs:77-89` (the `docs/0` private function)

- [ ] **Step 1: Add a "Try it" section to `README.md`**, immediately after the Quickstart section's content (before `## Layer 2 — the live model`):

```markdown
## Try it

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2FShawnMcCool%2Fhue-ex%2Fmain%2Fexamples%2Fhue.livemd)

[`examples/hue.livemd`](examples/hue.livemd) is an interactive notebook that
walks the whole journey against your real bridge — discover, pair (one press
of the link button), control lights by name, and watch changes stream in
live. It doubles as a small light-control panel.
```

- [ ] **Step 2: Add the notebook as an ex_doc extra** in `mix.exs`:

```elixir
  defp docs do
    [
      main: "readme",
      extras: ["README.md", "examples/hue.livemd"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Core: [Hue, Hue.Client, Hue.Resource, Hue.Error],
        Setup: [Hue.Discovery, Hue.Bridge, Hue.Bridge.Info, Hue.Pairing, Hue.Transport],
        Events: [Hue.Events, Hue.Event],
        Colour: [Hue.Color, Hue.Color.Gamut]
      ]
    ]
  end
```

- [ ] **Step 3: Build and inspect the docs**

Run: `mix docs`
Expected: no warnings; then open `doc/hue.html` and confirm the notebook renders as a page with a "Run in Livebook" badge in the sidebar-listed extras. If `.livemd` misrenders, the spec's fallback applies: drop the extra, keep the README link, and note the reason in the commit message.

- [ ] **Step 4: Run the precommit suite**

Run: `mix precommit`
Expected: all green — the notebook is not compiled, so only the `mix.exs` change is exercised.

- [ ] **Step 5: Commit**

```bash
git add README.md mix.exs
git commit -m "Point README and HexDocs at the Livebook example"
```

---

### Task 6: Verify against the real bridge, then refresh HexDocs

**Files:**
- Modify: `examples/hue.livemd` (only if the run finds problems)

This is the task where the notebook is actually verified. Everything before it was proofread, not run.

- [ ] **Step 1: First run, from nothing** — `rm -f examples/.hue.json`, then open the notebook (`livebook server examples/hue.livemd`; if the command is missing, `mix escript.install hex livebook` first) and evaluate top to bottom. Confirm each of:
  - Discovery finds the bridge with a non-nil `fingerprint`.
  - The pairing cell blocks until the link button is pressed, then writes `examples/.hue.json`, and its cell output is `:paired` — the key must not appear anywhere in the rendered notebook.
  - Status reaches `:live`; the lights table shows real names.
  - The named `set` calls change the actual light, and the `await: true` call visibly returns only after the light changes.
  - The control panel drives a light end to end.
  - Flipping a light in the Hue app appends events to the frame, including the fanned-out `grouped_light` event.
- [ ] **Step 2: Second run, reconnect path** — restart the Livebook runtime and run top to bottom again. Confirm the credentials cell reports `:reconnecting`, no pairing request is sent (the pair cell is instant), and everything downstream still works.
- [ ] **Step 3: Fix what the run surfaced** — apply any corrections to the notebook, re-run the affected sections, and commit them with messages saying what the hardware run corrected (the layer-2 convention, e.g. "Reject a malformed colour whatever bulb is in the socket").
- [ ] **Step 4: Push and refresh HexDocs**

```bash
git push origin main
mix hex.publish docs
```

`mix hex.publish docs` republishes documentation for 0.2.0 without cutting a release — the notebook consumes the already-published package, so no version bump is needed.

- [ ] **Step 5: Mark the spec's verification section satisfied** — nothing to edit unless something deviated; if it did, record the correction in the spec the way the layer-1/2 specs do ("Corrected after implementation").
