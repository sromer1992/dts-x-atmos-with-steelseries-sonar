#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-UiLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [float]$Size = 10, [bool]$Bold = $false)
    $control = New-Object Windows.Forms.Label
    $control.Text = $Text; $control.SetBounds($X, $Y, $Width, $Height)
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $control.Font = New-Object Drawing.Font('Segoe UI', $Size, $style)
    $control.ForeColor = [Drawing.ColorTranslator]::FromHtml('#17263D')
    $Parent.Controls.Add($control)
    return $control
}

function New-UiButton {
    param($Parent, [string]$Text, [scriptblock]$Action, [bool]$Primary = $false, [int]$Width = 140)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.Size = New-Object Drawing.Size($Width, 36)
    $button.UseMnemonic = $false
    $button.Margin = New-Object Windows.Forms.Padding(0, 4, 10, 4)
    $button.FlatStyle = 'Flat'; $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = [Drawing.ColorTranslator]::FromHtml('#D4DCE7')
    $button.BackColor = if ($Primary) { [Drawing.ColorTranslator]::FromHtml('#156D63') } else { [Drawing.Color]::White }
    $button.ForeColor = if ($Primary) { [Drawing.Color]::White } else { [Drawing.ColorTranslator]::FromHtml('#17263D') }
    $button.Cursor = 'Hand'; $button.Add_Click($Action)
    $Parent.Controls.Add($button)
    return $button
}

function Set-UiPage {
    param([string]$Name)
    foreach ($key in $script:ui.Pages.Keys) {
        $script:ui.Pages[$key].Visible = $key -eq $Name
        $script:ui.Nav[$key].BackColor = if ($key -eq $Name) { [Drawing.ColorTranslator]::FromHtml('#E0EFEC') } else { [Drawing.Color]::White }
    }
    $script:ui.Page = $Name
}

function Get-UiSettings {
    return [pscustomobject]@{
        SetCommunications = $script:ui.Comms.Checked; SpatialApp = [string]$script:ui.Provider.SelectedItem
        RepairOnUnlock = $script:ui.Unlock.Checked; RepairOnResume = $script:ui.Resume.Checked
    }
}

function Set-UiSnapshot {
    param($Snapshot)
    $script:ui.Snapshot = $Snapshot
    $attention = @($Snapshot.Checks | Where-Object { $_.State -in @('Missing', 'Attention') }).Count
    $heading = if ($Snapshot.TaskState -eq 'Not installed') { 'Set up your audio route' } elseif ($attention) { 'A few things need attention' } elseif ($Snapshot.TaskState -eq 'Disabled') { 'Automatic repair is paused' } else { 'Device checks pass' }
    $script:ui.Heading.Text = $heading
    $script:ui.Heading.ForeColor = [Drawing.ColorTranslator]::FromHtml($(if ($attention) { '#966015' } else { '#156D63' }))
    $script:ui.Description.Text = 'Keep CABLE selected for DTS / Atmos, then send it through Sonar. Routing and spatial format still need a listening check.'
    $script:ui.Playback.Text = $Snapshot.Playback
    $script:ui.Voice.Text = if ($Snapshot.Settings.SetCommunications) { 'CABLE enforced for default voice audio' } else { 'Voice routing left unchanged (ChatMix friendly)' }
    $unlockText = if ($Snapshot.Settings.RepairOnUnlock) { 'On' } else { 'Off' }
    $resumeText = if ($Snapshot.Settings.RepairOnResume) { 'On' } else { 'Off' }
    $script:ui.Automation.Text = "$($Snapshot.TaskState)`r`nUnlock: $unlockText   Resume: $resumeText"
    $script:ui.Pause.Text = if ($Snapshot.TaskState -eq 'Disabled') { 'Resume automatic' } else { 'Pause automatic' }
    $script:ui.Checks.BeginUpdate(); $script:ui.Checks.Items.Clear()
    foreach ($check in $Snapshot.Checks) {
        $item = New-Object Windows.Forms.ListViewItem($check.Name)
        $item.SubItems.Add($check.State) | Out-Null; $item.SubItems.Add($check.Detail) | Out-Null
        $item.ForeColor = [Drawing.ColorTranslator]::FromHtml($(if ($check.State -eq 'Pass') { '#156D63' } else { '#966015' }))
        $script:ui.Checks.Items.Add($item) | Out-Null
    }
    $script:ui.Checks.EndUpdate()
    if (-not $script:ui.OptionsDirty) {
        $script:ui.ApplyingSnapshot = $true
        $script:ui.Provider.SelectedItem = $Snapshot.Settings.SpatialApp
        $script:ui.Comms.Checked = $Snapshot.Settings.SetCommunications
        $script:ui.Unlock.Checked = $Snapshot.Settings.RepairOnUnlock
        $script:ui.Resume.Checked = $Snapshot.Settings.RepairOnResume
        $script:ui.ApplyingSnapshot = $false
    }
    $script:ui.LastRun.Text = "Last scheduled run: $($Snapshot.LastTaskRun)   |   Result: $($Snapshot.LastTaskResult)"
    if ($Snapshot.LastRepair) {
        $when = [DateTime]::Parse($Snapshot.LastRepair.CompletedUtc).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
        $outcome = if ($Snapshot.LastRepair.ExitCode -eq 0) { 'Device checks passed' } else { 'Failed checks - see History & logs' }
        $script:ui.LastRun.Text = "Last repair: $when   |   $outcome"
    }
    $script:ui.Version.Text = "PACKAGE $($Snapshot.Version)   /   INSTALLED $(if ($Snapshot.InstalledVersion) { $Snapshot.InstalledVersion } else { '-' })"
    $script:ui.Log.Text = @($Snapshot.Log) -join "`r`n"
    $script:ui.Backups.Items.Clear()
    foreach ($backup in $Snapshot.Backups) {
        $item = New-Object Windows.Forms.ListViewItem($backup.Created)
        $item.SubItems.Add($backup.Version) | Out-Null
        $item.SubItems.Add($(if ($backup.HasChecksums) { 'Checksums saved' } else { 'Legacy backup' })) | Out-Null
        $item.Tag = $backup.Path; $script:ui.Backups.Items.Add($item) | Out-Null
    }
    $script:ui.NextRefresh = [DateTime]::UtcNow.AddSeconds(30)
}

function Start-UiOperation {
    param([string]$Operation, $Request, [string]$Destination = '', [switch]$Elevated)
    if ($script:ui.Job) { return }
    try {
        $jobDir = Join-Path (Join-Path $env:LOCALAPPDATA 'FixAudio\ui-jobs') ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $jobDir -Force | Out-Null
        $resultPath = Join-Path $jobDir 'result.json'; $requestPath = Join-Path $jobDir 'request.json'; $jobLog = Join-Path $jobDir 'worker.log'
        function Quote-UiArgument([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
        $command = '& ' + (Quote-UiArgument (Join-Path $PSScriptRoot 'Setup.ps1')) + ' -Operation ' + (Quote-UiArgument $Operation) +
            ' -ResultPath ' + (Quote-UiArgument $resultPath) + ' -ExpectedUserSid ' + (Quote-UiArgument ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
        if ($Request) { $Request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $requestPath -Encoding UTF8; $command += ' -RequestPath ' + (Quote-UiArgument $requestPath) }
        if ($Destination) { $command += ' -Destination ' + (Quote-UiArgument $Destination) }
        $command += ' *> ' + (Quote-UiArgument $jobLog) + '; exit $LASTEXITCODE'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
        $parameters = @{ FilePath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); ArgumentList = $arguments; WindowStyle = 'Hidden'; PassThru = $true; ErrorAction = 'Stop' }
        if ($Elevated -or $Operation -eq 'Driver') { $parameters.Verb = 'RunAs'; $Elevated = $true }
        $process = Start-Process @parameters
        $script:ui.Job = @{ Process = $process; Operation = $Operation; Request = $Request; Destination = $Destination; ResultPath = $resultPath; Directory = $jobDir; Elevated = [bool]$Elevated; Log = $jobLog; StartedUtc = [DateTime]::UtcNow; TimedOut = $false }
        $script:ui.Progress.Visible = $true
        $script:ui.Footer.Text = switch ($Operation) { 'Repair' { 'Repairing defaults and watching for delayed changes. This can take about two minutes.' }; 'Driver' { 'Downloading and verifying VB-CABLE. Complete the driver installer when it opens.' }; 'Snapshot' { 'Checking devices, task settings, and installed apps...' }; default { "$Operation in progress..." } }
        foreach ($button in $script:ui.ActionButtons) { $button.Enabled = $false }
    }
    catch { $script:ui.Footer.Text = $_.Exception.Message; $script:ui.Progress.Visible = $false }
}

function Complete-UiOperation {
    $job = $script:ui.Job
    if (-not $job) { return }
    if (-not $job.Process.HasExited) {
        if ($job.Operation -eq 'Snapshot' -and ([DateTime]::UtcNow - $job.StartedUtc).TotalSeconds -gt 45) {
            $job.TimedOut = $true; $job.Process.Kill(); $job.Process.WaitForExit(2000) | Out-Null
        }
        else { return }
    }
    $result = $null
    try {
        if ($job.TimedOut) { throw 'Status inspection timed out. Use Refresh to try again; audio settings were not changed.' }
        if (Test-Path -LiteralPath $job.ResultPath) { $result = Get-Content -LiteralPath $job.ResultPath -Raw | ConvertFrom-Json }
        else { throw "The worker did not return a result. $(Get-Content -LiteralPath $job.Log -Tail 5 -ErrorAction SilentlyContinue)" }
    }
    catch { $result = [pscustomobject]@{ Success = $false; Error = $_.Exception.Message; NeedsElevation = $false } }
    finally {
        $job.Process.Dispose(); $script:ui.Job = $null; $script:ui.Progress.Visible = $false
        foreach ($file in @('request.json', 'result.json', 'result.json.tmp', 'worker.log')) {
            $path = Join-Path $job.Directory $file
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item -LiteralPath $job.Directory -ErrorAction SilentlyContinue
        foreach ($button in $script:ui.ActionButtons) { $button.Enabled = $true }
    }
    if (-not $result.Success) {
        if ($result.NeedsElevation -and -not $job.Elevated -and $job.Operation -ne 'Snapshot') {
            Start-UiOperation $job.Operation $job.Request $job.Destination -Elevated
            return
        }
        $script:ui.Footer.Text = $result.Error
        if ($job.Operation -ne 'Snapshot') { [Windows.Forms.MessageBox]::Show($result.Error, 'FixAudio', 'OK', 'Error') | Out-Null }
        return
    }
    if ($job.Operation -eq 'Snapshot') { Set-UiSnapshot $result.Data; $script:ui.Footer.Text = 'Checks refreshed. Manual routing and spatial checks are shown separately.' }
    else {
        if ($job.Operation -in @('Options', 'Install')) { $script:ui.OptionsDirty = $false }
        $script:ui.Footer.Text = if ($result.Data.Message) { $result.Data.Message } else { 'Installation and settings verified.' }
        Start-UiOperation 'Snapshot'
    }
}

function Show-FixAudioWindow {
    param([string]$PreviewPath, [string]$PreviewPage = 'Overview')
    $script:ui = @{ Pages = @{}; Nav = @{}; ActionButtons = New-Object 'System.Collections.Generic.List[object]'; Job = $null; Snapshot = $null; NextRefresh = [DateTime]::UtcNow.AddYears(1); Page = 'Overview'; OptionsDirty = $false; ApplyingSnapshot = $false }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'FixAudio - DTS / Atmos with Sonar'; $form.ClientSize = New-Object Drawing.Size(960, 750)
    $form.MinimumSize = New-Object Drawing.Size(940, 740); $form.StartPosition = 'CenterScreen'
    $form.AutoScaleMode = 'Dpi'; $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $form.BackColor = [Drawing.ColorTranslator]::FromHtml('#F4F6FA')
    $script:ui.Form = $form
    $root = New-Object Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.Padding = New-Object Windows.Forms.Padding(24); $root.ColumnCount = 1; $root.RowCount = 4
    foreach ($height in @(86, 48)) { $root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) | Out-Null }
    $root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))) | Out-Null
    $root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 46))) | Out-Null
    $form.Controls.Add($root)
    $header = New-Object Windows.Forms.Panel; $header.Dock = 'Fill'; $root.Controls.Add($header, 0, 0)
    New-UiLabel $header 'FixAudio' 0 0 240 42 25 $true | Out-Null
    New-UiLabel $header 'DTS / ATMOS  +  STEELSERIES SONAR' 2 46 500 24 9 | Out-Null
    $script:ui.Version = New-UiLabel $header "PACKAGE $PackageVersion" 540 18 365 34 9
    $script:ui.Version.TextAlign = 'MiddleRight'; $script:ui.Version.Anchor = 'Top,Right'
    $nav = New-Object Windows.Forms.FlowLayoutPanel; $nav.Dock = 'Fill'; $nav.WrapContents = $false; $root.Controls.Add($nav, 0, 1)
    $body = New-Object Windows.Forms.Panel; $body.Dock = 'Fill'; $root.Controls.Add($body, 0, 2)
    foreach ($name in @('Overview', 'Audio options', 'Setup guide', 'History & logs')) {
        $page = New-Object Windows.Forms.Panel; $page.Dock = 'Fill'; $page.AutoScroll = $true; $body.Controls.Add($page); $script:ui.Pages[$name] = $page
        $pageName = $name
        $button = New-UiButton $nav $name ({ Set-UiPage $pageName }.GetNewClosure()) $false 150
        $script:ui.Nav[$name] = $button
    }
    $footer = New-Object Windows.Forms.Panel; $footer.Dock = 'Fill'; $root.Controls.Add($footer, 0, 3)
    $script:ui.Footer = New-UiLabel $footer 'Ready.' 0 9 720 34 9
    $script:ui.Footer.Anchor = 'Top,Left,Right'
    $script:ui.Progress = New-Object Windows.Forms.ProgressBar; $script:ui.Progress.Style = 'Marquee'; $script:ui.Progress.SetBounds(744, 13, 160, 15); $script:ui.Progress.Anchor = 'Top,Right'; $script:ui.Progress.Visible = $false; $footer.Controls.Add($script:ui.Progress)

    $overview = $script:ui.Pages['Overview']
    $layout = New-Object Windows.Forms.TableLayoutPanel; $layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 5; $overview.Controls.Add($layout)
    foreach ($height in @(102, 50, 118)) { $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) | Out-Null }
    $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))) | Out-Null
    $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 68))) | Out-Null
    $hero = New-Object Windows.Forms.Panel; $hero.Dock = 'Fill'; $hero.BackColor = [Drawing.Color]::White; $layout.Controls.Add($hero, 0, 0)
    $script:ui.Heading = New-UiLabel $hero 'Checking your setup...' 18 14 850 34 19 $true
    $script:ui.Description = New-UiLabel $hero 'Devices, defaults, and automation in one place.' 18 54 840 40 10
    $actions = New-Object Windows.Forms.FlowLayoutPanel; $actions.Dock = 'Fill'; $actions.WrapContents = $false; $layout.Controls.Add($actions, 0, 1)
    $script:ui.ActionButtons.Add((New-UiButton $actions 'Repair now' { Start-UiOperation 'Repair' } $true 135))
    $script:ui.ActionButtons.Add((New-UiButton $actions 'Refresh' { Start-UiOperation 'Snapshot' } $false 95))
    $script:ui.Pause = New-UiButton $actions 'Pause automatic' { if ($script:ui.Snapshot.TaskState -eq 'Disabled') { Start-UiOperation 'Resume' } else { Start-UiOperation 'Pause' } } $false 155
    $script:ui.ActionButtons.Add($script:ui.Pause)
    $script:ui.ActionButtons.Add((New-UiButton $actions 'Install / update' {
        if ($script:ui.Snapshot.InstalledScript) { Start-UiOperation 'Update' }
        else {
            $dialog = New-Object Windows.Forms.FolderBrowserDialog; $dialog.Description = 'Choose a permanent installation folder'; $dialog.SelectedPath = $DefaultInstallDir
            try { if ($dialog.ShowDialog() -eq 'OK') { Start-UiOperation 'Install' ([pscustomobject]@{ Settings = Get-UiSettings }) (Join-Path $dialog.SelectedPath 'FixAudio.ps1') } } finally { $dialog.Dispose() }
        }
    } $false 145))
    New-UiButton $actions 'Copy report' { if ($script:ui.Snapshot) { [Windows.Forms.Clipboard]::SetText((Get-DiagnosticReport $script:ui.Snapshot)); $script:ui.Footer.Text = 'Diagnostic report copied. Username, computer name, and user-profile paths were redacted.' } } $false 130 | Out-Null
    $cards = New-Object Windows.Forms.TableLayoutPanel; $cards.Dock = 'Fill'; $cards.ColumnCount = 3; $layout.Controls.Add($cards, 0, 2)
    foreach ($i in 0..2) { $cards.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 33.333))) | Out-Null }
    foreach ($entry in @(@('PLAYBACK', 'Playback'), @('VOICE ROUTING', 'Voice'), @('AUTOMATIC REPAIR', 'Automation'))) {
        $card = New-Object Windows.Forms.Panel; $card.Dock = 'Fill'; $card.BackColor = [Drawing.Color]::White; $card.Margin = New-Object Windows.Forms.Padding(0, 4, 10, 8); $cards.Controls.Add($card)
        New-UiLabel $card $entry[0] 14 12 250 23 9 $true | Out-Null
        $script:ui[$entry[1]] = New-UiLabel $card 'Checking...' 14 39 260 62 10
    }
    $checks = New-Object Windows.Forms.ListView; $checks.Dock = 'Fill'; $checks.View = 'Details'; $checks.FullRowSelect = $true; $checks.HeaderStyle = 'Nonclickable'; $checks.BorderStyle = 'None'
    $checks.Columns.Add('CHECK', 180) | Out-Null; $checks.Columns.Add('STATUS', 100) | Out-Null; $checks.Columns.Add('DETAIL', 590) | Out-Null
    $layout.Controls.Add($checks, 0, 3); $script:ui.Checks = $checks
    $manual = New-Object Windows.Forms.Panel; $manual.Dock = 'Fill'; $layout.Controls.Add($manual, 0, 4)
    New-UiLabel $manual 'MANUAL CHECK   Listen bridge > Sonar Gaming > headset, plus the Windows spatial format.' 0 12 890 22 9 $true | Out-Null
    $script:ui.LastRun = New-UiLabel $manual 'Last scheduled run: checking...' 0 38 890 22 9

    $options = $script:ui.Pages['Audio options']; $options.BackColor = [Drawing.Color]::White
    New-UiLabel $options 'Choose how FixAudio behaves' 20 20 800 35 18 $true | Out-Null
    New-UiLabel $options 'Spatial app' 22 76 200 24 11 $true | Out-Null
    $script:ui.Provider = New-Object Windows.Forms.ComboBox; $script:ui.Provider.DropDownStyle = 'DropDownList'; $script:ui.Provider.Items.AddRange(@('Auto', 'DTS', 'Dolby', 'None')); $script:ui.Provider.SelectedItem = 'Auto'; $script:ui.Provider.SetBounds(22, 106, 220, 30); $options.Controls.Add($script:ui.Provider)
    New-UiLabel $options 'Auto opens the only installed app. If both are installed, choose DTS or Dolby. Select the matching spatial format in Windows too.' 265 104 600 52 10 | Out-Null
    $script:ui.Comms = New-Object Windows.Forms.CheckBox; $script:ui.Comms.Text = 'Route default voice audio through CABLE'; $script:ui.Comms.SetBounds(22, 171, 800, 30); $options.Controls.Add($script:ui.Comms)
    New-UiLabel $options 'Leave this off to preserve separate voice routing. For ChatMix, select Sonar Chat in your voice app. Turning it on mixes default voice audio into Sonar Gaming.' 44 207 810 50 10 | Out-Null
    New-UiLabel $options 'Optional recovery' 22 280 800 28 12 $true | Out-Null
    $script:ui.Unlock = New-Object Windows.Forms.CheckBox; $script:ui.Unlock.Text = 'Repair after unlocking Windows'; $script:ui.Unlock.SetBounds(22, 321, 800, 28); $options.Controls.Add($script:ui.Unlock)
    $script:ui.Resume = New-Object Windows.Forms.CheckBox; $script:ui.Resume.Text = 'Repair after waking from sleep'; $script:ui.Resume.SetBounds(22, 356, 800, 28); $options.Controls.Add($script:ui.Resume)
    $changed = { if (-not $script:ui.ApplyingSnapshot) { $script:ui.OptionsDirty = $true; $script:ui.Footer.Text = 'Options changed. Use Save options to apply them.' } }
    $script:ui.Provider.Add_SelectedIndexChanged($changed)
    foreach ($checkbox in @($script:ui.Comms, $script:ui.Unlock, $script:ui.Resume)) { $checkbox.Add_CheckedChanged($changed) }
    New-UiLabel $options 'These options reclaim your configured defaults after the event. Runs are short, with a two-minute cooldown. Pause automatic repair when using another output intentionally.' 44 394 810 50 10 | Out-Null
    $save = New-UiButton $options 'Save options' { if (-not $script:ui.Snapshot.InstalledScript) { $script:ui.Footer.Text = 'Choose your options, then use Install / update on Overview.' } else { Start-UiOperation 'Options' ([pscustomobject]@{ Settings = Get-UiSettings }) } } $true 145
    $save.Location = New-Object Drawing.Point(22, 461); $script:ui.ActionButtons.Add($save)

    $guide = $script:ui.Pages['Setup guide']; $guide.BackColor = [Drawing.Color]::White
    New-UiLabel $guide 'Finish the route, then listen' 20 18 800 34 18 $true | Out-Null
    $guideText = @"
1. ENABLE SPATIAL SOUND ON CABLE INPUT
Open Sound settings, select CABLE Input, and choose DTS Headphone:X or Dolby Atmos for Headphones in its Spatial sound settings.

2. CONNECT CABLE OUTPUT TO SONAR
Open Recording devices > CABLE Output > Properties > Listen. Enable Listen to this device, and choose SteelSeries Sonar - Gaming as the playback destination.

3. CHECK SONAR AND CHATMIX
Choose your headset as Sonar's output. Turn off Sonar Spatial Audio to avoid applying spatial processing twice. For separate ChatMix, choose Sonar Chat in your voice app.

4. TEST AND CONFIRM
A headset chime confirms audible playback. Check the Listen destination and spatial format separately; a chime alone does not prove the intended processing path.
"@
    New-UiLabel $guide $guideText 22 72 850 330 11 | Out-Null
    $guideButtons = New-Object Windows.Forms.FlowLayoutPanel; $guideButtons.SetBounds(22, 411, 860, 95); $guide.Controls.Add($guideButtons)
    New-UiButton $guideButtons 'Sound settings' { Start-Process 'ms-settings:sound' } $false 145 | Out-Null
    New-UiButton $guideButtons 'Recording devices' { Start-Process control.exe -ArgumentList 'mmsys.cpl,,1' } $false 165 | Out-Null
    New-UiButton $guideButtons 'Open SteelSeries' { $paths = @("$env:ProgramFiles\SteelSeries\GG\SteelSeriesGG.exe", "${env:ProgramFiles(x86)}\SteelSeries\GG\SteelSeriesGG.exe"); $found = $paths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1; if ($found) { Start-Process $found } else { Start-Process 'https://steelseries.com/gg' } } $false 150 | Out-Null
    New-UiButton $guideButtons 'Spatial app store' { $query = if ($script:ui.Provider.SelectedItem -eq 'Dolby') { 'Dolby Access' } else { 'DTS Sound Unbound' }; Start-Process ('ms-windows-store://search/?query=' + [Uri]::EscapeDataString($query)) } $false 150 | Out-Null
    New-UiButton $guideButtons 'Test sound' { try { $wav = Join-Path $env:SystemRoot 'Media\Windows Notify.wav'; $player = New-Object Media.SoundPlayer($wav); $player.Play(); $script:ui.Footer.Text = 'Listen for the headset chime, then confirm the route and spatial format in Windows.' } catch { $script:ui.Footer.Text = $_.Exception.Message } } $true 135 | Out-Null
    $driver = New-UiButton $guideButtons 'Install VB-CABLE' { Start-UiOperation 'Driver' } $false 150; $script:ui.ActionButtons.Add($driver)
    New-UiButton $guideButtons 'VB-Audio website' { Start-Process 'https://vb-audio.com/Cable/' } $false 155 | Out-Null

    $history = $script:ui.Pages['History & logs']
    $historyLayout = New-Object Windows.Forms.TableLayoutPanel; $historyLayout.Dock = 'Fill'; $historyLayout.ColumnCount = 1; $historyLayout.RowCount = 4; $history.Controls.Add($historyLayout)
    foreach ($height in @(34, 143, 50)) { $historyLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) | Out-Null }
    $historyLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))) | Out-Null
    $historyTitle = New-Object Windows.Forms.Label; $historyTitle.Text = 'Restore a backup or inspect recent activity'; $historyTitle.Dock = 'Fill'; $historyTitle.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold); $historyLayout.Controls.Add($historyTitle, 0, 0)
    $script:ui.Backups = New-Object Windows.Forms.ListView; $script:ui.Backups.Dock = 'Fill'; $script:ui.Backups.View = 'Details'; $script:ui.Backups.FullRowSelect = $true; $script:ui.Backups.MultiSelect = $false; $script:ui.Backups.Columns.Add('BACKUP CREATED', 250) | Out-Null; $script:ui.Backups.Columns.Add('VERSION', 140) | Out-Null; $script:ui.Backups.Columns.Add('VALIDATION', 440) | Out-Null; $historyLayout.Controls.Add($script:ui.Backups, 0, 1)
    $historyActions = New-Object Windows.Forms.FlowLayoutPanel; $historyActions.Dock = 'Fill'; $historyActions.WrapContents = $false; $historyLayout.Controls.Add($historyActions, 0, 2)
    $restore = New-UiButton $historyActions 'Restore selected' { if ($script:ui.Backups.SelectedItems.Count -eq 0) { $script:ui.Footer.Text = 'Select a backup first.'; return }; if ([Windows.Forms.MessageBox]::Show('Restore this script, its saved options, and task? A backup of the current installation will be kept. Audio routing will not change immediately.', 'Restore FixAudio', 'YesNo', 'Question') -eq 'Yes') { Start-UiOperation 'Restore' ([pscustomobject]@{ BackupPath = $script:ui.Backups.SelectedItems[0].Tag }) } } $false 165; $script:ui.ActionButtons.Add($restore)
    New-UiButton $historyActions 'Export report' { if (-not $script:ui.Snapshot) { return }; $saveDialog = New-Object Windows.Forms.SaveFileDialog; $saveDialog.Filter = 'Text report (*.txt)|*.txt'; $saveDialog.FileName = 'FixAudio-report.txt'; try { if ($saveDialog.ShowDialog() -eq 'OK') { Get-DiagnosticReport $script:ui.Snapshot | Set-Content -LiteralPath $saveDialog.FileName -Encoding UTF8; $script:ui.Footer.Text = 'Redacted diagnostic report saved.' } } finally { $saveDialog.Dispose() } } $false 140 | Out-Null
    New-UiButton $historyActions 'Open full log' { $path = Join-Path $env:USERPROFILE 'FixAudio.log'; if (Test-Path -LiteralPath $path) { Start-Process notepad.exe -ArgumentList ('"' + $path + '"') } } $false 140 | Out-Null
    $uninstall = New-UiButton $historyActions 'Uninstall FixAudio' { if ([Windows.Forms.MessageBox]::Show('Remove only the FixAudio task, installed script, and options? Drivers, spatial apps, logs, backups, and current Windows routing will be kept.', 'Uninstall FixAudio', 'YesNo', 'Warning') -eq 'Yes') { Start-UiOperation 'Uninstall' } } $false 170; $uninstall.ForeColor = [Drawing.ColorTranslator]::FromHtml('#A33145'); $script:ui.ActionButtons.Add($uninstall)
    $script:ui.Log = New-Object Windows.Forms.TextBox; $script:ui.Log.Dock = 'Fill'; $script:ui.Log.Multiline = $true; $script:ui.Log.ReadOnly = $true; $script:ui.Log.ScrollBars = 'Both'; $script:ui.Log.WordWrap = $false; $script:ui.Log.Font = New-Object Drawing.Font('Consolas', 9); $script:ui.Log.BackColor = [Drawing.Color]::White; $historyLayout.Controls.Add($script:ui.Log, 0, 3)
    Set-UiPage 'Overview'
    if ($PreviewPath) {
        Set-UiSnapshot (Get-ControlSnapshot)
        Set-UiPage $PreviewPage
        $form.ShowInTaskbar = $false; $form.Opacity = 0; $form.Show(); [Windows.Forms.Application]::DoEvents()
        $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
        try { $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height))); $bitmap.Save($PreviewPath, [Drawing.Imaging.ImageFormat]::Png) }
        finally { $bitmap.Dispose(); $form.Close(); $form.Dispose() }
        return
    }
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 500
    $timer.Add_Tick({ if ($script:ui.Job) { Complete-UiOperation } elseif ($script:ui.Page -eq 'Overview' -and [DateTime]::UtcNow -ge $script:ui.NextRefresh) { Start-UiOperation 'Snapshot' } })
    $form.Add_Shown({ Start-UiOperation 'Snapshot'; $timer.Start() })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:ui.Job -and $script:ui.Job.Operation -ne 'Snapshot') { $eventArgs.Cancel = $true; $script:ui.Footer.Text = 'Wait for the current operation to finish before closing.' }
        elseif ($script:ui.Job) {
            if (-not $script:ui.Job.Process.HasExited) { $script:ui.Job.Process.Kill(); $script:ui.Job.Process.WaitForExit(2000) | Out-Null }
            Complete-UiOperation
        }
    })
    try { $form.ShowDialog() | Out-Null }
    finally { $timer.Stop(); $timer.Dispose(); $form.Dispose() }
}
