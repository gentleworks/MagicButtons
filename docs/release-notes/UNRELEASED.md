# Unreleased

<!--
Notes for the NEXT release, in the user's language. Any PR with user-visible impact adds
to this file as part of that PR — that's the only place every change to the trunk is
reliably seen. `release.sh` publishes this at cut time and clears it back to the stub;
published notes live with the build, not here. Deliberately not version-named: the cut
reads the version from the build, and a version in the filename would assert a release
that hasn't happened. See docs/07 §Release notes.
-->

Fixed a rare case where MagicButtons could become completely unresponsive — the menu
stopped answering and gestures did nothing — and stay that way until the app was quit.
It happened when the Magic Mouse dropped and reconnected at just the wrong moment, for
example while the Mac was waking from sleep: a call into the mouse's touch system could
block forever, and because that call held the app's main thread, everything froze with
it. Those calls now run off the main thread, so in the same situation the menu and the
rest of the app keep working while the touch stream recovers on its own.

If the touch stream can't recover by itself, MagicButtons tells you instead of staying
silent: the menu status reads "Stream stuck — Quit & Reopen", the Status pane explains
what happened, and one click on "Quit & Reopen MagicButtons" brings it back. As a
backstop for any future hang, a built-in watchdog restarts the app on its own if it ever
goes unresponsive for about half a minute, so a dead state can no longer persist.

While the mouse is reconnecting — after the Mac sleeps and wakes, or after the mouse
drops and reconnects — the Status pane briefly shows "Re-enumerating the touch
stream…" instead of sitting quiet.
