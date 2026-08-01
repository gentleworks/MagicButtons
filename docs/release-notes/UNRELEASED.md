# Unreleased

<!--
Notes for the NEXT release, in the user's language. Any PR with user-visible impact adds
to this file as part of that PR — that's the only place every change to the trunk is
reliably seen. `release.sh` publishes this at cut time and clears it back to the stub;
published notes live with the build, not here. Deliberately not version-named: the cut
reads the version from the build, and a version in the filename would assert a release
that hasn't happened. See docs/07 §Release notes.
-->

The visualizer shows your finger the way the mouse actually sees it. Each contact is drawn
at its real size and angle instead of as a same-sized dot, so it grows as you press and
turns as you roll — and it now scales with the window instead of staying a fixed blob.

The visualizer also shows how much room a tap has left. A dashed circle marks how far your
finger may drift and still count as a tap, and a second ring tracks where your finger is
right now, growing and shrinking as you move. Go too far and the dashed circle turns solid
red — that's the moment the tap stopped counting. It's the quickest way to see what "Max
tap travel" in Advanced actually means before you change it.

Taps now get the same amount of room to wobble in every direction. The limit used to be
measured on the mouse's own grid, which is taller than it is wide — so a tap could slide
noticeably further front-to-back than side-to-side before it stopped counting, even
though a fingertip rolls sideways just as easily. "Max tap travel" in Advanced is now set
in millimetres, and the visualizer draws it as a circle you can watch your finger move
inside. If you'd tuned that slider, your setting carries over.

MagicButtons now speaks Spanish. The menu, Settings, the visualizer, and every status and
error message follow your Mac's language, and numbers, times, and durations are formatted
the way your region writes them.

MagicButtons now works with VoiceOver. The Advanced sliders say what they are and where
they're set, the Status pane says whether Accessibility is granted, and the menu-bar icon
announces MagicButtons by name — along with what needs attention when something does. In
the visualizer, the gesture badge now names the zone a gesture fired in instead of relying
on colour alone, and its text is easier to read; contact dots have a clearer outline. If you
use Reduce Motion, the badge fades in rather than scaling up.

The visualizer now speaks, so you can set your zones up without seeing it. Rest a finger on
the mouse and it tells you which zone you're in; tap, double-tap or hold and it tells you
what registered and where — which is the part you want while you're moving the Advanced
sliders and your VoiceOver cursor is on the slider, not the picture. Brief taps don't
announce where they landed, only what they were, so trying a few in a row stays quick to
listen to, and lifting your finger says nothing at all. You'll only hear it while the
visualizer or Settings window is the one you're in front of — using your mouse anywhere
else stays silent. Landing on the picture itself reads out the current zone and how many
fingers are down.

MagicButtons has a new home at codeberg.org/gentleworks/MagicButtons. The Homepage link in
About points there, and updates now come from the new address. There's nothing to do on your
end — this version already knows where to look.
