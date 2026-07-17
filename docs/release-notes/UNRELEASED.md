# Unreleased

<!--
Notes for the NEXT release, in the user's language. Any PR with user-visible impact adds
to this file as part of that PR — that's the only place every change to the trunk is
reliably seen. `release.sh` publishes this at cut time and clears it back to the stub;
published notes live with the build, not here. Deliberately not version-named: the cut
reads the version from the build, and a version in the filename would assert a release
that hasn't happened. See docs/07 §Release notes.
-->

## Improved interaction between mouse clicks and tap actions

Physical clicks and tap-driven actions no longer get in each other's way:

- **Clicking the mouse during a tap-started drag no longer interrupts it.** Pressing the
  shell mid-drag could previously drop what you were dragging, or start a competing
  selection.
- **Fixed a duplicate drag in Press-and-hold mode.** A finger resting on the shell could
  start a drag on top of a click you made yourself.
- Physical double- and triple-clicks keep working normally alongside tap-to-click.

### If you use Press-and-hold

Press-and-hold treats a resting finger as the start of a drag, so it needs the top of the
mouse kept clear: grip it from the sides, and touch the shell only when you mean to tap or
drag.

While a resting finger has started a drag, **clicking the
mouse won't register until you lift that finger** — so resting a finger and *then*
double-clicking won't select a word. Starting the double-click with the shell clear works
normally.

If you'd rather rest your fingers on the mouse, use **Tap-and-a-half**
(Settings → Advanced → Drag style), which ignores resting fingers by design.

## New: record a troubleshooting log

If MagicButtons misbehaves — a drag that drops, a tap that does nothing — you can now
record what happened and attach it to a bug report.

Turn on **Record a troubleshooting log** in Settings → Status, reproduce the problem, then
turn it off and click **Reveal in Finder…** to find the log.

It records only which zone of the mouse your finger touched, which gestures were
recognized, and when. It never records text, cursor positions, or key presses — so it's
safe to attach to a public bug report. Recording is always off when MagicButtons starts,
and stops on its own after 30 minutes.

Reports can be filed as Issues on the Codeberg project at [https://codeberg.org/anguiano/MagicButtons/issues/new](https://codeberg.org/anguiano/MagicButtons/issues/new).  Keep in mind this is a free volunteer
project and response times may be long and inconsistent.
