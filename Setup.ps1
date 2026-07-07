# ============================================================================
# FixAudio Setup Wizard
# ============================================================================
# Guided installer for the Sonar + VB-CABLE + DTS/Dolby spatial sound setup.
# Run via Setup.bat (needs administrator rights for driver + scheduled task).
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SetupDir          = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceScript      = Join-Path $SetupDir "FixAudio.ps1"
$DefaultInstallDir = Join-Path $env:USERPROFILE "FixAudio"
$TaskName          = "FixAudio"

$script:InstallDir = $DefaultInstallDir
$StateFile         = Join-Path $env:APPDATA "FixAudio-setup-state.txt"

# ----------------------------------------------------------------------------
# DETECTION
# ----------------------------------------------------------------------------
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-GG {
    if (Get-Process -Name "SteelSeriesGG" -ErrorAction SilentlyContinue) { return $true }
    if (Test-Path "$env:ProgramFiles\SteelSeries\GG") { return $true }
    if (Test-Path "${env:ProgramFiles(x86)}\SteelSeries\GG") { return $true }
    return $false
}

function Test-VBCable {
    $dev = Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match "VB-Audio" }
    if ($dev) { return $true }
    return $false
}

function Get-SpatialApp {
    if (Get-AppxPackage -Name "*DTSSoundUnbound*" -ErrorAction SilentlyContinue) { return "DTS Sound Unbound" }
    if (Get-AppxPackage -Name "*DolbyAccess*" -ErrorAction SilentlyContinue)     { return "Dolby Access" }
    return $null
}

function Test-ManualDone {
    Test-Path $StateFile
}

function Get-InstalledTask {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $arg = ($task.Actions | Select-Object -First 1).Arguments
    if ($arg -match '-File\s+"([^"]+)"') {
        $path = $Matches[1]
        if (Test-Path $path) { return $path }
    }
    return "?"
}

# ----------------------------------------------------------------------------
# ACTIONS
# ----------------------------------------------------------------------------
function Install-VBCable {
    $urls = @(
        "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip",
        "https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip"
    )
    $zip = Join-Path $env:TEMP "VBCable.zip"
    $dir = Join-Path $env:TEMP "VBCable"
    $ok  = $false

    foreach ($url in $urls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
            $ok = $true
            break
        } catch { }
    }

    if (-not $ok) {
        [System.Windows.Forms.MessageBox]::Show(
            "Automatic download failed. Your browser will open the official VB-Audio page.`n`nDownload the CABLE driver pack, extract it, right-click VBCABLE_Setup_x64.exe and choose 'Run as administrator', click 'Install Driver', then REBOOT.",
            "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
        Start-Process "https://vb-audio.com/Cable/"
        return
    }

    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    $exe = Get-ChildItem $dir -Filter "VBCABLE_Setup_x64.exe" -Recurse | Select-Object -First 1
    if (-not $exe) {
        [System.Windows.Forms.MessageBox]::Show("Downloaded but couldn't find the installer inside the zip. Opening the folder so you can run it yourself.", "DTS X / Atmos with Sonar", "OK", "Warning") | Out-Null
        Start-Process $dir
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        "The VB-CABLE installer will now open.`n`n1. Click 'Install Driver'`n2. When it finishes, REBOOT your PC`n3. After the reboot, run Setup.bat again to continue",
        "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
    Start-Process $exe.FullName -Verb RunAs -Wait
    [System.Windows.Forms.MessageBox]::Show("If the driver installed, reboot now and then run Setup.bat again.", "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
}

function Install-Script {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Choose where the FixAudio script should live (a folder that won't get deleted)"
    $dlg.SelectedPath = $script:InstallDir
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $script:InstallDir = $dlg.SelectedPath

    if (-not (Test-Path $script:InstallDir)) {
        New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    }
    $dest = Join-Path $script:InstallDir "FixAudio.ps1"
    Copy-Item $SourceScript $dest -Force

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                 -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest -LogonType Interactive
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $TaskName `
        -Description "Sets CABLE Input as default audio device and re-asserts spatial sound on login" `
        -Trigger $trigger -Action $action -Principal $principal -Settings $settings -Force | Out-Null

    [System.Windows.Forms.MessageBox]::Show(
        "Installed!`n`nScript: $dest`nScheduled task: '$TaskName' (runs at every login)",
        "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
}

function Show-ConfigGuide {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "One-time sound configuration"
    $f.Size = New-Object System.Drawing.Size(660, 560)
    $f.StartPosition = "CenterParent"
    $f.FormBorderStyle = "FixedDialog"
    $f.MaximizeBox = $false

    $txt = New-Object System.Windows.Forms.RichTextBox
    $txt.ReadOnly = $true
    $txt.BackColor = [System.Drawing.Color]::White
    $txt.BorderStyle = "FixedSingle"
    $txt.ScrollBars = "Vertical"
    $txt.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $txt.Location = New-Object System.Drawing.Point(12, 12)
    $txt.Size = New-Object System.Drawing.Size(620, 420)

    $normal = New-Object System.Drawing.Font("Segoe UI", 10)
    $bold   = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)

    function Add-GuideText([string]$Text, [bool]$IsHeader) {
        if ($IsHeader) { $txt.SelectionFont = $bold; $txt.SelectionColor = [System.Drawing.Color]::DarkSlateBlue }
        else           { $txt.SelectionFont = $normal; $txt.SelectionColor = [System.Drawing.Color]::Black }
        $txt.AppendText($Text + "`r`n")
    }

    Add-GuideText "Do these once. Use the buttons below to open the right windows." $false
    Add-GuideText "" $false
    Add-GuideText "Turn on DTS / Atmos" $true
    Add-GuideText "   1.  Click [Open Sound settings]" $false
    Add-GuideText "   2.  Under Output, select 'CABLE Input (VB-Audio Virtual Cable)'" $false
    Add-GuideText "   3.  Click the arrow next to CABLE Input to open its properties" $false
    Add-GuideText "   4.  Under 'Spatial sound', choose 'DTS Headphone:X'" $false
    Add-GuideText "        (or 'Dolby Atmos for Headphones' if you use Dolby)" $false
    Add-GuideText "   5.  Optional: set Format to the highest quality your PC allows" $false
    Add-GuideText "" $false
    Add-GuideText "Connect the cable to Sonar" $true
    Add-GuideText "   1.  Click [Open Recording devices]" $false
    Add-GuideText "   2.  Right-click 'CABLE Output' and choose Properties" $false
    Add-GuideText "   3.  Open the 'Listen' tab" $false
    Add-GuideText "   4.  Tick 'Listen to this device'" $false
    Add-GuideText "   5.  Under 'Playback through this device', pick 'SteelSeries Sonar - Gaming'" $false
    Add-GuideText "   6.  Click Apply, then OK" $false
    Add-GuideText "" $false
    Add-GuideText "Stop Sonar double-processing the sound" $true
    Add-GuideText "   1.  Click [Open SteelSeries GG] and go to the Sonar tab" $false
    Add-GuideText "   2.  On the GAME channel: turn Spatial Audio OFF" $false
    Add-GuideText "        (important -- otherwise 3D sound gets applied twice)" $false
    Add-GuideText "   3.  Set the Equalizer to Flat (or off)" $false
    Add-GuideText "   4.  Make sure each channel's output device is your headset" $false
    Add-GuideText "   5.  In Sonar settings, turn OFF 'Sync' so Sonar stops changing" $false
    Add-GuideText "        your Windows default device" $false
    Add-GuideText "" $false
    Add-GuideText "Check it works" $true
    Add-GuideText "   1.  Click 'Test my sound' on the main setup window" $false
    Add-GuideText "   2.  You should hear a chime through your headset" $false
    Add-GuideText "   3.  If you hear nothing, re-check 'Connect the cable to Sonar' above" $false
    Add-GuideText "" $false
    Add-GuideText "That's it. The FixAudio script re-applies the Windows default device automatically every time you log in." $false

    $txt.SelectionStart = 0
    $txt.ScrollToCaret()

    $btnSound = New-Object System.Windows.Forms.Button
    $btnSound.Text = "Open Sound settings"
    $btnSound.Location = New-Object System.Drawing.Point(12, 445)
    $btnSound.Size = New-Object System.Drawing.Size(150, 32)
    $btnSound.Add_Click({ Start-Process "ms-settings:sound" })

    $btnRec = New-Object System.Windows.Forms.Button
    $btnRec.Text = "Open Recording devices"
    $btnRec.Location = New-Object System.Drawing.Point(172, 445)
    $btnRec.Size = New-Object System.Drawing.Size(170, 32)
    $btnRec.Add_Click({ Start-Process "control.exe" -ArgumentList "mmsys.cpl,,1" })

    $btnGG = New-Object System.Windows.Forms.Button
    $btnGG.Text = "Open SteelSeries GG"
    $btnGG.Location = New-Object System.Drawing.Point(352, 445)
    $btnGG.Size = New-Object System.Drawing.Size(150, 32)
    $btnGG.Add_Click({
        $gg = "$env:ProgramFiles\SteelSeries\GG\SteelSeriesGG.exe"
        if (-not (Test-Path $gg)) { $gg = "${env:ProgramFiles(x86)}\SteelSeries\GG\SteelSeriesGG.exe" }
        if (Test-Path $gg) { Start-Process $gg }
        else {
            [System.Windows.Forms.MessageBox]::Show("Couldn't find SteelSeries GG -- open it from your Start menu.", "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
        }
    })

    $btnDone = New-Object System.Windows.Forms.Button
    $btnDone.Text = "Mark as done"
    $btnDone.Location = New-Object System.Drawing.Point(512, 445)
    $btnDone.Size = New-Object System.Drawing.Size(120, 32)
    $btnDone.Add_Click({
        "manual-config-done $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Set-Content $StateFile -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show("Marked as done. Use 'Test my sound' on the main window to make sure everything works!", "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
        $f.Close()
    })

    $f.Controls.AddRange(@($txt, $btnSound, $btnRec, $btnGG, $btnDone))
    $f.ShowDialog() | Out-Null
}

# ----------------------------------------------------------------------------
# MAIN WINDOW
# ----------------------------------------------------------------------------
if (-not (Test-Admin)) {
    [System.Windows.Forms.MessageBox]::Show("Please run Setup.bat instead -- this wizard needs administrator rights.", "DTS X / Atmos with Sonar", "OK", "Warning") | Out-Null
    exit 1
}
if (-not (Test-Path $SourceScript)) {
    [System.Windows.Forms.MessageBox]::Show("FixAudio.ps1 is missing from the setup folder. Keep Setup.bat, Setup.ps1 and FixAudio.ps1 together.", "DTS X / Atmos with Sonar", "OK", "Error") | Out-Null
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "DTS X / Atmos with Sonar -- Setup"
$form.Size = New-Object System.Drawing.Size(760, 560)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$header = New-Object System.Windows.Forms.Label
$header.Text = "DTS X / Atmos with Sonar -- setup checklist"
$header.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(16, 14)
$header.Size = New-Object System.Drawing.Size(720, 28)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = "Work top to bottom. Green = done. If a step needs a reboot, run Setup.bat again afterwards."
$sub.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$sub.ForeColor = [System.Drawing.Color]::DimGray
$sub.Location = New-Object System.Drawing.Point(16, 44)
$sub.Size = New-Object System.Drawing.Size(720, 20)

$form.Controls.AddRange(@($header, $sub))
$script:SubLabel = $sub

$script:StatusLabels = @{}

function Add-Row {
    param([int]$Index, [string]$Key, [string]$Title, [string]$Desc, [string]$ButtonText, [scriptblock]$OnClick)

    $y = 78 + ($Index * 68)

    $t = New-Object System.Windows.Forms.Label
    $t.Text = "$($Index + 1). $Title"
    $t.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $t.Location = New-Object System.Drawing.Point(16, $y)
    $t.Size = New-Object System.Drawing.Size(430, 22)

    $d = New-Object System.Windows.Forms.Label
    $d.Text = $Desc
    $d.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
    $d.ForeColor = [System.Drawing.Color]::DimGray
    $d.Location = New-Object System.Drawing.Point(32, ($y + 22))
    $d.Size = New-Object System.Drawing.Size(414, 34)

    $s = New-Object System.Windows.Forms.Label
    $s.Text = "..."
    $s.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $s.Location = New-Object System.Drawing.Point(452, ($y + 4))
    $s.Size = New-Object System.Drawing.Size(130, 40)
    $script:StatusLabels[$Key] = $s

    $b = New-Object System.Windows.Forms.Button
    $b.Text = $ButtonText
    $b.Location = New-Object System.Drawing.Point(590, $y)
    $b.Size = New-Object System.Drawing.Size(148, 34)
    $b.Add_Click($OnClick)

    $form.Controls.AddRange(@($t, $d, $s, $b))
}

function Refresh-Status {
    if (Test-GG) {
        $script:StatusLabels["gg"].Text = "Installed"
        $script:StatusLabels["gg"].ForeColor = [System.Drawing.Color]::Green
    } else {
        $script:StatusLabels["gg"].Text = "Not found"
        $script:StatusLabels["gg"].ForeColor = [System.Drawing.Color]::Firebrick
    }

    if (Test-VBCable) {
        $script:StatusLabels["vb"].Text = "Installed"
        $script:StatusLabels["vb"].ForeColor = [System.Drawing.Color]::Green
    } else {
        $script:StatusLabels["vb"].Text = "Not found"
        $script:StatusLabels["vb"].ForeColor = [System.Drawing.Color]::Firebrick
    }

    $spatial = Get-SpatialApp
    if ($spatial) {
        $script:StatusLabels["dts"].Text = $spatial
        $script:StatusLabels["dts"].ForeColor = [System.Drawing.Color]::Green
    } else {
        $script:StatusLabels["dts"].Text = "Not found"
        $script:StatusLabels["dts"].ForeColor = [System.Drawing.Color]::Firebrick
    }

    $taskPath = Get-InstalledTask
    if ($taskPath -and $taskPath -ne "?") {
        $script:StatusLabels["task"].Text = "Installed"
        $script:StatusLabels["task"].ForeColor = [System.Drawing.Color]::Green
    } elseif ($taskPath -eq "?") {
        $script:StatusLabels["task"].Text = "Task exists, script missing"
        $script:StatusLabels["task"].ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $script:StatusLabels["task"].Text = "Not installed"
        $script:StatusLabels["task"].ForeColor = [System.Drawing.Color]::Firebrick
    }

    if (Test-ManualDone) {
        $script:StatusLabels["cfg"].Text = "Done"
        $script:StatusLabels["cfg"].ForeColor = [System.Drawing.Color]::Green
    } else {
        $script:StatusLabels["cfg"].Text = "Not done yet"
        $script:StatusLabels["cfg"].ForeColor = [System.Drawing.Color]::DarkOrange
    }

    # All-done banner
    $taskOk = ($taskPath -and $taskPath -ne "?")
    if ((Test-GG) -and (Test-VBCable) -and (Get-SpatialApp) -and $taskOk -and (Test-ManualDone)) {
        $script:SubLabel.Text = "Setup complete -- you're good to go! Use 'Test my sound' below to double-check."
        $script:SubLabel.ForeColor = [System.Drawing.Color]::Green
        $script:SubLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    } else {
        $script:SubLabel.Text = "Work top to bottom. Green = done. If a step needs a reboot, run Setup.bat again afterwards."
        $script:SubLabel.ForeColor = [System.Drawing.Color]::DimGray
        $script:SubLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    }
}

Add-Row 0 "gg" "SteelSeries GG (with Sonar)" `
    "The SteelSeries app for your headset. You probably already have it." `
    "Get SteelSeries GG" { Start-Process "https://steelseries.com/gg" }

Add-Row 1 "vb" "VB-Audio Virtual Cable" `
    "A free virtual audio cable. Windows applies DTS/Dolby here first, then hands audio to Sonar. Needs a reboot after installing." `
    "Download && install" { Install-VBCable; Refresh-Status }

Add-Row 2 "dts" "DTS Sound Unbound (or Dolby Access)" `
    "The spatial sound app from the Microsoft Store. Has a free trial; the full version is a one-time purchase." `
    "Open Microsoft Store" { Start-Process "ms-windows-store://search/?query=DTS Sound Unbound"; }

Add-Row 3 "task" "Install the FixAudio script" `
    "Copies the script to a folder you choose and makes it run automatically at every login (keeps your audio devices set correctly)." `
    "Choose folder && install" { Install-Script; Refresh-Status }

Add-Row 4 "cfg" "One-time sound configuration" `
    "A short guided walkthrough: pick the right output, enable DTS, and connect the cable to Sonar." `
    "Open the guide" { Show-ConfigGuide; Refresh-Status }

# Bottom bar
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Re-check everything"
$btnRefresh.Location = New-Object System.Drawing.Point(16, 462)
$btnRefresh.Size = New-Object System.Drawing.Size(150, 34)
$btnRefresh.Add_Click({ Refresh-Status })

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = "Run FixAudio now"
$btnRun.Location = New-Object System.Drawing.Point(176, 462)
$btnRun.Size = New-Object System.Drawing.Size(140, 34)
$btnRun.Add_Click({
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $TaskName
        [System.Windows.Forms.MessageBox]::Show("FixAudio is running in the background. It takes about 2-3 minutes, then writes its log.", "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show("Install the script first (step 4).", "DTS X / Atmos with Sonar", "OK", "Warning") | Out-Null
    }
})

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text = "View log"
$btnLog.Location = New-Object System.Drawing.Point(326, 462)
$btnLog.Size = New-Object System.Drawing.Size(100, 34)
$btnLog.Add_Click({
    $log = Join-Path $env:USERPROFILE "FixAudio.log"
    if (Test-Path $log) { Start-Process notepad.exe -ArgumentList "`"$log`"" }
    else {
        [System.Windows.Forms.MessageBox]::Show("No log yet -- the script hasn't run.", "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
    }
})

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = "Test my sound"
$btnTest.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnTest.Location = New-Object System.Drawing.Point(436, 462)
$btnTest.Size = New-Object System.Drawing.Size(130, 34)
$btnTest.Add_Click({
    $wav = "C:\Windows\Media\tada.wav"
    if (-not (Test-Path $wav)) { $wav = "C:\Windows\Media\Windows Notify.wav" }
    try {
        $player = New-Object System.Media.SoundPlayer $wav
        $player.PlaySync()
        $heard = [System.Windows.Forms.MessageBox]::Show(
            "Did you hear a chime through your HEADSET?",
            "DTS X / Atmos with Sonar", "YesNo", "Question")
        if ($heard -eq [System.Windows.Forms.DialogResult]::Yes) {
            [System.Windows.Forms.MessageBox]::Show("Your audio chain is working. Enjoy!", "DTS X / Atmos with Sonar", "OK", "Information") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "No sound usually means the cable isn't connected to Sonar.`n`nOpen the guide (step 5) and re-check the 'Connect the cable to Sonar' section. Also check in SteelSeries GG that each Sonar channel's output device is your headset.",
                "DTS X / Atmos with Sonar", "OK", "Warning") | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Couldn't play the test sound: $_", "DTS X / Atmos with Sonar", "OK", "Warning") | Out-Null
    }
})

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.Location = New-Object System.Drawing.Point(638, 462)
$btnClose.Size = New-Object System.Drawing.Size(100, 34)
$btnClose.Add_Click({ $form.Close() })

$form.Controls.AddRange(@($btnRefresh, $btnRun, $btnLog, $btnTest, $btnClose))

Refresh-Status
$form.ShowDialog() | Out-Null
