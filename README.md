# FixAudio: DTS / Atmos with SteelSeries Sonar

FixAudio keeps VB-CABLE selected during Sonar startup and can open DTS Sound
Unbound or Dolby Access. Its native Windows dashboard shows device checks,
audio preferences, automatic repair, backups, and recent activity.

The intended route is:

```text
Game/app > CABLE Input (Windows spatial sound)
         > CABLE Output (Listen to this device)
         > SteelSeries Sonar - Gaming > headset
Voice    > SteelSeries Sonar - Chat > headset (for separate ChatMix)
```

Originally shared on [r/steelseries](https://www.reddit.com/r/steelseries/comments/1pc9zci/comment/odbc02h/?context=1).

## Getting started

You need Windows with Windows PowerShell 5.1, SteelSeries GG/Sonar, VB-Audio
Virtual Cable, and DTS Sound Unbound or Dolby Access with the appropriate
spatial format available on CABLE Input.

1. Extract the entire release ZIP or clone the repository. Keep its files together.
2. Double-click **Setup.bat** to open the dashboard.
3. Use **Setup guide** to install missing prerequisites and configure the cable route.
4. Choose **Audio options**, then **Install / update** on Overview.
5. Use **Repair now** when you want FixAudio to apply and watch your defaults.

The dashboard runs as your user. Driver installation and operations on older
protected tasks ask Windows for administrator permission when needed. If
elevation uses a different Windows account, the worker stops before making
changes. Install the driver separately with an administrator if necessary,
then return to the dashboard as the intended audio user.

The driver action downloads VB-CABLE Pack45 into a unique temporary folder,
checks its pinned SHA256 and expected publisher signature, then opens its
installer. A changed archive is rejected; use the official
[VB-Audio website](https://vb-audio.com/Cable/) or an updated FixAudio release.
FixAudio does not install the driver during an ordinary script update.

## Dashboard features

- **Overview:** current playback, voice routing, endpoint availability, selected
  spatial app availability, task checks, and last scheduled/recorded repair result.
- **Repair now:** applies your requested defaults, opens the selected spatial app
  once after a successful repair, and watches for delayed default changes.
- **Pause / resume automatic:** disables or enables the task. A current repair
  finishes normally. Manual repair remains available while automatic runs are paused.
- **Audio options:** choose DTS/Dolby/Auto/None, communications routing, and
  optional repair after unlock or resume. Unsaved edits survive status refreshes.
- **Setup guide:** routing instructions and shortcuts to Windows, GG, Store,
  the driver installer, and a test chime.
- **History & logs:** backup versions, restore, recent log, a full-log shortcut,
  diagnostic export, and scoped uninstall.
- **Copy / export report:** includes checks, preferences, results, and recent
  log entries. User-profile paths, username, and computer name are redacted.
  Nothing is uploaded or sent automatically; review the report before sharing it.

Downloads, setup, status inspection, and repairs run in separate workers so
the window stays responsive. The dashboard is optional; the login task works
when it is closed. There is no permanently running FixAudio service or tray app.

## Audio and recovery options

Installed preferences live beside the installed script in `FixAudio.config.json`:

```json
{
  "SetCommunications": false,
  "SpatialApp": "Auto",
  "RepairOnUnlock": false,
  "RepairOnResume": false
}
```

`SetCommunications: false` leaves communications routing alone. For separate
Game/Chat balancing, select **SteelSeries Sonar - Chat** in your voice app.
If true, FixAudio also sets and monitors CABLE as the communications default;
voice apps using that default join game audio in Sonar Gaming, preventing
separate ChatMix balancing for those apps.

`SpatialApp` accepts **DTS**, **Dolby**, **Auto**, or **None**. Auto opens an app
only when exactly one provider is installed; choose explicitly when both are
installed. None skips app launching. Opening the app does not select or prove
the Windows spatial format. FixAudio leaves an already-running app alone and
never force-kills a spatial app.

Unlock and resume recovery are off by default. If enabled, the task reclaims
your configured defaults after that event. Resume listens for Windows'
Power-Troubleshooter event 1; some systems/sleep modes may not emit this event.
Use Pause when choosing another output intentionally. Automatic runs have a
two-minute cooldown; manual repair bypasses it. A per-user mutex prevents
overlapping repairs, including directly launched copies.

## Installation and updates

Setup installs/validates **AudioDeviceCmdlets 3.1.0.2** for your user. Login
never downloads dependencies. A missing module is reported as a failure;
run Install / update to repair it.

Updates discover the existing task's script path, preserve saved options and
paused state, stage the files, and verify the installed hash and task settings.
They restore previous files and the task if deployment fails. Legacy inline
communications and app preferences are migrated. New recovery options remain
off during migration. Setup, updates, restore, and uninstall do not change
your current Windows audio routing.

The task is named **FixAudio**, runs as your interactive user without elevation,
ignores overlapping task starts, and has a six-minute execution limit.

Headless update:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Setup.ps1 -UpdateInstalled
```

Run as the task owner, with administrator rights if required by an older task.
Wait for any active repair to finish before maintenance.

## Verification and troubleshooting

FixAudio waits for audio endpoints rather than the GG frontend process. It
checks requested defaults by endpoint ID and requires CABLE Output and Sonar
Gaming to be present and enabled. Exit 0 means these checks passed; exit 1 means
a required check or operation failed.

**Listen destination, headset output, spatial format, and audible end-to-end
processing remain manual checks.** A chime proves audible playback, not the
intended routing or spatial processing. These limits are explicit in the UI/log.

Inspect installed defaults/endpoints without setting audio, waiting for startup,
or opening a spatial app:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\path\to\FixAudio.ps1" -CheckOnly
```

If audio is missing, check CABLE Output's Listen destination, Sonar's headset
output, and the Windows spatial format. Turn off Sonar Spatial Audio when
Windows already applies spatial processing. The dashboard's report can help
identify missing devices or incorrect task/configuration state.

Logs: `%USERPROFILE%\FixAudio.log`. Completed repair metadata:
`%LOCALAPPDATA%\FixAudio\last-run.json`. Each run records its version, SHA256,
and preferences. CheckOnly does not overwrite the last repair outcome.

## Restore and uninstall

Each deployment backs up existing files and the task into a dated
`.FixAudio-backup-*` folder beside the installed script. New backups include
checksums. The newest three restorable backups are retained; unexpected files
or links prevent automatic deletion of that backup directory.

Select a backup in **History & logs > Restore selected** to restore its script,
options, and task. The current installation is backed up first. Legacy backups
without checksum manifests receive syntax/task checks and are labeled Legacy.

**Uninstall FixAudio** removes only its scheduled task, installed script, and
installed JSON options. It retains drivers, spatial apps, logs, backups, and
current Windows audio routing. It never deletes the installation's parent
folder. To restore after uninstalling, reinstall to the same folder first,
then select the saved backup.

## Development and releases

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Regression.Tests.ps1
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\tests\UI.Worker.Tests.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Build-Release.ps1
```

Tests simulate audio/task operations and use isolated temporary files. The
builder produces `dist/FixAudio-<version>.zip`, a ZIP checksum, and an included
file-hash manifest. The Windows GitHub Actions workflow runs the tests and
uploads the package as an artifact. It does not publish a GitHub release.

`Setup.ps1` is the entry point; `FixAudio.Core.ps1` and
`FixAudio.Management.ps1` contain installation/control operations;
`FixAudio.UI.ps1` builds the dashboard. Only the standalone runtime
`FixAudio.ps1` and its JSON options are installed into the chosen folder.

## License

[MIT](LICENSE).
