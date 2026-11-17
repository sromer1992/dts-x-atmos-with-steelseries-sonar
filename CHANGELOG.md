# Changelog

## 1.2.1 - 2026-11-17

- Close the spatial app's window after launching it. DTS Sound Unbound and Dolby Access are UWP apps whose
  window belongs to ApplicationFrameHost, so FixAudio now waits up to 20 seconds for an `ApplicationFrameWindow`
  with the exact app title and sends it a normal close request. It never force-closes the app.
- Check that the scheduled task can be replaced before an update, options save, restore, or uninstall changes
  any file or backup. Without administrator rights these now stop with nothing changed, and the dashboard
  retries elevated. Previously this failed after a rollback, with a misleading warning and an extra backup.

## 1.2.0 - 2026-10-17

- Add a native dashboard with Overview, Audio options, Setup guide, and History/logs.
- Add manual repair, pause/resume, redacted diagnostic reports, backup restore, and scoped uninstall.
- Add opt-in unlock and resume recovery, a two-minute automatic cooldown, and a per-user repair mutex.
- Wait for audio endpoints and launch the spatial app after a successful delayed recovery.
- Run long operations in background workers; elevate only when needed and reject a changed Windows identity.
- Verify the VB-CABLE archive checksum and installer publisher before execution.
- Keep three backups, with checksums on new backups; preserve paused task state during updates.
- Add Windows CI and a versioned ZIP builder with file and archive checksums.

## 1.1.0 - 2026-10-17

- Monitor both requested defaults and verify endpoint IDs.
- Require the bridge and Sonar endpoints while disclosing unverified routing/spatial settings.
- Move dependency installation into setup and preserve user options during verified updates.
- Add staged deployment, rollback, least-privilege task execution, and regression checks.
