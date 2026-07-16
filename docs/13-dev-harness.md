# The `mb-dev` Developer Harness

This is a reference for **`mb-dev`**, the command-line tool that comes with this
repo. It's written for someone with no prior context — a newcomer, or a future
maintainer who has forgotten how any of this works. You do **not** need to have
read the other design docs first.

## What is `mb-dev`?

MagicButtons ships as a menu-bar app. `mb-dev` is a **separate command-line
program in the same repo** whose only job is to poke at the moving parts directly
from a terminal — read the Magic Mouse, post clicks, watch the gesture pipeline,
and measure behavior — **without launching the full app**. It's how the project
gets verified on real hardware and how you'd debug the mouse pipeline.

Think of it as a box of single-purpose probes. Each subcommand answers one
question ("does a synthesized click land in another app?", "is the mouse actually
sending finger data?", "how long can frames go silent while a finger rests?").

Nothing here changes your settings or installs anything. Most commands run for a
fixed number of seconds, print a summary, and exit — they can't hang.

## Running it

From the repo root:

```
swift run mb-dev <command> [args]      # builds if needed, then runs
```

or, if you've already built (`swift build`):

```
.build/debug/mb-dev <command> [args]
```

- `mb-dev --help` prints the authoritative, always-up-to-date usage (this doc is
  the friendly orientation; `--help` is the exact spec).
- Running with **no command** prints a one-line scaffold check (harmless).
- Bounded commands take an optional `[seconds]`; when a run is live, **Ctrl-C**
  stops it early.

## A 60-second glossary

Enough vocabulary to read the rest of this page. Skip if it's old news.

- **Surface / "shell"** — the entire smooth top of the Magic Mouse is
  touch-sensitive, independent of the physical click. That surface is what we read.
- **Contact** — one finger on the surface. It has a position, a size, and a stable
  id for as long as it stays down.
- **Frame** — one snapshot of all current contacts. The mouse emits frames as
  things change. **Important:** the stream is *change-driven* — a perfectly still
  finger produces almost no frames until it moves or lifts.
- **Zone** — the surface is split **left / middle / right** by horizontal position.
  A tap in a zone maps to that mouse button (middle zone → middle click, etc.).
- **Physical click** — pressing the mouse down for real (the hardware click).
- **Synthetic event** — a click MagicButtons *generates in software* (what turns a
  middle-zone tap into an actual middle-click other apps see).
- **Tap-and-a-half drag** — tap, then hold a second touch down to drag; the app
  synthesizes a held mouse button so motion registers as a drag.

## Permissions, briefly

- **Accessibility** is the one grant that matters. It lets `mb-dev` watch real
  clicks and **post** synthetic ones. Grant it to the **terminal app you run from**
  (System Settings → Privacy & Security → Accessibility), then **relaunch that
  terminal** — the permission is read at launch. Commands that only *read* the mouse
  don't need it; commands that *post* clicks do.
- **Input Monitoring** — some commands' built-in help still mentions it. In practice
  you don't need it: clean-machine testing found the Magic Mouse touch stream flows
  without it. Only if a command reports **"no frames"** should you grant Input
  Monitoring to your terminal (and relaunch) as a fallback.

## The commands

| Command | What it answers | Needs |
|---|---|---|
| `permissions` | Are the grants in place? | — |
| `verify-source [s]` | Is the mouse sending finger data as clean began/ended events? | Magic Mouse |
| `dump-frames [s]` | What do the raw hardware contact fields look like? | Magic Mouse |
| `visualize [sim]` | Show me the fingers and zones live | Magic Mouse (or `sim`) |
| `verify-two-mouse [s]` | With two mice, do their touches stay separated? | two Magic Mice |
| `verify-emit [zone] [count]` | Does a synthesized click land in another app? | Accessibility |
| `verify-tap [s]` | Are real physical clicks detected (and not duplicated)? | Accessibility |
| `verify-gesture [s]` | Does the *whole* pipeline turn a tap into a real click? | Accessibility |
| `log-gestures [s] [path]` | Capture real contacts to a CSV for threshold tuning | Magic Mouse |
| `log-conflicts [s] [tap\|hold] [path]` | When do physical clicks collide with synthetic clicks/drags? | Accessibility + Magic Mouse |
| `probe-cadence [s]` | How continuous is the frame stream while a finger is down? | Magic Mouse |

Defaults: `verify-emit` zone `middle`, count `1`; `dump-frames` and `verify-source`
run `10s`; `verify-tap`, `verify-gesture`, `verify-two-mouse`, and `probe-cadence`
run `20s`; `log-gestures` and `log-conflicts` run `30s` (`log-conflicts` drag style
defaults to `tap`).

### Check your setup

**`permissions`** — Prints whether Accessibility is granted, deep-links to the
exact System Settings pane for anything missing, and reports whether the app would
be fully operational. Exits `0` only if everything's in place. Run this first when
something isn't working.

### Watch the mouse (input side)

**`verify-source [seconds]`** — The everyday "is the mouse alive?" check. Runs the
real touch pipeline and prints a line each time a finger lands or lifts, tagged with
which mouse, the contact id, the zone, and the touch size. Tap the surface in the
left/middle/right areas and confirm the zones read correctly.
*You should see:* one `began` and one `ended` line per tap, with sensible zones.

**`dump-frames [seconds]`** — Lower-level than `verify-source`: dumps the *raw*
hardware contact fields (plus the detected surface dimensions). This is for
bring-up on a new machine or OS, to confirm the private data layout still matches.
You normally won't need it.

**`visualize [sim]`** — Opens a live window drawing finger dots over the three
zone bands, fed from the real mouse. Great for *seeing* what the recognizer sees.
`visualize sim` drives a synthetic sweep instead, so it runs with **no hardware** —
handy for checking the drawing itself. Close the window to quit.

**`verify-two-mouse [seconds]`** — Only relevant if you have **two** Magic Mice.
Confirms that touches from each mouse stay attributed to the right device, even when
both are touched at once. Prints a PASS/FAIL summary.

### Post clicks (output side)

**`verify-emit [zone] [count]`** — Posts exactly one synthesized click and exits.
It counts down a few seconds so you can click into a target app (e.g. TextEdit)
first. `zone` is `left|middle|right` (default `middle`); `count` is `1` or `2`
(default `1`, `2` = double-click).
*You should see:* a real click (or a selected word for a double-click) in whatever
app you focused. Nothing happening usually means Accessibility isn't granted.

**`verify-tap [seconds]`** — Confirms real physical clicks are *detected* by the
event tap (so the recognizer can tell a tap from a real click) and are **not
duplicated**. Click the real mouse a few times.
*You should see:* a `true → false` toggle per click, and **no** extra clicks
appearing in other apps.

### The whole thing, end to end

**`verify-gesture [seconds]`** — The headline check: runs the complete live
pipeline (read mouse → recognize gesture → post event), the same chain the shipping
app uses. Focus a target app, then tap a zone (→ one click) or double-tap a zone
(→ a double-click that selects a word). This is the on-hardware gate for the core
feature.

### Measure and tune

**`log-gestures [seconds] [path]`** — Records every real contact to a CSV
(duration, travel, size, zone, and whether it would count as a tap under the
current thresholds). It **filters and posts nothing** — pure measurement. Use it to
gather real data before adjusting zone boundaries or tap thresholds. Writes to a
timestamped file by default, or to `path` if given.

**`log-conflicts [seconds] [tap|hold] [path]`** — The measurement instrument for
**Feature B** (click/drag de-confliction, `14-post-v1.md`). It runs the *real*
shipping pipeline — same recognizer and `CGEventEmitter`, with drag promotion armed
through the same `EventInterceptor` that reports physical clicks — and writes a single
timestamped CSV interleaving **three** streams: physical clicks (`down`/`up`),
synthetic emissions (`press`/`release`/`click`), and contact-set changes. Every row
carries a `hold_active` column, so a physical event that lands during a synthetic drag
(the core collision) is a one-column filter, and the end-of-run summary counts them.
Physical rows also carry a **`swallowed`** column — whether de-confliction *consumed*
the event (docs/14) — so the fix is provable from the CSV rather than inferred: a
squeeze that begins inside a drag should read `hold_active=1, swallowed=1` for **both**
its down and its up, while a *straddle* pair (down before the hold began) should read
`swallowed=0` for both, leaking together so the real click stays balanced. The summary
splits collisions into swallowed vs passed for exactly that reason.
Unlike `log-gestures` it **posts real events** (so a genuine drag exists to collide
with) and needs **Accessibility**; unlike `verify-gesture` it wires the drag promoter
(so moves actually drag) and logs the timeline. Pick the drag style — `tap`
(tap-and-a-half, default) or `hold` (press-and-hold) — and **run both**, since the two
have different collision windows. On hardware, reproduce each case: squeeze the shell
mid-drag, race a physical press against a drag onset, race a physical click against a
same-zone tap; the ⚠︎ lines and the `collisions` count tell you what actually happened.
*Because it holds a synthetic button, the stuck-button guards apply* (`05` §Stuck-button
safeguards) — a stray physical click clears any leftover synthetic drag.

**`probe-cadence [seconds]`** — Measures how *continuous* the frame stream is while
a finger is held, especially resting motionless. This exists because a stream that
went silent under a still finger would defeat any "release the button when frames
stop" logic. Follow the on-screen prompts (hold still, drag with a pause, etc.); it
prints the worst gap and a plain-language verdict.
*Known result:* the stream is change-driven and **does** go silent for seconds under
a still finger — which is exactly why the app relies on the lift event, not silence,
to end a drag (see `05-event-output.md` §Stuck-button safeguards).

## If something goes wrong

- **Nothing happens when I touch the mouse / "no frames."** Is a Magic Mouse
  actually connected? A Bluetooth mouse may need a moment after waking. As a
  fallback, grant **Input Monitoring** to your terminal and relaunch it.
- **My synthesized clicks don't land.** Grant **Accessibility** to your terminal,
  then **relaunch the terminal** and retry — the grant is read at launch, so a
  mid-run toggle won't take effect for an already-running command.
- **The cursor got stuck / everything behaves like a drag.** The read-only probes
  here (`verify-source`, `dump-frames`, `visualize`, `probe-cadence`, `log-gestures`)
  **cannot** strand a button — they never post events. Only the paths that hold a
  synthetic button (`verify-gesture`, or the full app) can, and those are guarded
  against it (`05-event-output.md` §Stuck-button safeguards). If it ever happens,
  quit the offending process — the tap dies with it — and a single physical click
  clears any leftover synthetic drag.
- **A live command won't stop.** Ctrl-C. Timed commands also stop themselves at the
  end of their window.

## Keeping this page honest

`printUsage()` in `Sources/App/main.swift` (i.e. `mb-dev --help`) is the source of
truth for exact flags and defaults; this page is the orientation around it. **When
you add or change a subcommand, update both** — the dispatch/usage in `main.swift`
and the table + section here.
