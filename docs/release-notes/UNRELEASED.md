# Unreleased

<!--
Notes for the NEXT release, in the user's language. Any PR with user-visible impact adds
to this file as part of that PR — that's the only place every change to the trunk is
reliably seen. `release.sh` publishes this at cut time and clears it back to the stub;
published notes live with the build, not here. Deliberately not version-named: the cut
reads the version from the build, and a version in the filename would assert a release
that hasn't happened. See docs/07 §Release notes.
-->

On macOS 27, granting MagicButtons permission no longer opens System Settings underneath
Apple's permission dialog. The dialog now appears on its own, and its Open System Settings
button takes you to the right pane. MagicButtons now also calls that pane by its macOS 27
name, Device Control and Data Access. Earlier versions of macOS are unchanged.
