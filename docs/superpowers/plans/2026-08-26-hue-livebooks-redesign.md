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
    {:error, reason} -> raise "could not read #{creds_path}: #{inspect(reason)}"
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

    {:error, _} = err ->
      {:halt, err}

    status ->
      Process.sleep(200)
      {:cont, status}
  end
end)
|> case do
  :live -> :live
  status -> raise "bridge did not reach :live, status: #{inspect(status)}"
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
        {:ok, device} <- [Hue.Bridge.fetch(@bridge, :device, device_rid)],
        %{"rid" => light_rid, "rtype" => "light"} <- device["services"] || [],
        {:ok, light} <- [Hue.Bridge.fetch(@bridge, :light, light_rid)],
        do: light
  end

  # -- activity ------------------------------------------------------------

  @activity_cap 50

  def describe(%Hue.Event{type: :error, resource_type: rt, rid: rid, data: %Hue.Error{reason: reason}}) do
    "`#{rt}` **#{name(rt, rid)}** — write failed: #{reason}"
  end

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

```elixir
ui = %{
  status: Kino.Frame.new(placeholder: false),
  rooms: Kino.Frame.new(),
  light_state: Kino.Frame.new(placeholder: false),
  scenes: Kino.Frame.new(),
  activity: Kino.Frame.new()
}
```

## Event router

```elixir
{:ok, _router} =
  Kino.start_child(
    {Task,
     fn ->
       :ok = Hue.Bridge.subscribe(HuePanel)

       Stream.repeatedly(fn -> receive do: ({:hue, e} -> e) end)
       |> Enum.reduce([], fn event, history ->
         [Panel.describe(event) | history]
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

The `ui` map gets its own cell at the end of "Helpers", after the `Panel`
module — not inside the router cell — because later tasks (Task 3 on) add a
`## Rooms`-style section between "Helpers" and "Event router" that builds its
own frames (e.g. `group_frames`) and needs `ui` already in scope; the router
cell in turn needs those frames in scope, so it must come after them. Final
cell order from Task 3 onward: Connect → Helpers (`Panel` module, then `ui`)
→ Rooms → Event router → Panel. Later tasks extend `Panel`, add tab sections
between the `ui` cell and "Event router", and grow the tabs list. The
router's `reduce` gains render calls per event type as tabs land (Task 3
adds the dispatch shown there).

- [ ] **Step 2: Proofread** — every hue call against `lib/` (`Hue.Bridge.fetch/3` returns `{:ok, map} | {:error, _}` — the `lights_in_room` comprehension matches `{:ok, x}` against a *singleton-list generator* (`{:ok, x} <- [fetch(...)]`), which filters rather than crashes on a miss; a plain `{:ok, x} = fetch(...)` match would instead raise `MatchError` on `{:error, _}`, so the `<-`-over-a-list idiom is load-bearing, not stylistic. Confirm the filtering behavior is wanted and it is: a missing device mid-topology-change should drop out, not crash the renderer). Every Kino call against hexdocs 0.19, especially `Kino.Frame.new/1` options, `Kino.Frame.render/2`, `Kino.Layout.tabs/1` tab-list shape, and the app-settings metadata line. `receive do: ({:hue, e} -> e)` — verify this one-liner form parses; if not, use the block form.

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

  def render_group_states(group_frames) do
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

- [ ] **Step 2: Add a `## Rooms` section** between "Helpers" and "Event
  router" — right after the `ui` cell, so the row controls built here can
  close over `ui`, and so `group_frames` (built here) is in scope for the
  router cell that follows:

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
Panel.render_group_states(group_frames)
```
````

- [ ] **Step 3: Wire the router.** The Rooms section now sits above "Event
  router" (Step 2), so `group_frames` is already in scope there. Replace the
  router cell's `reduce` body so grouped_light/room/zone events refresh
  states:

```elixir
         history = [Panel.describe(event) | history] |> then(&Panel.render_activity(ui, &1))

         if event.resource_type in [:grouped_light, :room, :zone],
           do: Panel.render_group_states(group_frames)

         history
```

- [ ] **Step 4: Add the tab** — tabs list gains `{"Rooms", ui.rooms}` first.

- [ ] **Step 5: Proofread** — confirmed clean, no code changes needed:
  - `Hue.Bridge.grouped_light/3` accepts a rid target with no adaptation.
    `Bridge.grouped_light/3` delegates to `Graph.grouped_light/3`, which
    calls `Graph.resolve/3`, which calls `Cache.fetch(table, type, target)`
    first — an exact `:ets.lookup(table, {type, target})` — before ever
    falling back to the name index. A rid matches that lookup directly.
  - `Hue.Room.set/3` / `Hue.Zone.set/3` accept a rid target for the same
    reason: both go through `Hue.Group.set/4`, which calls
    `Bridge.grouped_light/3` with the target unchanged.
  - `report_changes: true` is a real option on `Kino.Control.form/2` in kino
    0.19 (`lib/kino/control.ex`): "Either `:submit` or `:report_changes`
    must be specified," and setting it emits a `:change` event with the
    field data on every input change, no submit button required. No
    separate debounce option is needed at the form level —
    `Kino.Input.range/2` already debounces at 250ms by default
    (`lib/kino/input.ex`), which is the behavior wanted here.
  - `Kino.Input.range(label, opts)` requires `is_binary(label)`; `""` is a
    binary, so the empty label parses and matches every other input's
    calling convention.
  - `Kino.Control.button/1` events are `%{origin: ..., type: :click}`
    (documented in `lib/kino/control.ex`); the plan's handlers ignore the
    payload (`fn _ -> ...`), which is correct since only the fact of a click
    matters.
  - `Kino.listen/2` accepts a bare `%Kino.Control{}` directly (it implements
    `Enumerable`), so `Kino.listen(on, fn _ -> ... end)` is valid without
    wrapping in `Kino.Control.stream/1`.
  - `Kino.Layout.grid(terms, columns: n)` (`lib/kino/layout.ex`) lays `terms`
    into a grid with `n` columns; a 5-element list with `columns: 5` is one
    row, and `columns: 1` on the list of rows stacks them one per line —
    both call sites do what the section intends.

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
          mirek && "#{mirek} mirek",
          connectivity_status(light)
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

  # v2 has no reachability field on :light itself — "reachable" lives on the
  # owning device's zigbee_connectivity service. Every step degrades to nil
  # rather than crashing: a device with no such service (e.g. a zgp remote),
  # a cache miss mid-topology-change, or simply the normal "connected" case,
  # which is deliberately silent so the line doesn't get noisier for the
  # common state.
  defp connectivity_status(light) do
    with %{"rid" => device_rid} <- light["owner"],
         {:ok, device} <- Hue.Bridge.fetch(@bridge, :device, device_rid),
         %{"rid" => zc_rid} <-
           Enum.find(device["services"] || [], &(&1["rtype"] == "zigbee_connectivity")),
         {:ok, zc} <- Hue.Bridge.fetch(@bridge, :zigbee_connectivity, zc_rid),
         status when status != "connected" <- zc["status"] do
      status
    else
      _ -> nil
    end
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
      transition: Kino.Input.number("Transition ms", default: 400, min: 0)
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
    [on: d.on, brightness: d.brightness] ++
      (if d.transition, do: [transition: round(d.transition)], else: []) ++
      if(d.use_color, do: [color: d.color], else: [kelvin: round(d.kelvin)])

  Panel.report_result(ui, "#{Panel.name(:light, rid)} → apply", Hue.Light.set(HuePanel, rid, opts))
end)

Kino.listen(blink, fn _ ->
  rid = Agent.get(selected_light, & &1)

  case Hue.Bridge.fetch(HuePanel, :light, rid) do
    {:ok, light} ->
      %{"rid" => device_rid} = light["owner"]

      result = Hue.Resource.update(client, :device, device_rid, %{"identify" => %{"action" => "identify"}})
      Panel.report_result(ui, "#{Panel.name(:light, rid)} → blink", result)

    {:error, err} ->
      Panel.report_result(ui, "blink", {:error, err})
  end
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

         if event.resource_type == :zigbee_connectivity,
           do: Panel.render_light_state(ui, Agent.get(selected_light, & &1))
```

The `:zigbee_connectivity` clause is unconditional on which device changed —
it is a rare event, and re-rendering the selected light's state line from
cache is cheap — unlike the `:light` clause above it, which is filtered to
the selected rid because light events are frequent.

- [ ] **Step 4: Tab** — `{"Lights", lights_tab}` after Rooms.

- [ ] **Step 5: Proofread** — confirmed clean against kino 0.19.0 and `lib/`, one correction made (already folded into Step 2's code above):
  - `Kino.Input.color/2` exists (`lib/kino/input.ex`); default `"#6583FF"`, value is always a `"#"`-prefixed hex string, never `nil`. `Hue.Color`'s `to_chromaticity/1` accepts exactly that shape (`"#" <> _`), and `Hue.Bridge.Body.validate_option!/1` accepts the same shape for `:color` — no adaptation needed.
  - `Kino.Input.number/2` exists; value is a number **or `nil`** if the field is cleared (the docstring says so explicitly). `Hue.Bridge.Body`'s `:transition` validation requires a non-negative integer and raises `ArgumentError` otherwise — an uncaught raise inside a `Kino.listen` callback is swallowed by Kino's own `safe_apply` (logged, listener keeps running) rather than reported to `ui.status`, which would make a bad transition value a **silent** failure, violating "every control's outcome is reported." Fixed: the opts list omits `:transition` entirely when `d.transition` is `nil`, and only calls `round/1` (guarding the float-vs-integer case, same reasoning as `:kelvin`) when a value is present. Also added `min: 0` to the input itself as a UI-level nudge.
  - `{Agent, fn -> ... end}` as a `Kino.start_child/1` child spec: confirmed valid. `Kino.start_child/1` calls `Supervisor.child_spec(child_spec, [])`, which for a `{module, arg}` tuple calls `module.child_spec(arg)`; `Agent.child_spec(fun)` (stdlib) returns `%{id: Agent, start: {Agent, :start_link, [fun]}}`, and `Kino.start_child/1` returns `{:ok, pid}` from `DynamicSupervisor.start_child/2` — so `{:ok, selected_light} = Kino.start_child(...)` binds `selected_light` to the agent's pid, and `Agent.get/2`/`Agent.update/2` work on it directly.
  - `light["owner"]` shape confirmed against `test/support/fixtures/full_state.json`: every light resource carries `"owner" => %{"rid" => <device-rid>, "rtype" => "device"}` — matches `%{"rid" => device_rid} = light["owner"]` exactly.
  - `Hue.Resource.type/1` knows `:device` — `"device"` is in `@resource_type_names` in `lib/hue/resource.ex`, and the fixture's device resources carry `"type": "device"`, `"services"` (list of `%{"rid", "rtype"}`), and an `"identify" => %{}` key (empty on read, as CLIP v2 documents for a write-only action field) — consistent with, but not proof of, the write body.
  - The identify write body `%{"identify" => %{"action" => "identify"}}` is **unverifiable from this repo** — the fixture is a captured GET response, which never contains a write payload, and nothing else in `lib/` or `test/` touches `identify`. Kept as-is. Task 8 already carries the hardware-verification line for this ("blink's body was unverifiable from the repo — this is its test"), so no addition needed there.
  - Apply handler's opts: `use_color` branch correctly picks `color:` vs `kelvin:`. `Hue.Bridge.Body` accepts `:kelvin` as `is_integer(value) and value > 0` (`lib/hue/bridge/body.ex`), clamped to the light's own mirek schema by `Hue.Color.mirek_for/2`; `Kino.Input.range/2` always emits a float (its own doc: "either float in the configured range"), so `round(d.kelvin)` is required, not decorative — same as the brightness float already accepted as-is since `:brightness` validation allows any number.
  - `Hue.Light.set/3` with a rid target: confirmed — `set/3` calls `get(bridge, target)`, i.e. `Bridge.resolve(bridge, :light, target)`, the same resolution path Task 3 verified for rooms/zones (exact ETS lookup by rid before the name index).
  - Binding order: the `## Lights` section sits after `## Rooms` and before `## Event router` in the notebook, so `ui`, `Panel`, and `client` (all bound in earlier cells) are in scope, and `selected_light` (bound in Lights) is in scope for the router's added dispatch clause.
  - **Reachability**: CLIP v2's `:light` resource has no reachability field of its own — "reachable" is the owning device's `zigbee_connectivity` service's `"status"` field. Confirmed against `test/support/fixtures/full_state.json`: 20 `zigbee_connectivity` resources, each `%{"id", "id_v1", "mac_address", "owner" => %{"rid", "rtype" => "device"}, "status", "type"}`, with observed statuses `"connected"` and `"connectivity_issue"`. Implemented as `Panel.connectivity_status/1` (private), taking the already-fetched light map (avoiding a redundant re-fetch) and walking light → `owner` → device → `services` → the entry with `"rtype" == "zigbee_connectivity"` → its cached resource → `"status"`, via a `with` chain where every step's mismatch (missing owner, missing device, no such service, e.g. a zgp device with no zigbee_connectivity, or a cache miss) falls through to `else -> nil`; the terminal clause additionally guards `status when status != "connected"` so the common case renders nothing. `light_state_line/1`'s element list gains this as its final entry, dropped by the existing `Enum.reject(&is_nil/1)` when `nil`. The router gains a `:zigbee_connectivity` clause, unconditional on device identity (see Step 3), since this event type is rare and the render is a cheap cache read.
  - **Blink's fetch, guarded**: the original `{:ok, light} = Hue.Bridge.fetch(...)` inside the blink listener would raise `MatchError` if the selected light had been deleted since selection — the same silent-failure class as the transition-nil bug above (Kino's `safe_apply` swallows it, `Panel.report_result` never runs). Replaced with a `case`: `{:error, err}` now reports `Panel.report_result(ui, "blink", {:error, err})` instead of crashing invisibly.
  - All 8 code cells syntax-checked with `Code.string_to_quoted!/1` — clean.
  - Minor, unfixed, out of scope: `hd(light_options)` (both the Agent's initial value and the section's final `render_light_state` call) raises if the bridge reports zero lights. Every reference bridge fixture and every plausible install has at least one light, and Task 3's `groups` (rooms ++ zones) has the identical unguarded shape, so this is left consistent with that precedent rather than special-cased here.

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
          mirek = get_in(light, ["color_temperature", "mirek"]) ->
            Map.put(a, "color_temperature", %{"mirek" => mirek})

          xy = get_in(light, ["color", "xy"]) ->
            Map.put(a, "color", %{"xy" => xy})

          true ->
            a
        end
      end)

    %{"target" => %{"rid" => light["id"], "rtype" => "light"}, "action" => action}
  end
```

- [ ] **Step 2: Add a `## Scenes` section** between "Lights" and "Event
  router" — right after the `## Lights` section, so `save_scene` and
  `rebuild_scenes` (built here) are in scope for the router cell that
  follows. Prose, then code, exactly:

````markdown
## Scenes

Scenes are room-owned: a scene's `"group"` names the room it belongs to, and
recalling it drives every light that room's devices carry to the state it
captured. Saving snapshots the room's current light state into a new scene.

Recall buttons and save forms are rebuilt from scratch whenever a scene is
added or deleted (topology), never on a plain state update. That rebuild
replaces `ui.scenes`' contents, but the controls it discards keep their own
`Kino.listen` processes running unless those are stopped explicitly — Kino
ties a control's lifetime to the pid that created it terminating, or to that
pid's *cell* re-evaluating (`Kino.Bridge.reference_object/2`'s doc: "Any
monitoring added to object will be dispatched once all of its associated
pids terminate or the associated cells reevaluate"), never to whether the
control is still rendered anywhere. Since every rebuild runs from the same
long-lived router process, neither condition ever fires between rebuilds, so
the old listener processes would otherwise accumulate for the life of the
session. `scene_listeners` holds the pids `Kino.listen` returns so each
rebuild can `Kino.terminate_child/1` the previous batch before starting the
next. A click that lands in the narrow window while a rebuild is replacing
its button can be dropped along with the listener that would have handled
it; this is accepted rather than guarded against, since the reappearing row
is itself the feedback that the click needs to be repeated.

Scene renames arrive as a plain `:update`, which does not trigger a rebuild,
so a renamed scene's button keeps its old label until the next add or
delete — recall keys on rid, not name, so the stale label still recalls the
right scene.

```elixir
{:ok, scene_listeners} = Kino.start_child({Agent, fn -> [] end})

save_scene = fn room, name ->
  actions = room |> Panel.lights_in_room() |> Enum.map(&Panel.scene_action/1)

  Hue.Resource.create(client, :scene, %{
    "metadata" => %{"name" => name},
    "group" => %{"rid" => room["id"], "rtype" => "room"},
    "actions" => actions
  })
end

rebuild_scenes = fn ->
  Enum.each(Agent.get(scene_listeners, & &1), &Kino.terminate_child/1)

  {:ok, scenes} = Hue.Scene.list(HuePanel)
  {:ok, rooms} = Hue.Room.list(HuePanel)

  by_group = Enum.group_by(scenes, & &1["group"]["rid"])
  room_ids = MapSet.new(rooms, & &1["id"])

  scene_row = fn scene ->
    name = get_in(scene, ["metadata", "name"])
    button = Kino.Control.button("Recall")

    pid =
      Kino.listen(button, fn _ ->
        Panel.report_result(ui, "recall #{name}", Hue.Scene.recall(HuePanel, scene["id"]))
      end)

    {pid, Kino.Layout.grid([Kino.Markdown.new(name), button], columns: 2)}
  end

  group_block = fn heading, group_scenes, save_room ->
    {pids, rows} = group_scenes |> Enum.map(scene_row) |> Enum.unzip()

    save_row =
      if save_room do
        form =
          Kino.Control.form([name: Kino.Input.text("New scene from current state")], submit: "Save")

        form_pid =
          Kino.listen(form, fn %{data: %{name: name}} ->
            result = save_scene.(save_room, name)
            outcome = if match?({:ok, _}, result), do: :ok, else: result
            Panel.report_result(ui, "save \"#{name}\"", outcome)
          end)

        [{form_pid, form}]
      else
        []
      end

    {save_pids, save_rows} = Enum.unzip(save_row)

    block =
      Kino.Layout.grid([Kino.Markdown.new("**#{heading}**")] ++ rows ++ save_rows, columns: 1)

    {pids ++ save_pids, block}
  end

  room_results =
    for room <- rooms do
      group_block.(get_in(room, ["metadata", "name"]), Map.get(by_group, room["id"], []), room)
    end

  leftover_results =
    for {group_rid, group_scenes} <- by_group, not MapSet.member?(room_ids, group_rid) do
      %{"rtype" => rtype} = hd(group_scenes)["group"]

      group_type =
        case rtype do
          "room" -> :room
          "zone" -> :zone
          _ -> nil
        end

      heading = if group_type, do: Panel.name(group_type, group_rid), else: group_rid
      group_block.(heading, group_scenes, nil)
    end

  {pid_lists, blocks} = Enum.unzip(room_results ++ leftover_results)

  Kino.Frame.render(ui.scenes, Kino.Layout.grid(blocks, columns: 1))
  Agent.update(scene_listeners, fn _ -> List.flatten(pid_lists) end)
end

rebuild_scenes.()
```
````

  Rooms with zero scenes still get a block (heading + save form, no recall
  rows) so a fresh room can capture its first scene. Scenes whose `"group"`
  rid matches no listed room (zone-owned scenes, e.g. `full_state.json`'s
  "Scene 15/16/22") group under a heading resolved via `Panel.name/2` and get
  recall rows but no save form — save is room-only by construction (the
  create body's `"group"` is hardcoded to `"rtype" => "room"`). The leftover
  branch maps `rtype` through an explicit `case` rather than
  `String.to_existing_atom/1`: an unrecognised `rtype` falls through to
  `nil` and the block heads with the raw group rid rather than risking an
  `ArgumentError` on an atom the runtime never interned.

- [ ] **Step 3: Router** — after the `:zigbee_connectivity` clause, add:

```elixir
         if event.resource_type == :scene and event.type in [:add, :delete] do
           try do
             rebuild_scenes.()
           rescue
             e -> Panel.report(ui, "scenes rebuild failed: #{Exception.message(e)}")
           end
         end
```

  Only `:add`/`:delete` trigger a rebuild. Plain `:update` scene events (the
  bridge rewrites a room's scenes when its membership changes — a phase-0
  finding) must not: recall buttons key on rid, not name, so a rename that
  arrives as `:update` leaves a stale label until the next add/delete. This
  matches the plan's Task 6 note about the bridge rewriting scenes on
  membership moves. The router closes over `rebuild_scenes`, which the
  Scenes section (Step 2) binds before the Event router cell — same
  ordering rule as Task 4's `selected_light`.

  The rebuild call is wrapped in `try`/`rescue` because it runs inside the
  router's own `:temporary` `Task` — any uncaught raise there (an
  unanticipated `rtype`, a transient cache miss, anything not already
  guarded) would kill the whole router, silently ending live updates for
  every tab, not just Scenes. A rescue reports the failure through
  `Panel.report/2` instead and lets the router keep running for the next
  event. The Scenes cell's own initial `rebuild_scenes.()` call (Step 2) is
  deliberately left unwrapped — a crash there happens at evaluation time,
  in the open, and should be loud rather than swallowed. The `case` added
  to the leftover-heading branch above removes the one raise this rescue
  was guarding against by name; the rescue stays as a backstop against
  whatever else a future change might introduce, not as the plan for this
  one.

- [ ] **Step 4: Tab** — `{"Scenes", ui.scenes}` after Lights.

- [ ] **Step 5: Proofread** — one defect found and fixed, everything else confirmed clean:
  - **`scene_action/1`'s `cond` order (fixed).** The first draft checked
    `color.xy` before `color_temperature.mirek`. Checked against every light
    in `full_state.json` that carries a `color_temperature` service: `mirek`
    is non-nil exactly when `mirek_valid` is `true`, and is `nil` on every
    light where `mirek_valid` is `false` — a clean, reliable signal for
    "this bulb is currently in colour-temperature mode." `color.xy`, by
    contrast, is populated on most colour-capable bulbs regardless of which
    mode they're in — several fixture lights carry a populated `xy` at the
    same time as a valid `mirek`. Checking `xy` first meant a bulb sitting in
    warm-white CT mode got snapshotted as an XY approximation, and recalling
    that scene would drive it into colour mode instead of reproducing the CT
    state it was captured in. Fixed by swapping the `cond` branches: `mirek`
    is checked first, `xy` is the fallback for lights with no valid mirek.
  - Scene create body shape confirmed against `full_state.json`'s 34 scene
    resources: every `actions` entry is exactly
    `%{"target" => %{"rid", "rtype"}, "action" => %{...}}`, and every scene's
    `"group"` is `%{"rid", "rtype" => "room" | "zone"}` — 31 room-owned, 3
    zone-owned. `Panel.scene_action/1`'s output and `save_scene`'s `"group"`
    match this shape exactly.
  - Every fixture scene also carries `speed` (float) and `auto_dynamic`
    (bool) at the top level, alongside server-computed fields (`status`,
    `last_actions_update`, `palette`, `id_v1`, `recall: %{}`) that a create
    body plainly should not send. `full_state.json` is a captured GET
    response, which cannot show what a POST requires — presence in every
    read does not prove requirement on write. Nothing suspicious enough to
    act on preemptively; left for Task 8's hardware run to prove or
    disprove (a 4xx on create naming a missing field would be the signal).
  - `Hue.Scene.recall/3` (`lib/hue/scene.ex`): `recall(bridge, target, options \\ [])` resolves `target` by name or rid via `get/2` → `Bridge.resolve(bridge, :scene, target)`, the same rid-first lookup Task 3 and Task 4 verified — a rid target needs no adaptation. Its only option is `:duration`; `Hue.Scene.recall(HuePanel, scene["id"])` with no options is a bare default-options call, matching the plan.
  - `Hue.Scene.list/1` scene map's `"group"` key confirmed as `%{"rid" => _, "rtype" => "room" | "zone"}` directly from the fixture (see above) — matches `scene["group"]["rid"]`/`["rtype"]` usage in `by_group` and the leftover-group heading lookup.
  - `Kino.Input.text/2` (`lib/kino/input.ex`): `text(label, opts \\ [])`, so the single-argument call is valid. `Kino.Control.form/2` with `submit: "Save"` and no `report_changes` — same pattern as Lights' Apply form.
  - Controls inside frames: already proven by Task 3's `ui.rooms` (buttons and a form composed via `Kino.Layout.grid` and rendered into a frame) and reused as-is here — no restructuring needed.
  - **Listener lifecycle** (kino 0.19.0, the exact version this repo's `Mix.install` pins): `Kino.Control.new/1` (backing `button/1` and `form/2`, `lib/kino/control.ex`) calls `Kino.Bridge.reference_object(ref, self())`. `Kino.Bridge.reference_object/2`'s doc (`lib/kino/bridge.ex`) states plainly: "Any monitoring added to `object` will be dispatched once all of its associated pids terminate or the associated cells reevaluate." There is no third condition for "the control stopped being rendered." `Kino.listen/2` (`lib/kino.ex`) spawns its worker via `async/1`, which calls `Kino.start_child(%{id: Task, start: {Kino.Terminator, :start_task, [self(), fun]}, restart: :temporary})` and returns the resulting pid (`@spec listen(...) :: pid()`). Both the control's `reference_object` pid and the listener Task's parent-link are the pid that was executing when `rebuild_scenes.()` ran — the Event router's long-lived `Task` process, since the router calls `rebuild_scenes.()` directly rather than re-evaluating the Scenes cell. That process never terminates and its cell (Event router) never reevaluates between rebuilds, so neither of `reference_object`'s two cleanup conditions ever fires: a rebuild that only replaces `ui.scenes`' rendered content, without also killing the previous batch's listeners, would accumulate one live `Task` per stale scene button/form on every `:scene` add/delete for the life of the session — exactly the unbounded growth the task named as the risk. Fix: `scene_listeners` (an `Agent` started once) holds the pid `Kino.listen/2` returns for every control created in a rebuild; the next rebuild's first action is `Enum.each(Agent.get(scene_listeners, & &1), &Kino.terminate_child/1)` — `Kino.terminate_child/1` (`lib/kino.ex`, public since 0.9.1) calls `DynamicSupervisor.terminate_child(Kino.DynamicSupervisor, pid)` on exactly the pid `Kino.start_child/1` handed back, so it is the correct, documented way to stop what `Kino.listen/2` started. This kills the stale listener processes; it does not clear the dead controls' `Kino.SubscriptionManager` topic entries (those stay keyed until the creating pid dies or its cell reevaluates), but a topic entry with no listening process and no rendered client element is inert bookkeeping, not a live process — the growth that mattered (processes, each blocked in `Enum.each` on a stream) is what gets bounded.
  - Binding order: `## Scenes` sits after `## Lights` and before `## Event router`, so `ui`, `Panel`, and `client` (Connect/Helpers) are already in scope, and `save_scene`/`rebuild_scenes` (bound in Scenes) are in scope for the router's added `:scene` dispatch clause.
  - **Router hardening.** `rebuild_scenes.()` runs inside the router's `:temporary` `Task` (Step 3's `try`/`rescue`), so a raise there no longer kills the router and silently stops every tab's live updates — it reports through `Panel.report/2` and the router keeps consuming events. The leftover-group heading no longer calls `String.to_existing_atom/1` on a bridge-supplied string at all (Step 2's `case rtype do "room" -> :room; "zone" -> :zone; _ -> nil end`), which was the one raise this task could name concretely; the rescue is kept as a backstop against whatever else might surface, not as the primary defense.
  - All 9 code cells (including the three touched by this task) syntax-checked with `Code.string_to_quoted!/1` — clean.

- [ ] **Step 6: Commit** — `Control panel: scenes recalled and captured`

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
