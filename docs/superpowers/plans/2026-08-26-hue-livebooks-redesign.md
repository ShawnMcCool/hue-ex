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

## Setup & Connect

Credentials load from your platform's user config directory (shared with
the walkthrough — see its "Saved credentials" section for the per-platform
path); first run discovers the bridge and pairs — press the round link
button when asked.

```elixir
creds_path =
  Path.join(to_string(:filename.basedir(:user_config, "hue_livebooks")), "hue.json")

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

    File.mkdir_p!(Path.dirname(creds_path))

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

> **Corrected after hardware verification:** the per-tab `## Connect` /
> `## Helpers` / `## Rooms` / `## Lights` / `## Scenes` / `## Management` /
> `## Event router` heading structure sketched above and built through
> Task 6 was consolidated to three sections at the user's request once the
> notebook was hardware-verified — `## Setup & Connect`, `## Engine`
> (`Panel`, `ui`, and every tab's code through the event router, in the
> same cell order), `## Panel` (the composed tabs output). Cell order and
> code are unchanged; each cell group's long rationale prose became a short
> code comment at the relevant lines instead of its own section heading.

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
  close over `ui`, and so `group_frames_ref` (built here) is in scope for the
  router cell that follows.

  **Revised during Task 6's review.** The original shape below built
  `room_rows` once and bound `group_frames` as a plain cell-level variable.
  Task 6's review caught that this violates the plan's own binding
  convention stated up top — "Topology events (`:add`/`:delete` of room,
  zone, light, scene, device) rebuild the affected tab's controls" — because
  a room or zone created through Management never appeared on this tab
  without re-running the cell. Fixed to the now-standard rebuild shape: an
  `rebuild_rooms` zero-arg fn with its own terminate-first listener-pids
  `Agent` (`room_listeners`, pids registered incrementally as each control
  is created, not collected and stored in bulk at the end — a crash
  partway through a rebuild must not leak the controls already created), and
  a `group_frames_ref` `Agent` holding the current generation's frames so
  the router's `render_group_states` call always reads the fresh set rather
  than a `group_frames` binding captured before the last rebuild:

````markdown
## Rooms

One row per room, then per zone: name, live state, On/Off, brightness. The
plan's own binding convention ("topology events rebuild the affected tab's
controls") applies here too: a room or zone created through Management must
show up on this tab without re-running the cell, so the rows are rebuilt —
same terminate-first pattern as Scenes — whenever a room or zone is added or
deleted; the small state frame in each row is what live-updates otherwise.
`group_frames_ref` holds the current generation's frames so the router's
`render_group_states` call always reads the fresh set, never a binding
captured before the last rebuild.

```elixir
{:ok, room_listeners} = Kino.start_child({Agent, fn -> [] end})
{:ok, group_frames_ref} = Kino.start_child({Agent, fn -> %{} end})

set_group = fn
  :room, target, opts -> Hue.Room.set(HuePanel, target, opts)
  :zone, target, opts -> Hue.Zone.set(HuePanel, target, opts)
end

rebuild_rooms = fn ->
  Enum.each(Agent.get(room_listeners, & &1), &Kino.terminate_child/1)
  Agent.update(room_listeners, fn _ -> [] end)
  Agent.update(group_frames_ref, fn _ -> %{} end)

  register = fn pid -> Agent.update(room_listeners, &[pid | &1]) end

  {:ok, rooms} = Hue.Room.list(HuePanel)
  {:ok, zones} = Hue.Zone.list(HuePanel)

  groups =
    Enum.map(rooms, &{:room, &1}) ++ Enum.map(zones, &{:zone, &1})

  group_frames =
    Map.new(groups, fn {type, g} -> {{type, g["id"]}, Kino.Frame.new(placeholder: false)} end)

  room_rows =
    for {type, g} <- groups do
      gname = get_in(g, ["metadata", "name"])
      state_frame = group_frames[{type, g["id"]}]

      on = Kino.Control.button("On")
      off = Kino.Control.button("Off")
      bri = Kino.Control.form([brightness: Kino.Input.range("", min: 1, max: 100, default: 50)], report_changes: true)

      register.(
        Kino.listen(on, fn _ ->
          Panel.report_result(ui, "#{gname} → on", set_group.(type, g["id"], on: true))
        end)
      )

      register.(
        Kino.listen(off, fn _ ->
          Panel.report_result(ui, "#{gname} → off", set_group.(type, g["id"], on: false))
        end)
      )

      register.(
        Kino.listen(bri, fn %{data: %{brightness: b}} ->
          Panel.report_result(ui, "#{gname} → #{round(b)}%", set_group.(type, g["id"], brightness: b))
        end)
      )

      Kino.Layout.grid(
        [Kino.Markdown.new("**#{gname}**"), state_frame, on, off, bri],
        columns: 5
      )
    end

  Kino.Frame.render(ui.rooms, Kino.Layout.grid(room_rows, columns: 1))
  Agent.update(group_frames_ref, fn _ -> group_frames end)
  Panel.render_group_states(group_frames)
end

rebuild_rooms.()
```
````

- [ ] **Step 3: Wire the router.** The Rooms section now sits above "Event
  router" (Step 2), so `rebuild_rooms` and `group_frames_ref` are already in
  scope there. `rebuild_rooms.()` runs — wrapped in the same try/rescue +
  `catch :exit` reporter as every other rebuild — on `:add`/`:delete` of
  `:room`/`:zone`, *before* `render_group_states` so a brand-new room's
  frame already exists by the time its state is read; `render_group_states`
  itself now reads the current frames from `group_frames_ref` rather than
  a plain variable:

```elixir
         history = [Panel.describe(event) | history] |> then(&Panel.render_activity(ui, &1))

         if event.resource_type in [:room, :zone] and event.type in [:add, :delete] do
           try do
             rebuild_rooms.()
           rescue
             e -> Panel.report(ui, "rooms rebuild failed: #{Exception.message(e)}")
           catch
             :exit, reason -> Panel.report(ui, "rooms rebuild failed: #{inspect(reason)}")
           end
         end

         if event.resource_type in [:grouped_light, :room, :zone],
           do: Panel.render_group_states(Agent.get(group_frames_ref, & &1))

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
next. It is reset to `[]` immediately after that terminate step, and a
`register` helper appends each new pid the instant `Kino.listen` returns it
— the same shape Rooms and Management use — so a rebuild that raises
partway through still leaves what it already built registered for the
*next* rebuild's terminate-first step to clean up, rather than threading
pids back out through tuple returns and storing them in one bulk update
only if the whole rebuild finishes. A click that lands in the narrow window
while a rebuild is replacing its button can be dropped along with the
listener that would have handled it; this is accepted rather than guarded
against, since the reappearing row is itself the feedback that the click
needs to be repeated.

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
  Agent.update(scene_listeners, fn _ -> [] end)

  register = fn pid -> Agent.update(scene_listeners, &[pid | &1]) end

  {:ok, scenes} = Hue.Scene.list(HuePanel)
  {:ok, rooms} = Hue.Room.list(HuePanel)

  by_group = Enum.group_by(scenes, & &1["group"]["rid"])
  room_ids = MapSet.new(rooms, & &1["id"])

  scene_row = fn scene ->
    name = get_in(scene, ["metadata", "name"])
    button = Kino.Control.button("Recall")

    register.(
      Kino.listen(button, fn _ ->
        Panel.report_result(ui, "recall #{name}", Hue.Scene.recall(HuePanel, scene["id"]))
      end)
    )

    Kino.Layout.grid([Kino.Markdown.new(name), button], columns: 2)
  end

  group_block = fn heading, group_scenes, save_room ->
    rows = Enum.map(group_scenes, scene_row)

    save_row =
      if save_room do
        form =
          Kino.Control.form([name: Kino.Input.text("New scene from current state")], submit: "Save")

        register.(
          Kino.listen(form, fn %{data: %{name: name}} ->
            result = save_scene.(save_room, name)
            outcome = if match?({:ok, _}, result), do: :ok, else: result
            Panel.report_result(ui, "save \"#{name}\"", outcome)
          end)
        )

        [form]
      else
        []
      end

    Kino.Layout.grid([Kino.Markdown.new("**#{heading}**")] ++ rows ++ save_row, columns: 1)
  end

  room_blocks =
    for room <- rooms do
      group_block.(get_in(room, ["metadata", "name"]), Map.get(by_group, room["id"], []), room)
    end

  leftover_blocks =
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

  Kino.Frame.render(ui.scenes, Kino.Layout.grid(room_blocks ++ leftover_blocks, columns: 1))
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
           catch
             :exit, reason -> Panel.report(ui, "scenes rebuild failed: #{inspect(reason)}")
           end
         end
```

  **Revised twice after Task 5 originally landed**, both times during later
  review passes: Task 6's review added the `catch :exit` clause above,
  matching the width every other rebuild wrapper in the router now has
  (`rebuild_scenes.()` makes the same class of inter-process `Kino`/`Agent`
  calls a plain `rescue` does not catch if one of them exits). A separate,
  later review caught that `rebuild_scenes` itself was the one rebuild fn
  still on the old pid-collection shape — pids threaded back out through
  tuple returns (`{pid, block}`, `Enum.unzip/1`) and stored in one bulk
  `Agent.update` only if the whole rebuild finished, so a crash partway
  through left that generation's controls unregistered and unkillable by
  any later rebuild. Step 2's code above is the fix: `scene_listeners` is
  reset to `[]` right after the terminate step, a `register` helper appends
  each pid the instant `Kino.listen` returns it, and `scene_row`/
  `group_block` return plain blocks instead of `{pids, block}` tuples — the
  same shape `rebuild_rooms` (Task 3) and `rebuild_management` (Task 6)
  already use.

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

One nested `Kino.Layout.tabs` (Rename · Rooms & zones · Devices · Delete),
gated as the spec tiers them, consolidated into a single
`rebuild_management.()` that re-renders into one `ui.management` frame
rather than four independent rebuilds — simpler, and the tab is touched
rarely. `ui` gains two frames (`management`, `device_status`):

```elixir
ui = %{
  status: Kino.Frame.new(placeholder: false),
  rooms: Kino.Frame.new(),
  light_state: Kino.Frame.new(placeholder: false),
  scenes: Kino.Frame.new(),
  management: Kino.Frame.new(),
  device_status: Kino.Frame.new(placeholder: false),
  activity: Kino.Frame.new()
}
```

- [x] **Step 1: Add to `Panel`** (new section before `# -- activity`):

```elixir
  # -- management ------------------------------------------------------------

  # A light's own name is deprecated in CLIP v2; the authoritative name lives
  # on the device that owns it (`Hue.Bridge.Names`'s moduledoc), reached the
  # same way the blink handler in Lights reaches it — via the light's "owner".
  def light_owner_rid(rid) do
    case Hue.Bridge.fetch(@bridge, :light, rid) do
      {:ok, %{"owner" => %{"rid" => device_rid}}} -> device_rid
      _ -> nil
    end
  end

  def render_device_status(ui) do
    status =
      case Hue.Bridge.list(@bridge, :zigbee_device_discovery) do
        {:ok, [discovery]} -> discovery["status"]
        _ -> nil
      end

    Kino.Frame.render(ui.device_status, Kino.Markdown.new(status || "unknown"))
  end
```

- [x] **Step 2: Add a `## Management` section** between "Scenes" and "Event
  router". A structural choice made here, deviating from the plan's original
  "type select → dynamic resource select" sketch: Kino forms cannot
  repopulate one field's options in response to another field's live
  selection, so a type-select paired with a resource-select could never
  actually filter — it would just be inert UI. Rename and Delete instead use
  a single resource picker whose option *value* folds the type in as a
  `"type:rid"` string (rids are bridge-issued UUIDs, never containing a
  colon, so splitting on the first one is unambiguous), parsed back into a
  type/rid pair inside the listener via an explicit `case`, never
  `String.to_existing_atom/1`.

  Fixture checks done before writing this section (against
  `test/support/fixtures/full_state.json`): distinct room/zone
  `metadata.archetype` values are `bedroom`, `downstairs`, `garden`,
  `kitchen`, `living_room`, `office`, `toilet`, `tv` (`"other"` added per the
  spec, for archetypes the fixture doesn't happen to contain). Every room's
  `children` carry `rtype: "device"`; every zone's carry `rtype: "light"` —
  confirming the spec's suspicion that room and zone membership are
  differently shaped, not a single generic editor. Device resources carry
  `metadata.name`/`metadata.archetype` directly (not behind a service walk),
  confirming device rename and the delete-confirm name comparison can read
  `device["metadata"]["name"]` straight off a cached device fetch. The
  `zigbee_device_discovery` singleton's shape (`%{"action" =>
  %{"action_type_values" => ["search"]}, "status" => "ready", ...}`) matches
  phase 0's read-only probe exactly.

  A second deviation from the plan's sketch, forced by `kino` itself:
  `Kino.Input.read/1` (`lib/kino/input.ex`) raises `"input value can only be
  read in the main evaluation process"` when called from any process other
  than the cell's own evaluator — which rules out reading a plain select's
  value from inside a `Kino.Control.button`'s `Kino.listen` callback (a
  separate process) or from the router. The doc raise itself names the fix:
  "consider using `Kino.Control.form/2`, or subscribing to the input change
  using one of the functions in the `Kino.Control` module." Every
  single-action control here (Rename, create, device delete, Delete) is
  accordingly a `Kino.Control.form` whose submit event already carries every
  field's value — no read-back needed. The two membership editors (Add/Remove
  are independent actions against a shared pair of selects, which a single
  form can't express as two buttons) instead hold `%{group:, member:}` in a
  small `Agent`, kept current by a `Kino.listen` change-listener on each
  select — the same technique the Lights tab already uses for
  `selected_light`, generalised to two fields.

  Because `rebuild_management.()` recreates those two membership `Agent`s
  (and their selects) on every topology rebuild, the router needs a stable
  handle on "whichever generation is current" to refresh the members frame
  on a plain `:room`/`:zone` `:update` (a membership edit itself never
  arrives as `:add`/`:delete`, so a rebuild-only refresh would never show
  it). `membership_refs` is a second, *not*-rebuilt `Agent`, holding
  `%{room: %{state:, frame:} | nil, zone: ...}`, updated at the end of every
  `rebuild_management.()` call.

```elixir
{:ok, management_listeners} = Kino.start_child({Agent, fn -> [] end})
{:ok, membership_refs} = Kino.start_child({Agent, fn -> %{room: nil, zone: nil} end})

render_members = fn type, rid, frame ->
  content =
    case Hue.Bridge.fetch(HuePanel, type, rid) do
      {:ok, group} ->
        case group["children"] || [] do
          [] ->
            "*(no members)*"

          children ->
            children
            |> Enum.map(fn %{"rid" => crid, "rtype" => crtype} ->
              Panel.name(Hue.Resource.type(crtype), crid)
            end)
            |> Enum.map_join("\n", &"- #{&1}")
        end

      {:error, _} ->
        "*(deleted)*"
    end

  Kino.Frame.render(frame, Kino.Markdown.new(content))
end

refresh_membership = fn ->
  case Agent.get(membership_refs, & &1.room) do
    nil -> :ok
    %{state: state, frame: frame} -> render_members.(:room, Agent.get(state, & &1.group), frame)
  end

  case Agent.get(membership_refs, & &1.zone) do
    nil -> :ok
    %{state: state, frame: frame} -> render_members.(:zone, Agent.get(state, & &1.group), frame)
  end
end

rebuild_management = fn ->
  Enum.each(Agent.get(management_listeners, & &1), &Kino.terminate_child/1)
  Agent.update(management_listeners, fn _ -> [] end)
  Agent.update(membership_refs, fn _ -> %{room: nil, zone: nil} end)

  register = fn pid -> Agent.update(management_listeners, &[pid | &1]) end

  archetypes = ~w(bedroom downstairs garden kitchen living_room office toilet tv other)

  {:ok, rooms} = Hue.Room.list(HuePanel)
  {:ok, zones} = Hue.Zone.list(HuePanel)
  {:ok, scenes} = Hue.Scene.list(HuePanel)
  {:ok, lights} = Hue.Light.list(HuePanel)
  {:ok, devices} = Hue.Bridge.list(HuePanel, :device)

  device_options =
    devices
    |> Enum.map(&{&1["id"], Panel.name(:device, &1["id"])})
    |> Enum.sort_by(&elem(&1, 1))

  light_options =
    lights
    |> Enum.map(&{&1["id"], Panel.name(:light, &1["id"])})
    |> Enum.sort_by(&elem(&1, 1))

  room_options =
    rooms
    |> Enum.map(&{&1["id"], get_in(&1, ["metadata", "name"])})
    |> Enum.sort_by(&elem(&1, 1))

  zone_options =
    zones
    |> Enum.map(&{&1["id"], get_in(&1, ["metadata", "name"])})
    |> Enum.sort_by(&elem(&1, 1))

  # ---- Rename ----

  light_rename_options =
    for l <- lights, owner_rid = Panel.light_owner_rid(l["id"]), owner_rid do
      {"light:#{owner_rid}", "light: #{Panel.name(:light, l["id"])}"}
    end

  rename_options =
    Enum.uniq_by(light_rename_options, &elem(&1, 0)) ++
      Enum.map(rooms, &{"room:#{&1["id"]}", "room: #{get_in(&1, ["metadata", "name"])}"}) ++
      Enum.map(zones, &{"zone:#{&1["id"]}", "zone: #{get_in(&1, ["metadata", "name"])}"}) ++
      Enum.map(scenes, &{"scene:#{&1["id"]}", "scene: #{get_in(&1, ["metadata", "name"])}"})

  rename_block =
    if rename_options == [] do
      Kino.Markdown.new("*(nothing to rename)*")
    else
      rename_form =
        Kino.Control.form(
          [
            resource: Kino.Input.select("Resource", rename_options),
            name: Kino.Input.text("New name")
          ],
          submit: "Apply"
        )

      register.(
        Kino.listen(rename_form, fn %{data: %{resource: ref, name: new_name}} ->
          [type_str, rid] = String.split(ref, ":", parts: 2)

          type =
            case type_str do
              "light" -> :device
              "room" -> :room
              "zone" -> :zone
              "scene" -> :scene
            end

          result = Hue.Resource.update(client, type, rid, %{"metadata" => %{"name" => new_name}})
          Panel.report_result(ui, "rename to \"#{new_name}\"", result)
        end)
      )

      Kino.Layout.grid([rename_form], columns: 1)
    end

  # ---- Rooms & zones: create ----

  create_form =
    Kino.Control.form(
      [
        name: Kino.Input.text("Name"),
        archetype: Kino.Input.select("Archetype", Enum.map(archetypes, &{&1, &1})),
        kind: Kino.Input.select("Kind", [{"room", "Room"}, {"zone", "Zone"}])
      ],
      submit: "Create"
    )

  register.(
    Kino.listen(create_form, fn %{data: %{name: name, archetype: archetype, kind: kind}} ->
      type = if kind == "zone", do: :zone, else: :room
      body = %{"metadata" => %{"name" => name, "archetype" => archetype}, "children" => []}
      result = Hue.Resource.create(client, type, body)
      outcome = if match?({:ok, _}, result), do: :ok, else: result
      Panel.report_result(ui, "create #{kind} \"#{name}\"", outcome)
    end)
  )

  # ---- Rooms & zones: room membership (devices) ----

  {room_membership_block, room_ref} =
    if room_options == [] or device_options == [] do
      {Kino.Markdown.new("*(no rooms or no devices yet)*"), nil}
    else
      {:ok, room_membership_state} =
        Kino.start_child(
          {Agent,
           fn ->
             %{group: elem(hd(room_options), 0), member: elem(hd(device_options), 0)}
           end}
        )

      register.(room_membership_state)

      room_group_select = Kino.Input.select("Room", room_options)
      room_device_select = Kino.Input.select("Device", device_options)
      room_members_frame = Kino.Frame.new(placeholder: false)
      room_add_button = Kino.Control.button("Add to room")
      room_remove_button = Kino.Control.button("Remove from room")

      register.(
        Kino.listen(room_group_select, fn %{value: rid} ->
          Agent.update(room_membership_state, &Map.put(&1, :group, rid))
          render_members.(:room, rid, room_members_frame)
        end)
      )

      register.(
        Kino.listen(room_device_select, fn %{value: rid} ->
          Agent.update(room_membership_state, &Map.put(&1, :member, rid))
        end)
      )

      register.(
        Kino.listen(room_add_button, fn _ ->
          %{group: group_rid, member: member_rid} = Agent.get(room_membership_state, & &1)

          result =
            case Hue.Bridge.fetch(HuePanel, :room, group_rid) do
              {:ok, room} ->
                children = room["children"] || []

                if Enum.any?(children, &(&1["rid"] == member_rid)) do
                  :ok
                else
                  new_children = children ++ [%{"rid" => member_rid, "rtype" => "device"}]
                  Hue.Resource.update(client, :room, group_rid, %{"children" => new_children})
                end

              {:error, _} = err ->
                err
            end

          Panel.report_result(
            ui,
            "add #{Panel.name(:device, member_rid)} to #{Panel.name(:room, group_rid)}",
            result
          )
        end)
      )

      register.(
        Kino.listen(room_remove_button, fn _ ->
          %{group: group_rid, member: member_rid} = Agent.get(room_membership_state, & &1)

          result =
            case Hue.Bridge.fetch(HuePanel, :room, group_rid) do
              {:ok, room} ->
                new_children = Enum.reject(room["children"] || [], &(&1["rid"] == member_rid))
                Hue.Resource.update(client, :room, group_rid, %{"children" => new_children})

              {:error, _} = err ->
                err
            end

          Panel.report_result(
            ui,
            "remove #{Panel.name(:device, member_rid)} from #{Panel.name(:room, group_rid)}",
            result
          )
        end)
      )

      render_members.(:room, elem(hd(room_options), 0), room_members_frame)

      block =
        Kino.Layout.grid(
          [room_group_select, room_device_select, room_add_button, room_remove_button, room_members_frame],
          columns: 1
        )

      {block, %{state: room_membership_state, frame: room_members_frame}}
    end

  # ---- Rooms & zones: zone membership (lights) ----

  {zone_membership_block, zone_ref} =
    if zone_options == [] or light_options == [] do
      {Kino.Markdown.new("*(no zones or no lights yet)*"), nil}
    else
      {:ok, zone_membership_state} =
        Kino.start_child(
          {Agent,
           fn ->
             %{group: elem(hd(zone_options), 0), member: elem(hd(light_options), 0)}
           end}
        )

      register.(zone_membership_state)

      zone_group_select = Kino.Input.select("Zone", zone_options)
      zone_light_select = Kino.Input.select("Light", light_options)
      zone_members_frame = Kino.Frame.new(placeholder: false)
      zone_add_button = Kino.Control.button("Add to zone")
      zone_remove_button = Kino.Control.button("Remove from zone")

      register.(
        Kino.listen(zone_group_select, fn %{value: rid} ->
          Agent.update(zone_membership_state, &Map.put(&1, :group, rid))
          render_members.(:zone, rid, zone_members_frame)
        end)
      )

      register.(
        Kino.listen(zone_light_select, fn %{value: rid} ->
          Agent.update(zone_membership_state, &Map.put(&1, :member, rid))
        end)
      )

      register.(
        Kino.listen(zone_add_button, fn _ ->
          %{group: group_rid, member: member_rid} = Agent.get(zone_membership_state, & &1)

          result =
            case Hue.Bridge.fetch(HuePanel, :zone, group_rid) do
              {:ok, zone} ->
                children = zone["children"] || []

                if Enum.any?(children, &(&1["rid"] == member_rid)) do
                  :ok
                else
                  new_children = children ++ [%{"rid" => member_rid, "rtype" => "light"}]
                  Hue.Resource.update(client, :zone, group_rid, %{"children" => new_children})
                end

              {:error, _} = err ->
                err
            end

          Panel.report_result(
            ui,
            "add #{Panel.name(:light, member_rid)} to #{Panel.name(:zone, group_rid)}",
            result
          )
        end)
      )

      register.(
        Kino.listen(zone_remove_button, fn _ ->
          %{group: group_rid, member: member_rid} = Agent.get(zone_membership_state, & &1)

          result =
            case Hue.Bridge.fetch(HuePanel, :zone, group_rid) do
              {:ok, zone} ->
                new_children = Enum.reject(zone["children"] || [], &(&1["rid"] == member_rid))
                Hue.Resource.update(client, :zone, group_rid, %{"children" => new_children})

              {:error, _} = err ->
                err
            end

          Panel.report_result(
            ui,
            "remove #{Panel.name(:light, member_rid)} from #{Panel.name(:zone, group_rid)}",
            result
          )
        end)
      )

      render_members.(:zone, elem(hd(zone_options), 0), zone_members_frame)

      block =
        Kino.Layout.grid(
          [zone_group_select, zone_light_select, zone_add_button, zone_remove_button, zone_members_frame],
          columns: 1
        )

      {block, %{state: zone_membership_state, frame: zone_members_frame}}
    end

  rooms_zones_block =
    Kino.Layout.grid(
      [
        Kino.Markdown.new("**Create a room or zone**"),
        create_form,
        Kino.Markdown.new(
          "**Membership.** Adding a device to a room removes it from its old " <>
            "room automatically, and the old room's scenes are rewritten to " <>
            "drop the departed light."
        ),
        Kino.Markdown.new("**Rooms**"),
        room_membership_block,
        Kino.Markdown.new("**Zones**"),
        zone_membership_block
      ],
      columns: 1
    )

  # ---- Devices: search ----

  search_button = Kino.Control.button("Search for new devices")

  register.(
    Kino.listen(search_button, fn _ ->
      result =
        case Hue.Resource.list(client, :zigbee_device_discovery) do
          {:ok, [discovery]} ->
            Hue.Resource.update(client, :zigbee_device_discovery, discovery["id"], %{
              "action" => %{"action_type" => "search"}
            })

          {:ok, other} ->
            {:error, {:unexpected_zigbee_device_discovery, other}}

          {:error, _} = err ->
            err
        end

      Panel.report_result(ui, "search for new devices", result)
    end)
  )

  Panel.render_device_status(ui)

  # ---- Devices: delete ----

  device_delete_block =
    if device_options == [] do
      Kino.Markdown.new("*(no devices)*")
    else
      device_delete_form =
        Kino.Control.form(
          [
            device: Kino.Input.select("Device", device_options),
            confirm_name: Kino.Input.text("Type the device's name to confirm")
          ],
          submit: "Delete"
        )

      register.(
        Kino.listen(device_delete_form, fn %{data: %{device: rid, confirm_name: typed}} ->
          case Hue.Bridge.fetch(HuePanel, :device, rid) do
            {:ok, device} ->
              current_name = get_in(device, ["metadata", "name"])

              if typed == current_name do
                Panel.report_result(
                  ui,
                  "delete #{current_name}",
                  Hue.Resource.delete(client, :device, rid)
                )
              else
                Panel.report(ui, "delete #{current_name} — typed name did not match, refused")
              end

            {:error, _} = err ->
              Panel.report_result(ui, "delete device", err)
          end
        end)
      )

      Kino.Layout.grid([device_delete_form], columns: 1)
    end

  devices_block =
    Kino.Layout.grid(
      [
        Kino.Markdown.new(
          "**Search.** New devices announce themselves on the Activity feed " <>
            "as they join."
        ),
        search_button,
        ui.device_status,
        Kino.Markdown.new(
          "**Delete.** Unpairs the bulb. Recovery can require physically " <>
            "resetting it."
        ),
        device_delete_block
      ],
      columns: 1
    )

  # ---- Delete (scene/room/zone) ----

  delete_options =
    Enum.map(rooms, &{"room:#{&1["id"]}", "room: #{get_in(&1, ["metadata", "name"])}"}) ++
      Enum.map(zones, &{"zone:#{&1["id"]}", "zone: #{get_in(&1, ["metadata", "name"])}"}) ++
      Enum.map(scenes, &{"scene:#{&1["id"]}", "scene: #{get_in(&1, ["metadata", "name"])}"})

  delete_block =
    if delete_options == [] do
      Kino.Markdown.new("*(nothing to delete)*")
    else
      delete_form =
        Kino.Control.form(
          [
            resource: Kino.Input.select("Resource", delete_options),
            confirm: Kino.Input.checkbox("Confirm delete")
          ],
          submit: "Delete"
        )

      register.(
        Kino.listen(delete_form, fn %{data: %{resource: ref, confirm: confirmed}} ->
          [type_str, rid] = String.split(ref, ":", parts: 2)

          type =
            case type_str do
              "room" -> :room
              "zone" -> :zone
              "scene" -> :scene
            end

          name = Panel.name(type, rid)

          if confirmed do
            Panel.report_result(ui, "delete #{name}", Hue.Resource.delete(client, type, rid))
          else
            Panel.report(ui, "delete #{name} — refused, confirm not checked")
          end
        end)
      )

      Kino.Layout.grid([delete_form], columns: 1)
    end

  management_tab =
    Kino.Layout.tabs([
      {"Rename", rename_block},
      {"Rooms & zones", rooms_zones_block},
      {"Devices", devices_block},
      {"Delete", delete_block}
    ])

  Kino.Frame.render(ui.management, management_tab)

  Agent.update(membership_refs, fn _ -> %{room: room_ref, zone: zone_ref} end)
end

rebuild_management.()
```

- [x] **Step 3: Router** — after the `:scene` add/delete clause, add the
  management rebuild (try/rescue *and* `catch :exit` — this rebuild makes
  inter-process `Agent`/`Kino` calls a plain `rescue` would not catch if one
  of them exits), the membership-frame refresh, and the device-status
  refresh:

```elixir
         if event.resource_type in [:room, :zone, :scene, :device, :light] and
              event.type in [:add, :delete] do
           try do
             rebuild_management.()
           rescue
             e -> Panel.report(ui, "management rebuild failed: #{Exception.message(e)}")
           catch
             :exit, reason -> Panel.report(ui, "management rebuild failed: #{inspect(reason)}")
           end
         end

         if event.resource_type in [:room, :zone] do
           try do
             refresh_membership.()
           rescue
             e -> Panel.report(ui, "membership refresh failed: #{Exception.message(e)}")
           catch
             :exit, reason -> Panel.report(ui, "membership refresh failed: #{inspect(reason)}")
           end
         end

         if event.resource_type == :zigbee_device_discovery,
           do: Panel.render_device_status(ui)
```

  **Revised twice after the initial write, both times during review:**

  1. `refresh_membership.()` was originally called bare (unconditional on
     event type, no `try`/`rescue`). A review caught the failure mode this
     left open: if `rebuild_management.()` itself raised partway through a
     rebuild — say, mid-way through building the room membership editor —
     `membership_refs` could be left pointing at a generation whose `Agent`s
     and selects had already been torn down by the *next* successful
     rebuild's terminate-first step, and the very next `:room`/`:zone`
     event's bare `refresh_membership.()` would call `Agent.get/2` on a
     dead pid and crash the whole router with `:noproc` — silently ending
     live updates for every tab, not just Management. Two-part fix: (a)
     `rebuild_management.()` now resets `membership_refs` to `%{room: nil,
     zone: nil}` immediately after its terminate step (see Step 2's code),
     so a dangling generation can never be dereferenced — a crash before the
     end-of-rebuild update leaves the refs pointing at nothing, and
     `refresh_membership.()`'s own `nil -> :ok` clauses turn that into a
     no-op; (b) `refresh_membership.()` is now wrapped in the same
     try/rescue + `catch :exit` shape as every rebuild, belt and braces,
     since it still makes the same class of inter-process `Agent` calls.
  2. `rebuild_management.()`'s pids were originally collected in local
     variables per sub-tab and flattened into one `Agent.update` at the very
     end. A review named the partial-generation leak this left open: a
     crash anywhere before that final line meant every listener and `Agent`
     already created in that rebuild attempt was never registered anywhere,
     so the *next* successful rebuild's terminate-first step had no record
     of them to kill — permanent leak, once per crashed rebuild, for the
     rest of the session. Fixed by registering incrementally: `register =
     fn pid -> Agent.update(management_listeners, &[pid | &1]) end`, called
     immediately after every `Kino.listen`/`Kino.start_child` call (see
     Step 2's code) rather than threading pids back out through tuple
     returns. `management_listeners` is also reset to `[]` right after the
     terminate step, for the same reason as `membership_refs` above.

  The Rooms tab (Task 3) gained the identical rebuild/incremental-registration/
  reset-after-terminate shape in the same pass, once the review traced the
  underlying gap to the plan's own binding convention rather than to
  Management specifically — see Task 3's revised Steps 2–3. Dispatch order
  in the router matters here: `rebuild_rooms.()` runs before
  `render_group_states`, so a brand-new room's frame exists by the time its
  state is read from the fresh `group_frames_ref`.

- [x] **Step 4: Tab** — `{"Management", ui.management}` between Scenes and
  Activity (a frame, not a raw `management_tab` variable — the frame is what
  stays live across rebuilds):

```elixir
Kino.Layout.tabs([
  {"Rooms", ui.rooms},
  {"Lights", lights_tab},
  {"Scenes", ui.scenes},
  {"Management", ui.management},
  {"Activity", ui.activity}
])
```

- [x] **Step 5: Proofread** — confirmed clean against kino 0.19.0 and
  `lib/`, two defects found and fixed during writing (folded into the code
  above), everything else confirmed clean:
  - **`Kino.Input.read/1`'s process restriction (fixed).** First draft had
    the Add/Remove buttons read two standalone selects' current values via
    `Kino.Input.read/1` at click time. `lib/kino/input.ex`'s `read/1` raises
    on any process but the cell's own evaluator — a `Kino.listen` callback
    process fails this every time. Fixed by tracking `%{group:, member:}` in
    a per-editor `Agent`, updated by a `Kino.listen` change-listener on each
    select (the same technique `selected_light` already uses in Lights),
    read back via `Agent.get/2` (safe from any process) in the button
    handlers instead.
  - **Device enumeration read (fixed).** First draft fetched devices via
    `Hue.Resource.list(client, :device)` — a live HTTP round trip — inside
    `rebuild_management.()`, inconsistent with every other topology read in
    the same function (`Hue.Room.list`, `Hue.Zone.list`, `Hue.Scene.list`,
    `Hue.Light.list`, all cache reads) and an avoidable extra failure mode
    for a rebuild that should be as cache-driven as Scenes' is. Fixed to
    `Hue.Bridge.list(HuePanel, :device)` (`lib/hue/bridge.ex:206`,
    `Cache.list/2` — confirmed generic over any resource type, not just the
    ones with a layer-2 wrapper). The Devices sub-tab's "Search" button
    keeps the live `Hue.Resource.list(client, :zigbee_device_discovery)` call
    the plan specifies verbatim for resolving the singleton's rid at click
    time — that one is deliberately a fresh fetch, not a cache read.
  - `zigbee_device_discovery` confirmed in `Hue.Resource`'s
    `@resource_type_names` (`lib/hue/resource.ex`) — `Hue.Resource.list/3`,
    `update/5`, and `Hue.Bridge.list/2` (cache) all accept it with no
    adaptation.
  - Every `Hue.Resource` call's arity checked against `lib/hue/resource.ex`:
    `create/4` (`client, type, body, opts \\ []` — used with 3 args),
    `update/5` (`client, type, rid, body, opts \\ []` — used with 4),
    `delete/4` (`client, type, rid, opts \\ []` — used with 3), `list/3`
    (`client, type, opts \\ []` — used with 2). `update/5` and `delete/4`
    return plain `:ok | {:error, _}` in `:simple` mode (the moduledoc's
    "Writes" section) — `Panel.report_result/3` accepts that shape directly,
    no `match?({:ok, _}, ...)` normalization needed for rename, membership
    edits, or delete; `create/4` returns `{:ok, [rid_map]}` on success, same
    shape Scenes' `save_scene` already normalizes, so create does need it
    (present in the code above).
  - Confirm-gate logic reads the *current* cached name, not a stale
    rebuild-time label: the device-delete form's listener fetches
    `Hue.Bridge.fetch(HuePanel, :device, rid)` fresh at submit time and
    compares against `typed`, rather than trusting the option label the
    picker showed when it was last rebuilt. Same freshness property for
    Add/Remove: both fetch the group's current `children` from the cache at
    click time (inside the listener), never from a binding captured when
    `rebuild_management.()` last ran.
  - `Kino.Input.select/3` (`lib/kino/input.ex`): value is an arbitrary term,
    but nothing in the package (searched the extracted 0.19.0 source tree)
    shows how a select's value round-trips to and from the browser — the
    marshalling is Livebook's, not kino's, and out of reach here. Composite
    values are accordingly plain strings (`"type:rid"`), which are
    JSON-safe under any implementation, rather than tuples, which would not
    be — a deliberately conservative choice given the gap in what could be
    verified from this repo.
  - `Kino.listen/2` on a bare `Kino.Input` (not wrapped in a form or
    control): confirmed valid — `Kino.Input`'s `Enumerable` impl
    (`lib/kino/input.ex`) delegates to `Kino.Control.stream/1`, and
    `Control.stream/1`'s typespec (`lib/kino/control.ex`) explicitly
    includes `%Kino.Input{}` alongside `%Kino.Control{}`; its doc example
    shows the emitted shape for a change event —
    `%{origin: ..., type: :change, value: v}` — matching the `fn %{value:
    rid} -> ...` pattern used on both group-selects here.
  - `Kino.start_child({Agent, fun})` returning `{:ok, pid}`: already proven
    in Task 4's proofread (`selected_light`) and reused as-is for
    `management_listeners`, `membership_refs`, and the two per-editor
    membership-state `Agent`s. `Kino.terminate_child/1` (`lib/kino.ex`) is
    generic over any `Kino.DynamicSupervisor` child, not just `Kino.listen`
    results, so folding a membership-state `Agent`'s pid into the same
    tracked-and-terminated list as the listener pids (see
    `room_membership_state`/`zone_membership_state` in the `pids` lists
    above) is the correct, documented way to retire it on the next rebuild.
  - Fixture-confirmed shapes: archetypes (`bedroom`, `downstairs`, `garden`,
    `kitchen`, `living_room`, `office`, `toilet`, `tv`, plus `"other"` per
    spec); room children `rtype: "device"`; zone children `rtype: "light"`;
    device `metadata` carries `name` and `archetype` directly; scene
    `metadata` carries `name` (plus `appdata`/`image`, not sent on write, per
    Task 5's proofread of scene create).
  - Binding order: `## Management` sits after `## Scenes` and before `##
    Event router`, so `ui`, `Panel`, `client`, and the `rooms`/`zones` from
    the Rooms cell are already in scope (the latter two are shadowed by
    fresh cache reads inside `rebuild_management`'s own body, the same
    shadowing `rebuild_scenes` already does); `rebuild_management`,
    `refresh_membership`, and `render_members` are bound here and in scope
    for the router's added dispatch clauses that follow.
  - All 10 code cells (the new Management cell plus the touched `ui`,
    router, and tabs cells) syntax-checked with `Code.string_to_quoted!/1` —
    clean. `mix precommit` green (522 tests, 0 failures; credo and dialyzer
    clean) — the notebook itself isn't compiled, run anyway per the plan's
    convention.
  - Deferred to Task 8 (hardware): every write body here (`children`
    replacement, `metadata.name` rename, room/zone `create`, the discovery
    `search` action) is, like Scenes' create body, unverifiable from a
    captured GET fixture — a 4xx naming a missing/extra field would be the
    signal. Also deferred: whether a rename's `:update` event on a *device*
    correctly refreshes anything keyed by the light's resolved name
    elsewhere in the panel (Rooms/Lights already only re-render from rid,
    never cache a name, so this is expected to be fine, but only hardware
    proves it).

- [x] **Step 6: Commit** — `Control panel: management, tiered by consequence`

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

> **Corrected after hardware verification:** deploying the panel as a
> Livebook app surfaced a defect the editor-mode run never could. Livebook
> runs a deployed app from an autosave directory
> (`~/.local/share/livebook/autosaved/<date>/<id>/`), not from the
> notebook's own path — so `Path.join(__DIR__, ".hue.json")` (a) never finds
> the credentials a normal editor run saved beside the repo notebooks, so
> the app re-pairs needlessly, and (b) `File.write!` crashes with
> `File.Error … no such file or directory` on the write after pairing,
> because the autosave directory doesn't exist on disk. Screenshot-verified:
> pairing succeeded, then the write crashed. Fixed in both notebooks by
> moving the canonical credentials path to the platform user config
> directory's `hue_livebooks/hue.json` via
> `:filename.basedir(:user_config, "hue_livebooks")` (`~/.config/hue_livebooks`
> on Linux, `~/Library/Application Support/hue_livebooks` on macOS,
> `%APPDATA%\hue_livebooks` on Windows — confirmed against
> `stdlib/src/filename.erl`'s `basedir_from_os/2`; verified on this machine
> to return an Elixir binary already, so no `to_string/1` wrap was
> load-bearing but one is kept as a defensive no-op), and
> `File.mkdir_p!(Path.dirname(creds_path))` before every write to it. See
> Task 2's Connect cell (now `## Setup & Connect`) for the corrected code.
>
> A first pass also added a legacy-path fallback (reading `examples/.hue.json`
> beside the notebook when the canonical path was absent). Removed before
> merge, once quality review named it a defect in its own right: the
> beside-the-notebook scheme never shipped in a released version — this
> branch is unmerged — so the only file it could ever fall back to was the
> author's own, already migrated to the canonical path, and the fallback's
> real effect was to make "delete the canonical file to start over" false
> forever, silently resurrecting the old pairing with no write-through.
> `.gitignore`'s `/examples/.hue.json` entry stays (a stray legacy file must
> never become committable), but neither notebook reads it anymore.

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
