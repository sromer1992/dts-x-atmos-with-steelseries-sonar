# ============================================================================
# FixAudio Setup Wizard
# ============================================================================
# Guided installer for the Sonar + VB-CABLE + DTS/Dolby spatial sound setup.
# Run via Setup.bat (needs administrator rights for driver + scheduled task).
# ============================================================================

#requires -Version 5.1

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$SetupDir          = $PSScriptRoot
$SourceScript      = Join-Path $SetupDir "FixAudio.ps1"
$DefaultInstallDir = Join-Path $env:USERPROFILE "FixAudio"
$TaskName          = "FixAudio"
$AudioModuleVersion = '3.1.0.2'
$PackageVersion = '1.2.1'

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
    $dts = Get-AppxPackage -Name '*DTSSoundUnbound*' -ErrorAction SilentlyContinue
    $dolby = Get-AppxPackage -Name '*DolbyAccess*' -ErrorAction SilentlyContinue
    if ($dts -and $dolby) { return 'DTS + Dolby' }
    if ($dts) { return 'DTS Sound Unbound' }
    if ($dolby) { return 'Dolby Access' }
    return $null
}

function Test-ManualDone {
    Test-Path $StateFile
}

function Get-FixAudioTask {
    # Querying the root folder distinguishes a missing task from an access error.
    $tasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop | Where-Object { $_.TaskName -eq $TaskName })
    if ($tasks.Count -gt 1) { throw 'More than one FixAudio task was found.' }
    if ($tasks.Count -eq 1) { return $tasks[0] }
    return $null
}

function Get-TaskScriptPath {
    param($Task)
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1 -or [IO.Path]::GetFileName($actions[0].Execute) -ine 'powershell.exe' -or
        $actions[0].Arguments -notmatch '(?i)-File\s+"([^"]+)"(?:\s+-Automatic)?\s*$') {
        throw 'The FixAudio task has an unexpected action. Check it in Task Scheduler before updating.'
    }
    $path = $Matches[1]
    if (-not [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetFileName($path) -ine 'FixAudio.ps1') {
        throw 'The FixAudio task does not point to an absolute FixAudio.ps1 path.'
    }
    return [IO.Path]::GetFullPath($path)
}

function Get-TaskOwnerSid {
    param($Task)
    $owner = $Task.Principal.UserId
    if ($owner -like 'S-1-*') { return $owner }
    return (New-Object Security.Principal.NTAccount($owner)).Translate([Security.Principal.SecurityIdentifier]).Value
}

function Get-InstalledTask {
    try {
        $task = Get-FixAudioTask
        if (-not $task) { return $null }
        $path = Get-TaskScriptPath $task
        if ($task.State -eq 'Disabled' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '?' }
        return $path
    }
    catch { return '?' }
}

function Test-Settings {
    param($Settings)
    if ($null -eq $Settings -or $Settings.SetCommunications -isnot [bool] -or
        $Settings.SpatialApp -notin @('Auto', 'DTS', 'Dolby', 'None')) {
        throw 'Invalid FixAudio.config.json. SetCommunications must be true/false; SpatialApp must be Auto, DTS, Dolby, or None.'
    }
    foreach ($name in @('RepairOnUnlock', 'RepairOnResume')) {
        if ($Settings.PSObject.Properties.Name -contains $name -and $Settings.$name -isnot [bool]) { throw "$name must be true or false." }
    }
}

function Get-InstallSettings {
    param([string]$Destination)
    $configPath = Join-Path (Split-Path -Parent $Destination) 'FixAudio.config.json'
    if (Test-Path -LiteralPath $configPath) {
        $settings = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    else {
        $settings = [pscustomobject]@{ SetCommunications = $false; SpatialApp = 'Auto' }
        # Migrate the old inline preference without executing the old script.
        if (Test-Path -LiteralPath $Destination) {
            $oldScript = Get-Content -LiteralPath $Destination -Raw -ErrorAction Stop
            if ($oldScript -match '(?im)^\$SetCommunications\s*=\s*\$(true|false)\b') {
                $settings.SetCommunications = $Matches[1] -ieq 'true'
                if (Get-AppxPackage -Name '*DTSSoundUnbound*' -ErrorAction Stop) { $settings.SpatialApp = 'DTS' }
                elseif (Get-AppxPackage -Name '*DolbyAccess*' -ErrorAction Stop) { $settings.SpatialApp = 'Dolby' }
            }
            if ($oldScript -match '(?im)^\$LaunchSpatialApp\s*=\s*\$false\b') { $settings.SpatialApp = 'None' }
        }
    }
    foreach ($name in @('RepairOnUnlock', 'RepairOnResume')) {
        if ($settings.PSObject.Properties.Name -notcontains $name) { $settings | Add-Member -NotePropertyName $name -NotePropertyValue $false }
    }
    Test-Settings $settings
    return $settings
}

function Initialize-SetupAudioModule {
    if (-not (Get-Module -ListAvailable AudioDeviceCmdlets | Where-Object { $_.Version -eq [version]$AudioModuleVersion })) {
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -ge [version]'2.8.5.201' }
        if (-not $nuget) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        }
        Install-Module -Name AudioDeviceCmdlets -RequiredVersion $AudioModuleVersion -Repository PSGallery `
            -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module AudioDeviceCmdlets -RequiredVersion $AudioModuleVersion -ErrorAction Stop
}

function Publish-FixAudio {
    param([Parameter(Mandatory)][string]$Destination, $Settings)
    $Destination = [IO.Path]::GetFullPath($Destination)
    if ($Destination -ieq [IO.Path]::GetFullPath($SourceScript)) {
        throw 'Choose an installation folder separate from the setup package.'
    }
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($SourceScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw "The source script has syntax errors: $($parseErrors.Message -join '; ')" }
    if (-not $Settings) { $Settings = Get-InstallSettings $Destination }
    Test-Settings $Settings
    $oldTask = Get-FixAudioTask
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($oldTask) {
        if ((Get-TaskScriptPath $oldTask) -ine $Destination) { throw 'Update must use the existing scheduled task path.' }
        if ($oldTask.State -eq 'Running') { throw 'FixAudio is running. Wait for it to finish, then update again.' }
        if ((Get-TaskOwnerSid $oldTask) -ne $userSid) { throw 'The FixAudio task belongs to another Windows account. Run setup as its owner.' }
        $oldTaskXml = Export-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        Assert-TaskWritable $oldTaskXml
    }
    Initialize-SetupAudioModule

    $installDir = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $installDir -Force -ErrorAction Stop | Out-Null
    $configPath = Join-Path $installDir 'FixAudio.config.json'
    $id = [guid]::NewGuid().ToString('N')
    $hadScript = Test-Path -LiteralPath $Destination
    $hadConfig = Test-Path -LiteralPath $configPath
    $backupDir = Save-InstallationSnapshot -Destination $Destination -TaskXml $oldTaskXml

    $stage = Join-Path $installDir ('.FixAudio-' + $id + '.tmp')
    $configStage = Join-Path $installDir ('.FixAudio-config-' + $id + '.tmp')
    $filesTouched = $false; $taskTouched = $false
    try {
        $sourceHash = (Get-FileHash -LiteralPath $SourceScript -Algorithm SHA256 -ErrorAction Stop).Hash
        Copy-Item -LiteralPath $SourceScript -Destination $stage -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $stage -Algorithm SHA256 -ErrorAction Stop).Hash -ne $sourceHash) { throw 'Staged script hash mismatch.' }
        $Settings | ConvertTo-Json | Set-Content -LiteralPath $configStage -Encoding UTF8 -ErrorAction Stop
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Destination`" -Automatic"
        $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $enabled = -not ($oldTask -and $oldTask.State -eq 'Disabled')
        $taskXml = New-FixAudioTaskXml -Destination $Destination -Settings $Settings -Enabled $enabled -UserSid $userSid

        $filesTouched = $true
        if ($hadScript) { [IO.File]::Replace($stage, $Destination, [NullString]::Value) }
        else { Move-Item -LiteralPath $stage -Destination $Destination -ErrorAction Stop }
        if ($hadConfig) { [IO.File]::Replace($configStage, $configPath, [NullString]::Value) }
        else { Move-Item -LiteralPath $configStage -Destination $configPath -ErrorAction Stop }
        $taskTouched = $true
        Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $taskXml -Force -ErrorAction Stop | Out-Null
        $verified = Get-FixAudioTask
        if (-not $verified -or (($verified.State -ne 'Disabled') -ne $enabled) -or (Get-TaskScriptPath $verified) -ine $Destination -or
            $verified.Actions[0].Arguments -cne $arguments -or $verified.Actions[0].Execute -ine $engine -or
            $verified.Settings.ExecutionTimeLimit -ne 'PT6M' -or
            [string]$verified.Settings.MultipleInstances -notin @('IgnoreNew', '2') -or
            [string]$verified.Principal.RunLevel -notin @('Limited', '0') -or
            (Get-TaskOwnerSid $verified) -ne $userSid) { throw 'Scheduled task verification failed.' }
        if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $sourceHash) { throw 'Installed script hash mismatch.' }
        $readback = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        Test-Settings $readback
        if ($readback.SetCommunications -ne $Settings.SetCommunications -or $readback.SpatialApp -ne $Settings.SpatialApp) { throw 'Installed settings verification failed.' }
        foreach ($name in @('RepairOnUnlock', 'RepairOnResume')) { if ([bool]$readback.$name -ne [bool]$Settings.$name) { throw 'Recovery settings verification failed.' } }
        Remove-OldFixAudioBackups -Destination $Destination
        return [pscustomobject]@{ Script = $Destination; SHA256 = $sourceHash; Backup = $backupDir }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = @()
        if ($filesTouched) {
            foreach ($file in @(
                @{ Path = $Destination; Existed = $hadScript; Name = 'FixAudio.ps1' },
                @{ Path = $configPath; Existed = $hadConfig; Name = 'FixAudio.config.json' }
            )) {
                try {
                    if ($file.Existed) { Copy-Item -LiteralPath (Join-Path $backupDir $file.Name) -Destination $file.Path -Force -ErrorAction Stop }
                    elseif (Test-Path -LiteralPath $file.Path) { Remove-Item -LiteralPath $file.Path -Force -ErrorAction Stop }
                }
                catch { $rollbackErrors += $_.Exception.Message }
            }
        }
        if ($taskTouched) {
            try {
                if ($oldTask) { Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $oldTaskXml -Force -ErrorAction Stop | Out-Null }
                elseif (Get-FixAudioTask) { Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop }
            }
            catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count) { throw "$failure Rollback needs attention: $($rollbackErrors -join '; '). Backup: $backupDir" }
        throw "$failure Previous installation restored. Backup: $backupDir"
    }
    finally {
        foreach ($tempFile in @($stage, $configStage)) {
            if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
        }
    }
}

