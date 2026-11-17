# FixAudio project history

Last updated: **17 October 2026 (Australia/Sydney)**.

This file records implementation, validation, and deployment history. See
[CHANGELOG.md](CHANGELOG.md) for concise release notes and [README.md](README.md)
for usage instructions.

## Current project state

- Local package and installed runtime version: **1.2.0**.
- Tracked repository: `C:\Users\Sean\Audio Script\FixAudio Setup\`.
- The parent `C:\Users\Sean\Audio Script\` is the workspace, not the Git repository.
- Configured remote: https://github.com/sromer1992/dts-x-atmos-with-steelseries-sonar.git.
- Live login script: `C:\Users\Sean\Documents\FixAudio.ps1`.
- Installed preferences: `C:\Users\Sean\Documents\FixAudio.config.json`.
- Scheduled task: **FixAudio**, targeting the Documents copy.
- Runtime log: `C:\Users\Sean\FixAudio.log`.
- Completed repair metadata: `%LOCALAPPDATA%\FixAudio\last-run.json`.
- Dashboard entry point: `Setup.bat` in the repository/package folder.

The repository and live script were rechecked when this history was written
and are byte-for-byte identical. Their SHA256 is:

```text
D67D7CBDF3B8F9E06DCCAE41AE8D3D8D1B4F98B767FE6C6F528347457C5CCBD1
```

The installed preferences remain:

```json
{
  "SetCommunications": true,
  "SpatialApp": "DTS",
  "RepairOnUnlock": false,
  "RepairOnResume": false
}
```

These preserve the user's existing DTS and communications choices. Unlock
and resume recovery are available as opt-in settings and were not enabled
on this installation. Current audio routing was preserved during deployment.

## 17 October 2026 — version 1.2.0

### Runtime and recovery

- Fixed a remaining recovery case: when the initial default-device change
  fails but a later retry succeeds, launch the spatial app once after recovery.
- Changed readiness checks to wait for CABLE and Sonar endpoints rather than
  relying on the SteelSeries GG frontend process.
- Added optional user-specific unlock and resume task triggers. Resume uses
  Microsoft-Windows-Power-Troubleshooter event 1.
- Added a two-minute cooldown for automatic runs and a per-user mutex to
  prevent overlapping repairs. Explicit manual repair bypasses the cooldown.
- Record completed repair outcomes separately from Task Scheduler results.
- Preserve a paused task's state during updates.

### Features and UI

- Replaced the checklist wizard with a native four-page dashboard:
  **Overview**, **Audio options**, **Setup guide**, and **History & logs**.
- Added current device/default checks, task configuration checks, provider
  availability, installed/package versions, and last-run information.
- Added Repair now, pause/resume automatic repair, and saved audio/recovery options.
- Added copy/export diagnostics with user-profile paths, username, and computer
  name redacted; reports are not uploaded automatically.
- Added Windows/GG/Store shortcuts, routing instructions, and a test chime.
- Added backup version history, restore, and scoped uninstall. Uninstall removes
  only the managed script, options, and task; it retains drivers, apps, logs,
  backups, the parent folder, and current Windows routing.
- Moved long operations into background workers, added a status-worker timeout,
  preserved unsaved option edits across refreshes, and rejected elevation under
  a different Windows identity.

### Installer and release tooling

- Split setup into `Setup.ps1`, `FixAudio.Core.ps1`,
  `FixAudio.Management.ps1`, and `FixAudio.UI.ps1`.
- Keep the dashboard unelevated; request elevation for operations that need it.
- Verify the official VB-CABLE Pack45 archive against a pinned SHA256 and
  check the installer's publisher signature before execution. Downloads use
  a unique temporary directory.
- Add checksum manifests to new backups and retain the newest three restorable
  backups. Cleanup skips directories containing unexpected files or links.
- Add a Windows GitHub Actions workflow, MIT LICENSE, changelog, and a versioned
  release builder with file and ZIP checksums.
- Fix Windows PowerShell 5.1 compatibility issues found during verification:
  serialize plain log strings without filesystem-provider metadata, explicitly
  load compression assemblies, and use forward-slash ZIP entry names.

### Validation and deployment

- **36 regression cases and 3 UI/worker checks passed** under Windows PowerShell 5.1.
- Visually inspected all four dashboard pages using rendered previews.
- Registered a uniquely named, disabled validation task to verify that Windows
  accepts login, unlock, and resume triggers; removed it after inspection.
- Updated the live Documents copy and task, then verified matching script hashes
  and ran the installed runtime with `-CheckOnly`. All required endpoint/default
  checks passed, with zero required failures.
- The deployed task uses `-NoProfile -NonInteractive`, runs without elevation,
  ignores overlapping task starts, has a six-minute limit, and uses `-Automatic`.
- Deployment backup: `C:\Users\Sean\Documents\.FixAudio-backup-20261017-024818-cdadca`.
- Validation records and UI previews are in `C:\Users\Sean\Audio Script\validation\`.

The local shareable package is `dist\FixAudio-1.2.0.zip`. Its 13 packaged files
were checked against the included manifest. ZIP SHA256:

```text
4DA3F28E1C94D94936EBFBE9DD6B2BC0A8531DDB6E1561B5E3C179189F73F026
```

The ZIP predates this history-file addition and has not been rebuilt for this
documentation-only update. The CI workflow has been prepared locally; no
GitHub CI run, push, or release publication was performed as part of this work.

## 17 October 2026 — version 1.1.0

- Reviewed the original runtime, installer, scheduled-task definition, and logs.
  Confirmed the original repo/live script copies matched and that recent runs
  had successfully reclaimed playback from Sonar.
- Fixed communications-only drift being detected at the end without being
  repaired during the watch loop.
- Changed default-device setting/readback to use endpoint IDs and reject
  ambiguous endpoint-name matches.
- Made missing CABLE Output and Sonar Gaming endpoints fail final checks.
- Replaced broad success claims with explicit limits on routing and spatial
  format verification; added a read-only `-CheckOnly` mode.
- Moved AudioDeviceCmdlets installation into setup, pinned version 3.1.0.2,
  and removed dependency downloads from login execution.
- Added explicit DTS/Dolby/Auto/None preferences and documented the communications
  routing versus separate ChatMix trade-off.
- Added staged, hash-verified deployment, preserved settings, backups, and
  rollback instead of reporting installation success after unchecked errors.
- Added unattended task flags, least-privilege execution, and a six-minute limit.
- Passed the original 20 regression cases and installed read-only checks.
- Updated the live Documents copy while preserving audio routing and preferences.
- Deployment backup: `C:\Users\Sean\Documents\.FixAudio-backup-20261017-020533-eb97fa`.

## Earlier committed history

| Date (local commit time) | Commit | Change |
| --- | --- | --- |
| 9 October 2026 | `0f2e645` | Add end-of-run verification, pass/fail summary, and exit code. |
| 9 October 2026 | `7514e49` | Launch the spatial app before the watch loop. |
| 9 October 2026 | `d5bb487` | Add Dolby Access support, communications toggle, and early exit when CABLE is missing. |
| 8 July 2026 | `414401e` | Initial Sonar/VB-CABLE/spatial-sound setup wizard. |

At the time of this entry, `0f2e645` is still the latest local commit. The
1.1.0/1.2.0 changes and this history file remain uncommitted in the working tree.

## Verification boundaries and continuation notes

- Device/default checks do not prove the Listen destination, actual headset
  output, active DTS/Atmos format, or audible spatial processing. Those remain
  manual checks in the UI and log.
- Actual unlock/resume events were not fired during validation. Trigger schema
  acceptance was tested; some sleep modes may not emit the configured resume event.
- Audio-changing recovery, restore, and uninstall paths were tested with mocks
  and isolated files. Installed-machine validation used read-only checks, not
  an audible end-to-end repair run.
- No VB-CABLE driver installer was executed during this development session;
  the official archive and signatures were inspected.
- SoundVolumeView under `C:\Users\Sean\Documents\soundvolumeview-x64\` remains
  a historical troubleshooting tool; the runtime does not depend on it.
- The old `%APPDATA%\FixAudio-setup-state.txt` manual-step marker was absent
  during the initial review. The current dashboard does not rely on that marker.
- Keep future code changes in the tracked setup folder and use Install / update
  to deploy them. Verify repo/live hashes instead of hand-editing both copies.
