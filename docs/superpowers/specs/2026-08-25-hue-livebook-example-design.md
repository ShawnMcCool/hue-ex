# Design: the Livebook example — a tool that teaches the library

## Goal

Give someone evaluating `hue` a runnable, interactive worked example: one
Livebook notebook that walks the full journey — discover, pair, control, watch
events — against their real bridge. The primary audience is new library users;
being a genuinely usable light-control tool is the means, not the end. Every
cell should be code a reader would copy into their own project.

Out of scope: an escript CLI (can be added later without conflicting with
this), layer-1 `Hue.Resource` usage (the moduledocs cover the escape hatch),
and any automated execution in CI.

## Shape

One notebook, `examples/hue.livemd`.

- The setup cell is `Mix.install([{:hue, "~> 0.2"}, {:kino, <latest>}])` —
  it consumes the **published package**, exactly as a user would, not the repo
  checkout. Pin Kino to whatever its current minor is at implementation time.
- `examples/` stays out of the Hex tarball; `mix.exs`'s `files` list already
  excludes it. No change to the package contents.

## Walkthrough sections

In journey order, each with prose explaining why before code showing how:

1. **Discover** — `Hue.Discovery` finds the bridge; show the resulting
   `%Hue.Bridge.Info{}`.
2. **Pair** — prose tells the reader to press the link button, then a cell
   polls `Hue.Pairing` until it succeeds. This step gets the most explanation:
   the design spec identifies discovery and pairing as the two steps most
   likely to block a new user.
3. **Start the bridge** — place `Hue.Bridge` under a supervisor via
   `Kino.start_child/1`, mirroring the child-spec-in-your-own-tree usage the
   library is designed around.
4. **Explore** — lights, rooms, zones, and scenes rendered with
   `Kino.DataTable`.
5. **Control** — plain `Hue.Light.set/3` calls by name (colour, brightness,
   `await: true`), followed by a small control panel: a light picker, on/off
   buttons, and a brightness slider wired through `Kino.Control`. The panel is
   the "tool" half of the goal.
6. **Live events** — subscribe to the bridge and append events to a
   `Kino.Frame` as the reader flips lights in the Hue app, showing the
   eventstream and the cache updating.

> **Corrected after implementation.** Two of the walkthrough details narrowed
> in the built notebook. Item 4 shows lights, rooms, and scenes but no zones
> table — many homes have none, and an empty table teaches nothing; zones
> appear in the control section's `Hue.Zone.set/3` mention instead. Item 5's
> "on/off buttons" became a checkbox inside a single submit form, which is the
> Kino idiom for a form that also carries the brightness slider.

## Re-runnability

Pairing produces the application key and the pinned bridge identity. The
notebook saves them to `examples/.hue.json` (gitignored) and on later runs
rebuilds the connection from that file, skipping discovery and pairing
entirely. This makes the notebook a reusable tool rather than a one-shot demo,
and it demonstrates the store-and-restore path every real integration needs —
the application key is a stored credential, which is exactly how a consumer
like Fae will treat it.

> **Corrected after hardware verification:** the notebooks now save
> credentials to the platform user config directory via `:filename.basedir/2`
> (`~/.config/hue_livebooks` on Linux; the walkthrough lists the per-platform
> paths), not `examples/.hue.json`. Deployed as a Livebook app, a
> notebook runs from an autosave directory that does not exist on disk, so a
> notebook-relative path both misses the pairing a normal run already saved
> and crashes `File.write!` on a missing directory. A first pass added a
> fallback read of the legacy `examples/.hue.json`; removed before merge —
> the beside-the-notebook scheme never shipped in a release, so the
> fallback only ever resurrected the author's own already-migrated file,
> silently, with no write-through, making "delete the file to start over"
> false for as long as it existed.

## Repo integration

- README gains a short "Try it" section pointing at the notebook.
- The notebook is listed as an `ex_doc` extra so the walkthrough appears on
  HexDocs with a "Run in Livebook" badge; `ex_doc` renders `.livemd` natively.
  If anything misrenders, the fallback is dropping the extra and keeping the
  README link only.
- `.gitignore` gains `examples/.hue.json`.

## Verification

Manual: run the notebook top to bottom against the real bridge, including a
second run to confirm the saved-credentials path skips pairing. As with the
layer-2 live suite, hardware that needs a physical button press is not worth
automating in CI. A published-package dependency also means the notebook can
only be fully verified after the version it references is on Hex; during
development, temporarily point `Mix.install` at the local path, and restore
the Hex dep before committing.
