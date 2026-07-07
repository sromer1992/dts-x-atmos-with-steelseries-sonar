# DTS X / Atmos with SteelSeries Sonar

Newer SteelSeries headsets (Arctis Nova Wireless, etc.) dropped DTS Headphone:X
and Dolby Atmos support in favour of SteelSeries Sonar. This project lets you
have **both**: Windows applies DTS or Dolby Atmos to a virtual audio cable
first, then hands the processed audio to Sonar, so you keep ChatMix and your
mic settings too.

Originally posted as a fix on [r/steelseries](https://www.reddit.com/r/steelseries/comments/1pc9zci/comment/odbc02h/?context=1).

## How it works

```
Game/App audio → CABLE Input (DTS/Atmos processed here)
               → CABLE Output "Listen" bridge
               → SteelSeries Sonar - Gaming
               → Your headset
```

Windows Spatial Sound needs a 2-channel stereo endpoint, but Sonar's virtual
device is locked to 8 channels (7.1), which is why the "Spatial Sound" option
is normally greyed out when Sonar is your default device. Routing through a
virtual cable first works around that.

A background script (`FixAudio.ps1`) runs at every Windows login to make sure
the virtual cable stays your default audio device, since Sonar can reset it.

## What you need

1. A SteelSeries headset with **SteelSeries GG** installed
2. **VB-Audio Virtual Cable** (free, the setup wizard installs it for you)
3. **DTS Sound Unbound** or **Dolby Access** from the Microsoft Store
   (free trial; full version is a one-time purchase)

## Setup

1. Download or clone this repo and keep all the files together
2. Double-click `Setup.bat`
3. Approve the Windows administrator prompt
4. Work through the checklist top to bottom (green means done)
5. If a step asks you to reboot, reboot and run `Setup.bat` again

The wizard will:
- Detect what's already installed
- Download and launch the VB-Cable installer
- Open the Microsoft Store to the DTS Sound Unbound listing
- Let you pick where the script lives, then install it and create a
  scheduled task that runs it at every login
- Walk you through the one-time manual sound configuration
- Let you test that everything is actually working

## What gets installed

- `FixAudio.ps1`, copied to a folder you choose
- A Windows Scheduled Task named **FixAudio** that runs at every login,
  keeping the virtual cable set as your default audio device and
  re-asserting spatial sound
- A log at `%USERPROFILE%\FixAudio.log`

## If sound stops working

1. Open **SteelSeries GG → Sonar** and check each channel's output device
   is your headset (Sonar sometimes resets this)
2. Run `Setup.bat`, open the guide, and re-check **"Connect the cable to
   Sonar"** (the Listen tab routing)
3. Reboot, it fixes it more often than you'd expect

## Uninstall

1. Open Task Scheduler and delete the **FixAudio** task
2. Delete the folder you installed the script to
3. Uninstall VB-Cable from Windows' installed apps list
4. In Windows Sound settings, pick your headset as the output again

## Files

| File | Purpose |
|---|---|
| `Setup.bat` | Double-click entry point, requests admin rights and launches the wizard |
| `Setup.ps1` | The guided setup wizard (PowerShell + WinForms) |
| `FixAudio.ps1` | The background script that runs at login |

## License

MIT. Do whatever you want with it.
