# Unreleased

<!--
Notes for the NEXT release, in the user's language. Any PR with user-visible impact adds
to this file as part of that PR — that's the only place every change to the trunk is
reliably seen. `release.sh` publishes this at cut time and clears it back to the stub;
published notes live with the build, not here. Deliberately not version-named: the cut
reads the version from the build, and a version in the filename would assert a release
that hasn't happened. See docs/07 §Release notes.
-->

MagicButtons now speaks Spanish. The menu, Settings, the visualizer, and every status and
error message follow your Mac's language, and numbers, times, and durations are formatted
the way your region writes them.

MagicButtons now works with VoiceOver. The Advanced sliders say what they are and where
they're set, the Status pane says whether Accessibility is granted, and the menu-bar icon
announces MagicButtons by name — along with what needs attention when something does. In
the visualizer, the gesture badge now names the zone a gesture fired in instead of relying
on colour alone, and its text is easier to read; contact dots have a clearer outline. If you
use Reduce Motion, the badge fades in rather than scaling up.
