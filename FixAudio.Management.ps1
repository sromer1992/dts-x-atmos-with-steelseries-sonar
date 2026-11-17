#requires -Version 5.1
# Shared control operations. Dot-sourcing this file performs no operations.
function New-FixAudioTaskXml {
    param([string]$Destination, $Settings, [bool]$Enabled = $true, [string]$UserSid)
    Test-Settings $Settings
    $engine = [Security.SecurityElement]::Escape((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $arguments = [Security.SecurityElement]::Escape("-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Destination`" -Automatic")
    $user = [Security.SecurityElement]::Escape($UserSid)
    $enabledText = $Enabled.ToString().ToLowerInvariant()
    $extra = ''
    if ($Settings.RepairOnUnlock) {
        $extra += "<SessionStateChangeTrigger id=`"FixAudio.Unlock`"><Enabled>true</Enabled><UserId>$user</UserId><Delay>PT10S</Delay><StateChange>SessionUnlock</StateChange></SessionStateChangeTrigger>"
    }
    if ($Settings.RepairOnResume) {
        $subscription = [Security.SecurityElement]::Escape("<QueryList><Query Id=`"0`" Path=`"System`"><Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select></Query></QueryList>")
        $extra += "<EventTrigger id=`"FixAudio.Resume`"><Enabled>true</Enabled><Subscription>$subscription</Subscription><Delay>PT10S</Delay></EventTrigger>"
    }
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>FixAudio $PackageVersion - VB-CABLE defaults and optional recovery</Description></RegistrationInfo>
  <Triggers><LogonTrigger id="FixAudio.Login"><Enabled>true</Enabled><UserId>$user</UserId></LogonTrigger>$extra</Triggers>
  <Principals><Principal id="Author"><UserId>$user</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><Enabled>$enabledText</Enabled><ExecutionTimeLimit>PT6M</ExecutionTimeLimit></Settings>
  <Actions Context="Author"><Exec><Command>$engine</Command><Arguments>$arguments</Arguments></Exec></Actions>
</Task>
"@
}

function Save-InstallationSnapshot {
    param([string]$Destination, [string]$TaskXml)
    $directory = Split-Path -Parent $Destination
    $name = '.FixAudio-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $backup = Join-Path $directory $name
    New-Item -ItemType Directory -Path $backup -ErrorAction Stop | Out-Null
    $hashes = [ordered]@{}
    foreach ($file in @('FixAudio.ps1', 'FixAudio.config.json')) {
        $source = Join-Path $directory $file
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $copy = Join-Path $backup $file
            Copy-Item -LiteralPath $source -Destination $copy -ErrorAction Stop
            $hashes[$file] = (Get-FileHash -LiteralPath $copy -Algorithm SHA256 -ErrorAction Stop).Hash
        }
    }
    if ($TaskXml) {
        $taskFile = Join-Path $backup 'Task.xml'
        $TaskXml | Set-Content -LiteralPath $taskFile -Encoding Unicode -ErrorAction Stop
        $hashes['Task.xml'] = (Get-FileHash -LiteralPath $taskFile -Algorithm SHA256).Hash
    }
    [pscustomobject]@{ CreatedUtc = [DateTime]::UtcNow.ToString('o'); Files = $hashes } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $backup 'backup-manifest.json') -Encoding UTF8 -ErrorAction Stop
    return $backup
}

function Get-FixAudioBackups {
    param([string]$Destination)
    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) { return }
    Get-ChildItem -LiteralPath $parent -Directory -Force -Filter '.FixAudio-backup-*' -ErrorAction Stop |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'FixAudio.ps1') -PathType Leaf) } |
        Sort-Object CreationTimeUtc -Descending | ForEach-Object {
            $version = 'Legacy'
            $text = Get-Content -LiteralPath (Join-Path $_.FullName 'FixAudio.ps1') -Raw -ErrorAction Stop
            if ($text -match '(?m)^\$ScriptVersion\s*=\s*''([^'']+)''') { $version = $Matches[1] }
            [pscustomobject]@{ Path = $_.FullName; Name = $_.Name; Version = $version; Created = $_.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'); HasChecksums = (Test-Path -LiteralPath (Join-Path $_.FullName 'backup-manifest.json')) }
        }
}

function Assert-BackupPath {
    param([string]$Destination, [string]$BackupPath)
    $resolved = [IO.Path]::GetFullPath($BackupPath)
    $parent = [IO.Path]::GetFullPath((Split-Path -Parent $Destination)).TrimEnd('\')
    if ((Split-Path -Parent $resolved).TrimEnd('\') -ine $parent -or
        [IO.Path]::GetFileName($resolved) -notmatch '^\.FixAudio-backup-\d{8}-\d{6}-[a-f0-9]{6}$') { throw 'Backup must be a FixAudio backup directly beside the installed script.' }
    $directory = Get-Item -LiteralPath $resolved -ErrorAction Stop
    if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Backup links are not supported.' }
    foreach ($file in Get-ChildItem -LiteralPath $resolved -Force) {
        if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $file.Name -notin @('FixAudio.ps1', 'FixAudio.config.json', 'Task.xml', 'backup-manifest.json')) { throw 'Backup contains unexpected files or links; it was left untouched.' }
    }
    return $resolved
}

function Remove-OldFixAudioBackups {
    param([string]$Destination, [int]$Keep = 3)
    try { $oldBackups = @(Get-FixAudioBackups $Destination | Select-Object -Skip $Keep) }
    catch { Write-Warning "Could not list backups for cleanup: $_"; return }
    foreach ($backup in $oldBackups) {
        try {
            $path = Assert-BackupPath $Destination $backup.Path
            # Only known files are removed, followed by the empty directory.
            Get-ChildItem -LiteralPath $path -Force | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
        catch { Write-Warning "Backup cleanup skipped: $_" }
    }
}

function Assert-MaintenanceTask {
    $task = Get-FixAudioTask
    if (-not $task) { throw 'FixAudio is not installed.' }
    if ((Get-TaskOwnerSid $task) -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'This task belongs to a different Windows account.' }
    if ($task.State -eq 'Running') { throw 'FixAudio is running. Wait for it to finish first.' }
    Get-TaskScriptPath $task | Out-Null
    return $task
}

function Assert-TaskWritable {
    # Re-register the unchanged definition before touching files or backups. A task created with
    # administrator rights cannot be replaced from a standard token; failing here changes nothing,
    # so the dashboard can retry elevated without a rollback or a spare backup.
    param([string]$TaskXml)
    try { Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $TaskXml -Force -ErrorAction Stop | Out-Null }
    catch { throw "Updating the FixAudio task needs administrator rights; nothing was changed. ($($_.Exception.Message))" }
}

function Copy-AtomicFile {
    param([string]$Source, [string]$Destination)
    $stage = $Destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        Copy-Item -LiteralPath $Source -Destination $stage -ErrorAction Stop
        if (Test-Path -LiteralPath $Destination) { [IO.File]::Replace($stage, $Destination, [NullString]::Value) }
        else { Move-Item -LiteralPath $stage -Destination $Destination -ErrorAction Stop }
        if ((Get-FileHash -LiteralPath $Destination).Hash -ne (Get-FileHash -LiteralPath $Source).Hash) { throw 'Restored file verification failed.' }
    }
    finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue } }
}

function Apply-InstallationSnapshot {
    param([string]$Destination, [string]$BackupPath)
    foreach ($file in @('FixAudio.ps1', 'FixAudio.config.json')) {
        $source = Join-Path $BackupPath $file
        $target = Join-Path (Split-Path -Parent $Destination) $file
        if (Test-Path -LiteralPath $source) { Copy-AtomicFile $source $target }
        elseif (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
    }
    $taskFile = Join-Path $BackupPath 'Task.xml'
    if (Test-Path -LiteralPath $taskFile) {
        Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml (Get-Content -LiteralPath $taskFile -Raw) -Force -ErrorAction Stop | Out-Null
    }
}

function Restore-FixAudioBackup {
    param([string]$BackupPath)
    $task = Assert-MaintenanceTask
    $dest = Get-TaskScriptPath $task
    $backup = Assert-BackupPath $dest $BackupPath
    $source = Join-Path $backup 'FixAudio.ps1'
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -or -not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'The backup script is missing or contains syntax errors.' }
    $manifestPath = Join-Path $backup 'backup-manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $expectedFiles = @('FixAudio.ps1', 'Task.xml')
        if (Test-Path -LiteralPath (Join-Path $backup 'FixAudio.config.json')) { $expectedFiles += 'FixAudio.config.json' }
        foreach ($file in $expectedFiles) {
            if ($manifest.Files.PSObject.Properties.Name -notcontains $file -or $manifest.Files.$file -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Backup checksum manifest is incomplete.' }
        }
        foreach ($property in $manifest.Files.PSObject.Properties) {
            if ($property.Name -notin @('FixAudio.ps1', 'FixAudio.config.json', 'Task.xml') -or
                (Get-FileHash -LiteralPath (Join-Path $backup $property.Name)).Hash -ne $property.Value) { throw 'Backup checksum verification failed.' }
        }
    }
    $taskFile = Join-Path $backup 'Task.xml'
    if (-not (Test-Path -LiteralPath $taskFile)) { throw 'This backup has no task definition and cannot restore a complete installation.' }
    [xml]$xml = Get-Content -LiteralPath $taskFile -Raw
    $ns = New-Object Xml.XmlNamespaceManager($xml.NameTable); $ns.AddNamespace('t', $xml.DocumentElement.NamespaceURI)
    $exec = $xml.SelectNodes('/t:Task/t:Actions/*', $ns)
    $owner = $xml.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:UserId', $ns)
    $record = [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = $exec[0].Command; Arguments = $exec[0].Arguments }); Principal = [pscustomobject]@{ UserId = $owner.InnerText } }
    if ($exec.Count -ne 1 -or (Get-TaskScriptPath $record) -ine $dest -or (Get-TaskOwnerSid $record) -ne (Get-TaskOwnerSid $task)) { throw 'Backup task does not match this installation and user.' }
    $currentXml = Export-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    Assert-TaskWritable $currentXml
    $undo = Save-InstallationSnapshot $dest $currentXml
    try { Apply-InstallationSnapshot $dest $backup }
    catch { $failure = $_; Apply-InstallationSnapshot $dest $undo; throw "Restore failed; the current installation was recovered: $failure" }
    Remove-OldFixAudioBackups $dest
    return [pscustomobject]@{ Message = 'Previous installation restored. Current audio routing was not changed.'; Backup = $undo }
}

function Uninstall-FixAudio {
    $task = Assert-MaintenanceTask
    $dest = Get-TaskScriptPath $task
    if ($dest -ieq [IO.Path]::GetFullPath($SourceScript)) { throw 'The task points into the setup package. Remove that task manually to preserve the source.' }
    $currentXml = Export-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    Assert-TaskWritable $currentXml
    $backup = Save-InstallationSnapshot $dest $currentXml
    try {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        foreach ($file in @($dest, (Join-Path (Split-Path -Parent $dest) 'FixAudio.config.json'))) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
        }
    }
    catch { $failure = $_; Apply-InstallationSnapshot $dest $backup; throw "Uninstall failed; installation restored: $failure" }
    return [pscustomobject]@{ Message = 'FixAudio script and scheduled task removed. Drivers, spatial apps, logs, backups, and Windows routing were retained.'; Backup = $backup }
}

function Get-ControlSnapshot {
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $task = $null; $dest = ''; $taskInfo = $null; $installedVersion = ''; $taskProblems = @()
    $settings = [pscustomobject]@{ SetCommunications = $false; SpatialApp = 'Auto'; RepairOnUnlock = $false; RepairOnResume = $false }
    try {
        $task = Get-FixAudioTask
        if ($task) {
            $dest = Get-TaskScriptPath $task
            $settings = Get-InstallSettings $dest
            if (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $dest) 'FixAudio.config.json'))) { $taskProblems += 'Saved options are missing; update to restore them' }
            $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
            if ((Get-TaskOwnerSid $task) -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { $taskProblems += 'Task belongs to another user' }
            if ([string]$task.Principal.RunLevel -notin @('Limited', '0')) { $taskProblems += 'Task still runs elevated' }
            if ($task.Settings.ExecutionTimeLimit -ne 'PT6M') { $taskProblems += 'Task time limit needs updating' }
            if ([string]$task.Settings.MultipleInstances -notin @('IgnoreNew', '2')) { $taskProblems += 'Overlapping task starts are not blocked' }
            if ($task.Actions[0].Arguments -notlike '*-NoProfile -NonInteractive*') { $taskProblems += 'Task startup flags need updating' }
            [xml]$taskXml = Export-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
            $ns = New-Object Xml.XmlNamespaceManager($taskXml.NameTable); $ns.AddNamespace('t', $taskXml.DocumentElement.NamespaceURI)
            $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $login = @($taskXml.SelectNodes('/t:Task/t:Triggers/t:LogonTrigger', $ns) | Where-Object {
                if ($_.Enabled -eq 'false' -or -not $_.UserId) { return $false }
                try { return (Get-TaskOwnerSid ([pscustomobject]@{ Principal = [pscustomobject]@{ UserId = [string]$_.UserId } })) -eq $ownerSid }
                catch { return $false }
            })
            if ($login.Count -eq 0) { $taskProblems += 'Login trigger is missing or disabled' }
            foreach ($name in @('Unlock', 'Resume')) {
                $nodes = $taskXml.SelectNodes("/t:Task/t:Triggers/*[@id='FixAudio.$name']", $ns)
                $actual = @($nodes | Where-Object { $_.Enabled -ne 'false' }).Count -gt 0
                if ($actual -ne [bool]$settings.('RepairOn' + $name)) { $taskProblems += "$name trigger does not match options" }
            }
            if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { $taskProblems += 'Installed script is missing' }
            else {
                $scriptText = Get-Content -LiteralPath $dest -Raw
                if ($scriptText -match '(?m)^\$ScriptVersion\s*=\s*''([^'']+)''') { $installedVersion = $Matches[1] }
                if ((Get-FileHash -LiteralPath $dest).Hash -ne (Get-FileHash -LiteralPath $SourceScript).Hash) { $taskProblems += 'An update is available in this package' }
            }
        }
    }
    catch { $taskProblems += $_.Exception.Message }
    $taskState = if ($task) { [string]$task.State } else { 'Not installed' }
    $installationState = if (-not $task) { 'Missing' } elseif ($taskProblems.Count) { 'Attention' } elseif ($taskState -eq 'Disabled') { 'Paused' } else { 'Pass' }
    $checks.Add([pscustomobject]@{ Name = 'Automatic repair'; State = $installationState; Detail = if ($taskProblems.Count) { $taskProblems -join '; ' } else { $taskState } })
    $playback = $null; $comms = $null; $devices = @()
    try {
        Import-Module AudioDeviceCmdlets -RequiredVersion $AudioModuleVersion -ErrorAction Stop
        $devices = @(Get-AudioDevice -List -ErrorAction Stop)
        $playback = Get-AudioDevice -Playback -ErrorAction Stop
        $comms = Get-AudioDevice -PlaybackCommunication -ErrorAction Stop
        $checks.Add([pscustomobject]@{ Name = 'Audio dependency'; State = 'Pass'; Detail = "AudioDeviceCmdlets $AudioModuleVersion" })
        foreach ($endpoint in @(
            @{ Name = 'CABLE Input'; Type = 'Playback'; Pattern = '^CABLE Input(?: \(|$)' },
            @{ Name = 'CABLE Output'; Type = 'Recording'; Pattern = '^CABLE Output(?: \(|$)' },
            @{ Name = 'Sonar Gaming'; Type = 'Playback'; Pattern = '^SteelSeries Sonar - Gaming(?: \(|$)' }
        )) {
            $matchesFound = @($devices | Where-Object { $_.Type -eq $endpoint.Type -and $_.Name -match $endpoint.Pattern })
            $checks.Add([pscustomobject]@{ Name = $endpoint.Name; State = if ($matchesFound.Count -eq 1) { 'Pass' } else { 'Attention' }; Detail = if ($matchesFound.Count -eq 1) { 'Present and enabled' } elseif ($matchesFound.Count -gt 1) { 'Multiple matches; resolve duplicate devices' } else { 'Missing or disabled' } })
        }
        $playbackOK = $playback -and $playback.Name -match '^CABLE Input(?: \(|$)'
        $voiceOK = -not $settings.SetCommunications -or ($comms -and $comms.ID -eq $playback.ID -and $playbackOK)
        $checks.Add([pscustomobject]@{ Name = 'Windows defaults'; State = if ($playbackOK -and $voiceOK) { 'Pass' } else { 'Attention' }; Detail = if ($playbackOK -and $voiceOK) { 'Requested defaults match' } else { 'Repair can restore requested defaults' } })
    }
    catch { $checks.Add([pscustomobject]@{ Name = 'Audio dependency'; State = 'Attention'; Detail = "Cannot inspect endpoints: $($_.Exception.Message)" }) }
    try {
        $dts = [bool](Get-AppxPackage -Name '*DTSSoundUnbound*' -ErrorAction Stop)
        $dolby = [bool](Get-AppxPackage -Name '*DolbyAccess*' -ErrorAction Stop)
        $providerOK = switch ($settings.SpatialApp) { 'DTS' { $dts }; 'Dolby' { $dolby }; 'None' { $true }; default { $dts -xor $dolby } }
        $checks.Add([pscustomobject]@{ Name = 'Spatial app'; State = if ($providerOK) { 'Pass' } else { 'Attention' }; Detail = if ($providerOK) { "Preference: $($settings.SpatialApp)" } elseif ($dts -and $dolby -and $settings.SpatialApp -eq 'Auto') { 'Both installed: choose DTS or Dolby' } else { 'Selected app is not available; check Options' } })
    }
    catch { $checks.Add([pscustomobject]@{ Name = 'Spatial app'; State = 'Attention'; Detail = 'Could not inspect Store apps' }) }
    $lastRepair = $null
    $runState = Join-Path $env:LOCALAPPDATA 'FixAudio\last-run.json'
    if (Test-Path -LiteralPath $runState) { try { $lastRepair = Get-Content -LiteralPath $runState -Raw | ConvertFrom-Json } catch {} }
    $lastRun = if ($taskInfo -and $taskInfo.LastRunTime.Year -gt 2000) { $taskInfo.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'Not recorded' }
    $lastResult = if ($taskInfo) { '{0} (0x{0:X})' -f [long]$taskInfo.LastTaskResult } else { 'Not recorded' }
    $lastLog = @()
    $logPath = Join-Path $env:USERPROFILE 'FixAudio.log'
    # PowerShell 5.1 attaches provider metadata to Get-Content strings. Keep
    # plain .NET strings here so JSON never walks PSDrive/provider objects.
    if (Test-Path -LiteralPath $logPath) {
        try { $lastLog = @([IO.File]::ReadAllLines($logPath) | Select-Object -Last 35) }
        catch { $lastLog = @('The log could not be read; another process may be writing it.') }
    }
    return [pscustomobject]@{
        Version = $PackageVersion; InstalledVersion = $installedVersion; InstalledScript = $dest; TaskState = $taskState
        Settings = $settings; Checks = @($checks.ToArray()); Playback = if ($playback) { $playback.Name } else { 'Unavailable' }
        Communications = if ($comms) { $comms.Name } else { 'Unavailable' }; LastTaskRun = $lastRun; LastTaskResult = $lastResult
        LastRepair = $lastRepair; Backups = if ($dest) { @(Get-FixAudioBackups $dest) } else { @() }; Log = $lastLog
        ManualChecks = 'Listen destination, headset output, and active spatial format require manual confirmation.'
    }
}

function Get-DiagnosticReport {
    param($Snapshot)
    $lines = @("FixAudio diagnostic report - package $($Snapshot.Version)", "Installed version: $($Snapshot.InstalledVersion)", "Task: $($Snapshot.TaskState)", "Last task run: $($Snapshot.LastTaskRun)", "Last task result: $($Snapshot.LastTaskResult)", "Playback: $($Snapshot.Playback)", "Communications: $($Snapshot.Communications)", "Options: $($Snapshot.Settings | ConvertTo-Json -Compress)", '')
    $lines += @($Snapshot.Checks | ForEach-Object { '{0}: {1} - {2}' -f $_.Name, $_.State, $_.Detail })
    if ($Snapshot.LastRepair) { $lines += "Latest repair: $($Snapshot.LastRepair.CompletedUtc); exit $($Snapshot.LastRepair.ExitCode); automatic=$($Snapshot.LastRepair.Automatic)" }
    $lines += @('', $Snapshot.ManualChecks, '', 'Recent log:') + @($Snapshot.Log)
    $text = $lines -join "`r`n"
    foreach ($replacement in @(@($env:USERPROFILE, '<USERPROFILE>'), @($env:COMPUTERNAME, '<COMPUTER>'), @($env:USERNAME, '<USER>'))) {
        if ($replacement[0]) { $text = [regex]::Replace($text, [regex]::Escape($replacement[0]), $replacement[1], [Text.RegularExpressions.RegexOptions]::IgnoreCase) }
    }
    return $text
}

function Test-DriverArchive {
    param([string]$ArchivePath)
    $expected = 'B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB'
    if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expected) {
        throw 'VB-CABLE archive checksum does not match this release. Nothing was run. Download from the official VB-Audio website or use an updated FixAudio package.'
    }
}

function Install-VerifiedVBCable {
    if (-not (Test-Admin)) { throw 'Installing the VB-CABLE driver requires administrator rights.' }
    $root = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
    $directory = Join-Path $root ('FixAudio-driver-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
    try {
        $archive = Join-Path $directory 'driver.zip'
        Invoke-WebRequest -Uri 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip' -OutFile $archive -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        Test-DriverArchive $archive
        $extracted = Join-Path $directory 'extracted'
        Expand-Archive -LiteralPath $archive -DestinationPath $extracted -ErrorAction Stop
        $installers = @(Get-ChildItem -LiteralPath $extracted -Recurse -Filter 'VBCABLE_Setup_x64.exe' -File)
        if ($installers.Count -ne 1) { throw 'Expected one VB-CABLE x64 installer.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $installers[0].FullName
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:CN|O)=BUREL VINCENT(?: Entrepreneur individuel)?(?:,|$)') { throw 'The driver installer publisher signature could not be verified. Nothing was run.' }
        $process = Start-Process -FilePath $installers[0].FullName -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -notin @(0, 3010)) { throw "Driver installer returned $($process.ExitCode). Check its result before rebooting." }
        return [pscustomobject]@{ Message = 'Driver installer finished. Reboot if it installed the driver, then return to FixAudio.' }
    }
    finally {
        $resolved = [IO.Path]::GetFullPath($directory)
        $safe = (Split-Path -Parent $resolved).TrimEnd('\') -ieq $root -and [IO.Path]::GetFileName($resolved) -match '^FixAudio-driver-[a-f0-9]{32}$'
        $links = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
        if ($safe -and $links.Count -eq 0) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-ControlOperation {
    param([string]$Operation, [string]$Destination, $Request)
    switch ($Operation) {
        'Snapshot' { return Get-ControlSnapshot }
        'Install' { if (-not $Destination) { throw 'Choose an installation folder.' }; return Publish-FixAudio -Destination $Destination -Settings $Request.Settings }
        'Update' { $task = Assert-MaintenanceTask; return Publish-FixAudio -Destination (Get-TaskScriptPath $task) }
        'Options' { $task = Assert-MaintenanceTask; Test-Settings $Request.Settings; return Publish-FixAudio -Destination (Get-TaskScriptPath $task) -Settings $Request.Settings }
        'Restore' { return Restore-FixAudioBackup -BackupPath $Request.BackupPath }
        'Uninstall' { return Uninstall-FixAudio }
        'Pause' { $task = Get-FixAudioTask; if (-not $task) { throw 'FixAudio is not installed.' }; if ((Get-TaskOwnerSid $task) -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'This task belongs to another user.' }; Disable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop | Out-Null; return [pscustomobject]@{ Message = 'Automatic repair paused. Any active repair will finish normally.' } }
        'Resume' { $task = Get-FixAudioTask; if (-not $task) { throw 'FixAudio is not installed.' }; if ((Get-TaskOwnerSid $task) -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'This task belongs to another user.' }; Enable-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop | Out-Null; return [pscustomobject]@{ Message = 'Automatic repair enabled for the configured triggers.' } }
        'Repair' {
            $task = Get-FixAudioTask
            if (-not $task) { throw 'Install FixAudio first.' }
            if ((Get-TaskOwnerSid $task) -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw 'This task belongs to another user.' }
            $scriptPath = Get-TaskScriptPath $task
            $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $scriptPath + '"'
            $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
            if ($process.ExitCode -ne 0) { throw 'Repair finished with failed checks. See the log and Setup guide.' }
            return [pscustomobject]@{ Message = 'Device repair completed. Check your headset and Windows spatial format to confirm the full route.' }
        }
        'Driver' { return Install-VerifiedVBCable }
        default { throw "Unknown operation: $Operation" }
    }
}
