# Unreleased

<!--
Notes for the NEXT release, in the user's language. Any PR with user-visible impact adds
to this file as part of that PR — that's the only place every change to the trunk is
reliably seen. `release.sh` publishes this at cut time and clears it back to the stub;
published notes live with the build, not here. Deliberately not version-named: the cut
reads the version from the build, and a version in the filename would assert a release
that hasn't happened. See docs/07 §Release notes.
-->

**Fixes a Magic Mouse that silently stops responding.** After a long stretch of use — typically across sleep — MagicButtons could lose its connection to the mouse's touch surface without noticing. Taps stopped working and the visualizer stopped showing your fingers, while the menu still said Active, and switching it off and on again didn't help. Only quitting and reopening did.

MagicButtons now reconnects to the mouse when your Mac wakes, and notices on its own if a real click ever arrives with no fingers detected — a combination that can't happen on a working mouse — and reconnects then too. If reconnecting genuinely doesn't help, the Status pane now says so rather than suggesting a relaunch you may have already tried.
