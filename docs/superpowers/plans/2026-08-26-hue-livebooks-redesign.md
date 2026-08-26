# Livebooks Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the single example notebook into `examples/walkthrough.livemd` (live documentation) and `examples/control_panel.livemd` (a full control panel with management), then restructure the README around them.

**Architecture:** Spec: `docs/superpowers/specs/2026-08-26-hue-livebooks-redesign.md` — including the phase-0 measurements (bridge auto-moves devices and rewrites the old room's scenes; a room gaining its first light gains a `grouped_light`; `zigbee_device_discovery` is a singleton with one action, `"search"`). The panel is structure A: code in sections, one composed `Kino.Layout.tabs` output at the end, deployable as a Livebook app.

**Tech Stack:** Livebook, `{:hue, "~> 0.2"}`, `{:kino, "~> 0.19"}`.

**Conventions that bind every task:**

- Both notebooks read and write `examples/.hue.json`; pairing in either connects both. `File.chmod!(creds_path, 0o600)` after any write of it. No cell may end with an expression that renders the application key.
- Panel bridge name: `HuePanel`. Walkthrough bridge name stays `LivebookHue`.
- **Controls are created once; state lives in frames.** Event handling re-renders state frames from the cache. Topology events (`:add`/`:delete` of room, zone, light, scene, device) rebuild the affected tab's controls; state events never do.
- Every control's outcome is reported through `Panel.report/2` to the status frame. A rejected write is never silent.
- The panel does not optimistically update. Displays render from the cache, which the eventstream updates.
- Kino calls must be verified against kino 0.19 hexdocs at implementation time (this caught two plan errors last round: `Kino.frame/1` does not exist — it is `Kino.Frame.new/1` — and `Kino.start_child/1` ties the child to the cell). If a signature in this plan is wrong, fix the notebook to match kino AND make the identical fix in this plan, same commit.
- Notebook cells cannot run in CI. Tasks 1–6 are verified by proofread; Task 8 is the hardware run. Do not claim a notebook "works" before Task 8.
- Work on branch `livebook-example`. Nothing merges to `main` before Task 10.

---

### Task 1: Split — rename the walkthrough, trim it, fix the wiring

**Files:**
- Rename: `examples/hue.livemd` → `examples/walkthrough.livemd` (`git mv`)
- Modify: `examples/walkthrough.livemd`, `mix.exs`, `README.md`

- [ ] **Step 1: `git mv examples/hue.livemd examples/walkthrough.livemd`**

- [ ] **Step 2: Replace the walkthrough's "A little control panel" section** (heading, prose, and its whole code cell) with:

````markdown
## A control panel, elsewhere

Driving lights from forms is a different job from learning the API, so it
has its own notebook: [`control_panel.livemd`](control_panel.livemd) is a
full interface to your bridge — rooms, lights, scenes, management — and it
reuses the `.hue.json` this notebook just saved, so it connects without
pairing again.
````

- [ ] **Step 3: mix.exs** — the extras line becomes:

```elixir
      extras: ["README.md", {"examples/walkthrough.livemd", filename: "walkthrough"}],
```

(The panel's extra is added in Task 7, once the file exists.)

- [ ] **Step 4: README** — minimal path fixes only (the full restructure is Task 9): in the "Try it" section, change both the badge URL's encoded path and the link so they reference `examples/walkthrough.livemd`.

- [ ] **Step 5: Verify** — `mix docs` clean, page now at `doc/walkthrough.html`; `mix precommit` green; `grep -rn "hue.livemd" README.md mix.exs examples/` finds nothing.

- [ ] **Step 6: Commit** — `git add -A examples mix.exs README.md` · message: `Split the notebook: the walkthrough keeps its name honest`

---

### Task 2: Panel skeleton — connect, helpers, event router, Activity, status line

**Files:**
- Create: `examples/control_panel.livemd`

- [ ] **Step 1: Create the notebook** with this content. The first line is Livebook app metadata (verify the exact metadata keys against Livebook's docs for app settings; adjust if they differ — and sync this plan):

````markdown
<!-- livebook:{"app_settings":{"access_type":"public","slug":"hue-panel"}} -->

# Hue Control Panel

```elixir
Mix.install([
  {:hue, "~> 0.2"},
  {:kino, "~> 0.19"}
])
```

## Connect

Run all. If `.hue.json` exists beside this notebook (the walkthrough saves
it), the panel connects with it; otherwise it discovers your bridge and
pairs — press the round link button when asked.

```elixir
creds_path = Path.join(__DIR__, ".hue.json")

saved =
  case File.read(creds_path) do
    {:ok, json} -> Jason.decode!(json)
    {:error, :enoent} -> nil
  end

{bridge_info, application_key} =
  if saved do
    {%Hue.Bridge.Info{
       host: saved["host"],
       port: saved["port"],
       bridge_id: saved["bridge_id"],
       fingerprint: saved["fingerprint"]
     }, saved["application_key"]}
  else
    {:ok, [info | _]} = Hue.Discovery.discover()
    IO.puts("Press the round link button on the bridge…")
    {:ok, %{application_key: key}} = Hue.Pairing.pair_when_pressed(info, app: "livebook")

    File.write!(
      creds_path,
      Jason.encode!(%{
        host: info.host,
        port: info.port,
        bridge_id: info.bridge_id,
        fingerprint: info.fingerprint,
        application_key: key
      })
    )

    File.chmod!(creds_path, 0o600)
    {info, key}
  end

{:ok, client} = Hue.from_bridge(bridge_info, application_key: application_key)
{:ok, _} = Kino.start_child({Hue.Bridge, name: HuePanel, client: client})

Enum.reduce_while(1..50, nil, fn _, _ ->
  case Hue.Bridge.status(HuePanel) do
    :live ->
      {:halt, :live}

    status ->
      Process.sleep(200)
      {:cont, status}
  end
end)
|> case do
  :live -> :live
  status -> raise "bridge did not reach :live within 10s, last status: #{inspect(status)}"
end
```

## Helpers

`Panel` renders every dynamic region from the cache. Controls call
`Panel.report/2` with their outcome; the event router calls the `render_*`
functions when the cache changes.

```elixir
defmodule Panel do
  @bridge HuePanel

  # -- status line ---------------------------------------------------------

  def report(ui, text) do
    Kino.Frame.render(ui.status, Kino.Markdown.new("**#{text}**"))
  end

  def report_result(ui, label, :ok), do: report(ui, "#{label} ✓")

  def report_result(ui, label, {:error, %Hue.Error{reason: reason}}),
    do: report(ui, "#{label} — #{reason}")

  def report_result(ui, label, {:error, other}),
    do: report(ui, "#{label} — #{inspect(other)}")

  # -- naming --------------------------------------------------------------

  def name(type, rid), do: Hue.Bridge.name_of(@bridge, type, rid) || rid

  # -- the lights a room's devices carry -----------------------------------

  def lights_in_room(room) do
    for %{"rid" => device_rid, "rtype" => "device"} <- room["children"] || [],
        {:ok, device} = Hue.Bridge.fetch(@bridge, :device, device_rid),
        %{"rid" => light_rid, "rtype" => "light"} <- device["services"] || [],
        {:ok, light} = Hue.Bridge.fetch(@bridge, :light, light_rid),
        do: light
  end

  # -- activity ------------------------------------------------------------

  @activity_cap 50

  def describe(%Hue.Event{type: t, resource_type: rt, rid: rid, data: data}) do
    what =
      cond do
        get_in(data, ["on", "on"]) == true -> "on"
        get_in(data, ["on", "on"]) == false -> "off"
        get_in(data, ["dimming", "brightness"]) -> "#{round(get_in(data, ["dimming", "brightness"]))}%"
        get_in(data, ["metadata", "name"]) -> "renamed to #{get_in(data, ["metadata", "name"])}"
        true -> to_string(t)
      end

    "`#{rt}` **#{name(rt, rid)}** — #{what}"
  end

  def render_activity(ui, history) do
    history = Enum.take(history, @activity_cap)
    Kino.Frame.render(ui.activity, Kino.Markdown.new(Enum.join(history, "\n\n")))
    history
  end
end
```

## Event router

```elixir
ui = %{
  status: Kino.Frame.new(placeholder: false),
  rooms: Kino.Frame.new(),
  light_state: Kino.Frame.new(placeholder: false),
  scenes: Kino.Frame.new(),
  activity: Kino.Frame.new()
}

{:ok, _router} =
  Kino.start_child(
    {Task,
     fn ->
       :ok = Hue.Bridge.subscribe(HuePanel)

       Stream.repeatedly(fn -> receive do: ({:hue, e} -> e) end)
       |> Enum.reduce([], fn event, history ->
         [Panel.describe(event), history]
         |> List.flatten()
         |> then(&Panel.render_activity(ui, &1))
       end)
     end}
  )

:ok
```

## Panel

```elixir
Kino.Layout.tabs([
  {"Activity", ui.activity}
])
|> then(&Kino.Layout.grid([ui.status, &1], columns: 1))
```
````

Later tasks extend `Panel`, add tab sections between "Event router" and
"Panel", and grow the tabs list. The router's `reduce` gains render calls
per event type as tabs land (Task 3 adds the dispatch shown there).

- [ ] **Step 2: Proofread** — every hue call against `lib/` (`Hue.Bridge.fetch/3` returns `{:ok, map} | {:error, _}` — the `lights_in_room` comprehension matches `{:ok, x}` in a generator, which *filters* rather than crashes on a miss; confirm that is the wanted behavior and it is: a missing device mid-topology-change should drop out, not crash the renderer). Every Kino call against hexdocs 0.19, especially `Kino.Frame.new/1` options, `Kino.Frame.render/2`, `Kino.Layout.tabs/1` tab-list shape, and the app-settings metadata line. `receive do: ({:hue, e} -> e)` — verify this one-liner form parses; if not, use the block form.

- [ ] **Step 3: Commit** — `Begin the control panel: connect, router, activity`

---

### Task 3: Rooms tab

**Files:**
- Modify: `examples/control_panel.livemd`

- [ ] **Step 1: Add to `Panel`** (inside the module, new section before `# -- activity`):

```elixir
  # -- rooms ---------------------------------------------------------------

  def group_state_line(type, group) do
    case Hue.Bridge.grouped_light(@bridge, type, group["id"]) do
      {:ok, gl} ->
        on = if get_in(gl, ["on", "on"]), do: "on", else: "off"
        bri = get_in(gl, ["dimming", "brightness"])
        if bri, do: "#{on} · #{round(bri)}%", else: on

      {:error, _} ->
        "no lights"
    end
  end

  def render_group_states(ui, group_frames) do
    for {{type, rid}, frame} <- group_frames do
      case Hue.Bridge.fetch(@bridge, type, rid) do
        {:ok, group} ->
          Kino.Frame.render(frame, Kino.Markdown.new(group_state_line(type, group)))

        {:error, _} ->
          Kino.Frame.render(frame, Kino.Markdown.new("*(deleted)*"))
      end
    end

    :ok
  end
```

- [ ] **Step 2: Add a `## Rooms` section** after "Event router":

````markdown
## Rooms

One row per room, then per zone: name, live state, On/Off, brightness.
Controls are built once from the current topology; the small state frame in
each row is what live-updates.

```elixir
{:ok, rooms} = Hue.Room.list(HuePanel)
{:ok, zones} = Hue.Zone.list(HuePanel)

groups =
  Enum.map(rooms, &{:room, &1}) ++ Enum.map(zones, &{:zone, &1})

group_frames =
  Map.new(groups, fn {type, g} -> {{type, g["id"]}, Kino.Frame.new(placeholder: false)} end)

set_group = fn
  :room, target, opts -> Hue.Room.set(HuePanel, target, opts)
  :zone, target, opts -> Hue.Zone.set(HuePanel, target, opts)
end

room_rows =
  for {type, g} <- groups do
    gname = get_in(g, ["metadata", "name"])
    state_frame = group_frames[{type, g["id"]}]

    on = Kino.Control.button("On")
    off = Kino.Control.button("Off")
    bri = Kino.Control.form([brightness: Kino.Input.range("", min: 1, max: 100, default: 50)], report_changes: true)

    Kino.listen(on, fn _ ->
      Panel.report_result(ui, "#{gname} → on", set_group.(type, g["id"], on: true))
    end)

    Kino.listen(off, fn _ ->
      Panel.report_result(ui, "#{gname} → off", set_group.(type, g["id"], on: false))
    end)

    Kino.listen(bri, fn %{data: %{brightness: b}} ->
      Panel.report_result(ui, "#{gname} → #{round(b)}%", set_group.(type, g["id"], brightness: b))
    end)

    Kino.Layout.grid(
      [Kino.Markdown.new("**#{gname}**"), state_frame, on, off, bri],
      columns: 5
    )
  end

Kino.Frame.render(ui.rooms, Kino.Layout.grid(room_rows, columns: 1))
Panel.render_group_states(ui, group_frames)
```
````

- [ ] **Step 3: Wire the router.** Replace the router cell's `reduce` body so grouped_light/room/zone events refresh states (and note `group_frames` must now be built **before** the router cell — move the Rooms section above "Event router", or split frame creation from control creation; choose the ordering that keeps each cell self-contained and record the choice in this plan):

```elixir
         history = [Panel.describe(event), history] |> List.flatten()
         Panel.render_activity(ui, history)

         if event.resource_type in [:grouped_light, :room, :zone],
           do: Panel.render_group_states(ui, group_frames)

         history
```

- [ ] **Step 4: Add the tab** — tabs list gains `{"Rooms", ui.rooms}` first.

- [ ] **Step 5: Proofread** — `Hue.Bridge.grouped_light/3` (name-or-rid target? check its spec — it resolves via `Graph`; passing a rid must work, verify in `lib/hue/bridge.ex` and `lib/hue/bridge/graph.ex`), `report_changes: true` on `Kino.Control.form` (verify option name in hexdocs; the intent is slider events without a submit button — if a debounce option exists, use it), `Kino.Input.range` with empty-string label.

- [ ] **Step 6: Commit** — `Control panel: the rooms surface`

---

### Task 4: Lights tab

**Files:**
- Modify: `examples/control_panel.livemd`

- [ ] **Step 1: Add to `Panel`:**

```elixir
  # -- lights --------------------------------------------------------------

  def light_state_line(rid) do
    case Hue.Bridge.fetch(@bridge, :light, rid) do
      {:ok, light} ->
        on = if get_in(light, ["on", "on"]), do: "on", else: "off"
        bri = get_in(light, ["dimming", "brightness"])
        xy = get_in(light, ["color", "xy"])
        mirek = get_in(light, ["color_temperature", "mirek"])

        [
          on,
          bri && "#{round(bri)}%",
          xy && "xy #{Float.round(xy["x"], 3)},#{Float.round(xy["y"], 3)}",
          mirek && "#{mirek} mirek"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      {:error, _} ->
        "*(deleted)*"
    end
  end

  def render_light_state(ui, rid) do
    Kino.Frame.render(ui.light_state, Kino.Markdown.new(light_state_line(rid)))
  end
```

- [ ] **Step 2: Add a `## Lights` section** — a light picker whose selection is held in an `Agent` (started with `Kino.start_child`) so the router knows which light's state line to refresh:

````markdown
## Lights

```elixir
{:ok, lights} = Hue.Light.list(HuePanel)

light_options =
  lights
  |> Enum.map(fn l -> {l["id"], Panel.name(:light, l["id"])} end)
  |> Enum.sort_by(&elem(&1, 1))

{:ok, selected_light} = Kino.start_child({Agent, fn -> elem(hd(light_options), 0) end})

picker = Kino.Control.form([light: Kino.Input.select("Light", light_options)], report_changes: true)

controls =
  Kino.Control.form(
    [
      on: Kino.Input.checkbox("On", default: true),
      brightness: Kino.Input.range("Brightness", min: 1, max: 100, default: 50),
      color: Kino.Input.color("Colour", default: "#ffd08a"),
      kelvin: Kino.Input.range("Kelvin", min: 2000, max: 6500, default: 2700),
      use_color: Kino.Input.checkbox("Set colour (else colour temperature)", default: true),
      transition: Kino.Input.number("Transition ms", default: 400)
    ],
    submit: "Apply"
  )

blink = Kino.Control.button("Blink to identify")

Kino.listen(picker, fn %{data: %{light: rid}} ->
  Agent.update(selected_light, fn _ -> rid end)
  Panel.render_light_state(ui, rid)
end)

Kino.listen(controls, fn %{data: d} ->
  rid = Agent.get(selected_light, & &1)

  opts =
    [on: d.on, brightness: d.brightness, transition: d.transition] ++
      if(d.use_color, do: [color: d.color], else: [kelvin: round(d.kelvin)])

  Panel.report_result(ui, "#{Panel.name(:light, rid)} → apply", Hue.Light.set(HuePanel, rid, opts))
end)

Kino.listen(blink, fn _ ->
  rid = Agent.get(selected_light, & &1)
  {:ok, light} = Hue.Bridge.fetch(HuePanel, :light, rid)
  %{"rid" => device_rid} = light["owner"]

  result = Hue.Resource.update(client, :device, device_rid, %{"identify" => %{"action" => "identify"}})
  Panel.report_result(ui, "#{Panel.name(:light, rid)} → blink", result)
end)

Panel.render_light_state(ui, elem(hd(light_options), 0))

lights_tab =
  Kino.Layout.grid([picker, ui.light_state, controls, blink], columns: 1)
```
````

- [ ] **Step 3: Router** — after the group-states refresh, add:

```elixir
         if event.resource_type == :light and event.rid == Agent.get(selected_light, & &1),
           do: Panel.render_light_state(ui, event.rid)
```

- [ ] **Step 4: Tab** — `{"Lights", lights_tab}` after Rooms.

- [ ] **Step 5: Proofread** — `Kino.Input.color/2` existence and default format ("#rrggbb" — must match `Hue.Color`'s hex input), `Kino.Input.number/2`, `{Agent, fun}` as a `Kino.start_child` child spec, `light["owner"]` shape against the fixture (`test/support/fixtures/full_state.json`), the CLIP v2 device-identify body (`{"identify":{"action":"identify"}}`) against the fixture's device resource or Hue's public API reference — if it cannot be confirmed from the repo, mark it for Task 8 hardware verification in your report and in this plan.

- [ ] **Step 6: Commit** — `Control panel: one light, fully driven`

---

### Task 5: Scenes tab

**Files:**
- Modify: `examples/control_panel.livemd`

- [ ] **Step 1: Add to `Panel`:**

```elixir
  # -- scenes --------------------------------------------------------------

  def scene_action(light) do
    action =
      %{"on" => %{"on" => get_in(light, ["on", "on"])}}
      |> then(fn a ->
        if bri = get_in(light, ["dimming", "brightness"]),
          do: Map.put(a, "dimming", %{"brightness" => bri}),
          else: a
      end)
      |> then(fn a ->
        cond do
          xy = get_in(light, ["color", "xy"]) ->
            Map.put(a, "color", %{"xy" => xy})

          mirek = get_in(light, ["color_temperature", "mirek"]) ->
            Map.put(a, "color_temperature", %{"mirek" => mirek})

          true ->
            a
        end
      end)

    %{"target" => %{"rid" => light["id"], "rtype" => "light"}, "action" => action}
  end
```

- [ ] **Step 2: Add a `## Scenes` section** — per room: recall buttons for its scenes plus a save form. Scene→room grouping comes from each scene's `"group"` ref. Save creates via layer 1:

```elixir
save_scene = fn room, name ->
  actions = room |> Panel.lights_in_room() |> Enum.map(&Panel.scene_action/1)

  Hue.Resource.create(client, :scene, %{
    "metadata" => %{"name" => name},
    "group" => %{"rid" => room["id"], "rtype" => "room"},
    "actions" => actions
  })
end
```

Recall buttons: `Kino.Control.button(scene_name)` + `Kino.listen` →
`Panel.report_result(ui, "recall #{scene_name}", Hue.Scene.recall(HuePanel, scene["id"]))`.
Save form per room: `Kino.Control.form([name: Kino.Input.text("New scene from current state")], submit: "Save")` →
`report_result` on `save_scene.(room, name)` (a `{:ok, _}` create counts as success — normalize with `match?({:ok, _}, r)`).
Compose rows into `ui.scenes` the way Task 3 composed `ui.rooms`; scenes-tab
controls rebuild on `:scene` add/delete via a `rebuild_scenes` fun the router
calls (this is the topology-rebuild case; keep the fun in a cell variable the
router closes over).

- [ ] **Step 3: Tab** — `{"Scenes", ui.scenes}` after Lights.

- [ ] **Step 4: Proofread** — scene create body shape against the fixture's scene resources (`full_state.json` — confirm `actions`/`target`/`action` nesting and whether `"speed"` or other keys are required — the fixture is the measured truth); `Hue.Scene.recall/3` accepting a rid.

- [ ] **Step 5: Commit** — `Control panel: scenes recalled and captured`

---

### Task 6: Management tab

**Files:**
- Modify: `examples/control_panel.livemd`

Sub-tabs composed with a nested `Kino.Layout.tabs`, gated as the spec tiers them.

- [ ] **Step 1: Rename** — forms: type select (`light/room/zone/scene`) → dynamic resource select → text input → Apply. Renames go through layer 1: `Hue.Resource.update(client, type, rid, %{"metadata" => %{"name" => new_name}})`. (For `:light`, rename the owning **device** instead — the walkthrough documents that device names are authoritative; resolve owner as in Task 4's blink.)

- [ ] **Step 2: Rooms & zones** — create form (name text, archetype select with the CLIP archetypes from the fixture, e.g. `living_room`, `kitchen`, `bedroom`, `office`, `other`); membership editor: group select + device select + Add / Remove buttons operating on the group's `children` via `Hue.Resource.update`, with a live members list in a frame. Prose must carry the phase-0 finding verbatim in spirit: adding a device to a room removes it from its old room automatically, and the old room's scenes are rewritten by the bridge.

- [ ] **Step 3: Devices** — a "Search for new devices" button →
`Hue.Resource.update(client, :zigbee_device_discovery, discovery_rid, %{"action" => %{"action_type" => "search"}})`
(fetch `discovery_rid` via `Hue.Resource.list(client, :zigbee_device_discovery)`); a status frame the router refreshes on `:zigbee_device_discovery` events; new devices announce themselves on Activity. Device delete: device select + a text input labelled "Type the device's name to confirm" + Delete button that compares input to the device's current name and refuses on mismatch; on match `Hue.Resource.delete(client, :device, rid)`. Prose states recovery may require physically resetting the bulb.

- [ ] **Step 4: Delete** — scene/room/zone: type select + resource select + a Confirm checkbox that must be checked, then Delete. `Hue.Resource.delete/4`.

- [ ] **Step 5: Topology rebuilds** — router calls the rebuild funs for rooms/scenes/management pickers on `:add`/`:delete` events of `:room`, `:zone`, `:scene`, `:device`, `:light`.

- [ ] **Step 6: Tab** — `{"Management", management_tab}` between Scenes and Activity.

- [ ] **Step 7: Proofread** — archetype values against the fixture; every `Hue.Resource` arity; confirm-gate logic reads the *current* cached name at click time, not a stale binding.

- [ ] **Step 8: Commit** — `Control panel: management, tiered by consequence`

---

### Task 7: Docs wiring for the panel

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1:** extras gains `{"examples/control_panel.livemd", filename: "control_panel"}`.
- [ ] **Step 2:** `mix docs` clean; pages `walkthrough.html` and `control_panel.html` both present with Run-in-Livebook badges. `mix precommit` green.
- [ ] **Step 3: Commit** — `Publish the control panel alongside the walkthrough`

---

### Task 8: Hardware verification (user at the bridge)

- [ ] Walkthrough: fresh run (`rm examples/.hue.json`) top to bottom; re-run reconnects.
- [ ] Panel: run all with saved credentials; every tab exercised — rooms on/off/brightness, light controls incl. colour and blink (blink's body was unverifiable from the repo — this is its test), scene recall and save (delete the saved test scene via Management afterwards, which tests that gate too), rename + undo, membership move + restore, room create/delete, device search trigger and status (bulb join live-observation if a spare bulb is at hand — the deferred phase-0 item), Activity feed showing fan-out.
- [ ] Panel as Livebook app: deploy from the Livebook UI, confirm the composed output is usable full-screen.
- [ ] Fixes land as commits stating what the hardware run corrected; sync any notebook change into this plan if it contradicts a task's code.

---

### Task 9: README restructure

**Files:**
- Modify: `README.md`

Per the spec's "README restructure" section, in order:

- [ ] **Step 1: Description** — keep the opening two-line description; delete the "Three Hue clients already exist…" paragraph entirely (no commentary on other packages); fold the measured-against-hardware point into the feature list.
- [ ] **Step 2: Features** — new `## Features` bullet list after the description: discovery (mDNS ∥ cloud), link-button pairing, trust-on-first-use certificate pinning, generic CRUD over every CLIP v2 resource type, lazy eventstream, live bridge model (ETS reads, name addressing, write coalescing, `await:`), registry-filtered subscriptions, per-light gamut-clamped colour, telemetry, behaviour measured against a real bridge.
- [ ] **Step 3: Livebooks section** — replaces "Try it": quick start first —

  ```
  mix escript.install hex livebook
  curl -fsSLO https://raw.githubusercontent.com/ShawnMcCool/hue-ex/main/examples/walkthrough.livemd
  curl -fsSLO https://raw.githubusercontent.com/ShawnMcCool/hue-ex/main/examples/control_panel.livemd
  livebook server walkthrough.livemd
  ```

  then both notebooks named with one line each (walkthrough = the API journey; control panel = full UI, deployable as a Livebook app, shares the same pairing), then the two badges, then the clone-the-repo line.
- [ ] **Step 4: Install + Quickstart** — keep content; delete the editorial sentences ("The order below is the real one, and step four is the one people skip." and similar).
- [ ] **Step 5: Mental model** — merge the "Layer 2 — the live model" intro and "Scope" into one `## Two layers` section placed before the reference material; layer 1 = stateless protocol client, layer 2 = one supervised process per bridge, neither starts anything unasked; the deliberate exclusions list stays.
- [ ] **Step 6: Reference sections** — keep Telemetry (minus the two "Corrected…" blockquotes), Trust model, Discovery on real networks, The eventstream, Colour, Testing, Licence. Sweep flourishes: "Be clear-eyed about this one…", "earns its keep", any sentence whose removal loses no information.
- [ ] **Step 7:** `mix docs` + `mix precommit` green. **Step 8: Commit** — `Restructure the README around what a reader does first`

---

### Task 10: Merge and publish

- [ ] `git checkout main && git merge --no-ff livebook-example` (message: `Merge the Livebooks: a walkthrough that teaches, a panel that controls`)
- [ ] `mix precommit` on main.
- [ ] `git push origin main`
- [ ] `mix hex.publish docs` (docs-only republish for 0.2.0 — README, walkthrough, control panel go live; badges now resolve).
