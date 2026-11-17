#requires -Version 5.1
# No audio settings, installed files, network downloads, or real tasks are changed.
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $PSScriptRoot
$runtimePath = Join-Path $packageRoot 'FixAudio.ps1'
$setupPath = Join-Path $packageRoot 'Setup.ps1'
$script:passed = 0

function Assert-True { param($Value, [string]$Message); if (-not $Value) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '*')
    try { & $Action } catch { if ($_.Exception.Message -like $Pattern) { return }; throw }
    throw 'Expected an exception, but the operation succeeded.'
}
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:passed++
    Write-Host "PASS: $Name"
}

foreach ($path in @($runtimePath, $setupPath)) {
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) "Syntax errors in $path"
}

. $runtimePath
function Write-Log { param($Message, $Level); $script:messages.Add("[$Level] $Message") }
function Start-Sleep { param($Seconds); $script:sleeps++ }
function Get-Process { [CmdletBinding()]param($Name); [pscustomobject]@{ Name = $Name } }
function Get-AudioDevice {
    [CmdletBinding()]param([switch]$List, [switch]$Playback, [switch]$PlaybackCommunication)
    if ($script:queryFailure) { Write-Error 'Simulated endpoint query failure'; return }
    if ($List) { return $script:devices }
    if ($Playback) { return [pscustomobject]@{ ID = $script:playbackID; Name = 'CABLE Input' } }
    if ($PlaybackCommunication) { return [pscustomobject]@{ ID = $script:commsID; Name = 'Voice endpoint' } }
}
function Set-AudioDevice {
    [CmdletBinding()]param($ID, [switch]$DefaultOnly, [switch]$CommunicationOnly)
    $script:setCalls++
    if ($script:failNextSet) { $script:failNextSet = $false; Write-Error 'Simulated first attempt failure'; return }
    if ($script:setFailure) { Write-Error 'Simulated audio setter failure'; return }
    if ($script:ignoreSetter) { return }
    if ($DefaultOnly) { $script:playbackID = $ID }
    if ($CommunicationOnly) { $script:commsID = $ID }
}
function Get-AppxPackage {
    [CmdletBinding()]param($Name)
    if (($Name -like '*DTS*' -and $script:hasDTS) -or ($Name -like '*Dolby*' -and $script:hasDolby)) {
        [pscustomobject]@{ PackageFamilyName = $Name; PackageFullName = $Name }
    }
}
function Start-Process { [CmdletBinding()]param($FilePath); $script:appStarts++ }
function Install-Module { [CmdletBinding()]param($Name); throw 'Runtime attempted a network install.' }
function Reset-Audio {
    $script:messages = New-Object 'System.Collections.Generic.List[string]'
    $script:sleeps = 0; $script:setCalls = 0; $script:appStarts = 0
    $script:setFailure = $false; $script:queryFailure = $false; $script:ignoreSetter = $false
    $script:failNextSet = $false; $script:SpatialAppHandled = $false
    $script:hasDTS = $true; $script:hasDolby = $true
    $script:playbackID = 'cable'; $script:commsID = 'cable'
    $script:SetCommunications = $true
    $script:devices = @(
        [pscustomobject]@{ ID = 'cable'; Type = 'Playback'; Name = 'CABLE Input (VB-Audio Virtual Cable)' },
        [pscustomobject]@{ ID = 'bridge'; Type = 'Recording'; Name = 'CABLE Output (VB-Audio Virtual Cable)' },
        [pscustomobject]@{ ID = 'sonar'; Type = 'Playback'; Name = 'SteelSeries Sonar - Gaming (SteelSeries Sonar Virtual Audio Device)' }
    )
}

Test-Case 'Communications-only drift is repaired during the watch loop' {
    Reset-Audio
    $script:commsID = 'sonar-chat'
    Watch-DefaultDevices (Get-TargetDevice)
    Assert-True ($script:commsID -eq 'cable' -and $script:setCalls -eq 2) 'Communications drift was not repaired exactly once.'
}
Test-Case 'Unmanaged communications routing is preserved' {
    Reset-Audio
    $SetCommunications = $false; $script:commsID = 'sonar-chat'
    Watch-DefaultDevices (Get-TargetDevice)
    Assert-True ($script:setCalls -eq 0 -and $script:commsID -eq 'sonar-chat') 'Voice routing was changed while disabled.'
}
Test-Case 'A missing bridge source fails final checks' {
    Reset-Audio
    $script:devices = @($script:devices | Where-Object { $_.ID -ne 'bridge' })
    Assert-True (-not (Invoke-FinalChecks)) 'Missing bridge incorrectly passed.'
}
Test-Case 'A missing Sonar playback endpoint fails final checks' {
    Reset-Audio
    $script:devices = @($script:devices | Where-Object { $_.ID -ne 'sonar' })
    Assert-True (-not (Invoke-FinalChecks)) 'Missing Sonar endpoint incorrectly passed.'
}
Test-Case 'Correct endpoints pass while routing and spatial format remain unverified' {
    Reset-Audio
    Assert-True (Invoke-FinalChecks) 'Valid defaults/endpoints failed.'
    Assert-True (@($script:messages | Where-Object { $_ -like '*UNVERIFIED*' }).Count -eq 1) 'Unverified routing was not disclosed.'
}
Test-Case 'Endpoint identity is checked even when friendly names match' {
    Reset-Audio
    $script:playbackID = 'other-cable'
    Assert-True (-not (Test-DefaultDevices (Get-TargetDevice))) 'Different endpoint ID passed.'
}
Test-Case 'Similar endpoint names and duplicate endpoints are not silently selected' {
    Reset-Audio
    $script:devices += [pscustomobject]@{ ID = '16ch'; Type = 'Playback'; Name = 'CABLE Input 16ch (VB-Audio)' }
    Assert-True ((Get-TargetDevice).ID -eq 'cable') 'Selected a different cable variant.'
    $script:devices += [pscustomobject]@{ ID = 'duplicate'; Type = 'Playback'; Name = 'CABLE Input (Another driver)' }
    Assert-Throws { Get-TargetDevice } '*Multiple playback*'
}
Test-Case 'Setter errors and failed readback cannot report success' {
    Reset-Audio
    $script:setFailure = $true
    Assert-True (-not (Set-DefaultDevice (Get-TargetDevice))) 'Setter error was ignored.'
    $script:setFailure = $false; $script:ignoreSetter = $true; $script:commsID = 'chat'
    Assert-True (-not (Set-DefaultDevice (Get-TargetDevice))) 'Failed communications readback was ignored.'
}
Test-Case 'Audio query errors propagate to the failure handler' {
    Reset-Audio; $script:queryFailure = $true
    Assert-Throws { Invoke-FinalChecks } '*Simulated endpoint query failure*'
}
Test-Case 'Both spatial apps require an explicit choice in Auto mode' {
    Reset-Audio; $SpatialAppPreference = 'Auto'
    Assert-True ($null -eq (Get-SpatialAppSelection)) 'Auto silently preferred DTS over Dolby.'
}
Test-Case 'Explicit Dolby preference and missing-provider behavior' {
    Reset-Audio; $SpatialAppPreference = 'Dolby'
    Assert-True ((Get-SpatialAppSelection).Label -eq 'Dolby Access') 'Dolby preference was ignored.'
    $script:hasDolby = $false
    Assert-True ($null -eq (Get-SpatialAppSelection)) 'Missing Dolby incorrectly fell back to DTS.'
    $SpatialAppPreference = 'Auto'
    Assert-True ((Get-SpatialAppSelection).Label -eq 'DTS Sound Unbound') 'Auto did not select the only installed app.'
}
Test-Case 'CheckOnly never sets audio, waits for startup, or launches apps' {
    Reset-Audio
    $CheckOnly = $true; $LogFile = $null
    function Import-Module { [CmdletBinding()]param($Name, $RequiredVersion) }
    Assert-True ((Main) -eq 0) 'CheckOnly failed for valid endpoints.'
    Assert-True ($script:setCalls -eq 0 -and $script:sleeps -eq 0 -and $script:appStarts -eq 0) 'CheckOnly performed an audio-changing operation.'
}
Test-Case 'A missing dependency fails without trying an online installation' {
    Reset-Audio
    function Import-Module { [CmdletBinding()]param($Name, $RequiredVersion); throw 'Missing module' }
    Assert-True (-not (Initialize-AudioModule)) 'Missing module did not fail.'
}
Test-Case 'A delayed recovery launches the spatial app exactly once' {
    Reset-Audio
    $script:failNextSet = $true; $script:commsID = 'chat'; $script:launchCount = 0
    function Initialize-AudioModule { $true }
    function Read-Configuration {}
    function Start-SpatialApp { $script:launchCount++ }
    $LogFile = $null; $CheckOnly = $false
    Assert-True ((Main) -eq 0) 'Delayed recovery did not finish successfully.'
    Assert-True ($script:launchCount -eq 1) 'The spatial app was skipped after delayed recovery.'
    $script:commsID = 'chat-again'
    Watch-DefaultDevices (Get-TargetDevice)
    Assert-True ($script:launchCount -eq 1) 'The app was launched more than once during recovery.'
}
Test-Case 'Ready endpoints avoid waiting for the GG frontend' {
    Reset-Audio
    function Get-Process { [CmdletBinding()]param($Name); throw 'Frontend process must not be used for readiness.' }
    Wait-ForSonar
    Assert-True ($script:sleeps -eq 0) 'Ready endpoints still caused a startup delay.'
}
Test-Case 'Endpoint readiness waits for a delayed Sonar endpoint' {
    Reset-Audio
    $script:devices = @($script:devices | Where-Object { $_.ID -ne 'sonar' })
    function Start-Sleep { param($Seconds); $script:sleeps++; $script:devices += [pscustomobject]@{ ID = 'sonar'; Type = 'Playback'; Name = 'SteelSeries Sonar - Gaming' } }
    Wait-ForSonar
    Assert-True ($script:sleeps -eq 1) 'Readiness did not wait for the delayed endpoint.'
}

# Real temporary files exercise deployment and rollback; task/module APIs are mocked.
. $setupPath
function Import-Module { [CmdletBinding()]param($Name, $RequiredVersion) }
function Get-ScheduledTaskInfo { [CmdletBinding()]param($TaskName, $TaskPath); [pscustomobject]@{ LastRunTime = [DateTime]'2026-01-01'; LastTaskResult = 0 } }
$script:testRoot = Join-Path $packageRoot ('.FixAudio-regression-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:testRoot | Out-Null
$script:userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Initialize-SetupAudioModule { if ($script:failure -eq 'Dependency') { throw 'Simulated dependency failure' } }
function Get-ScheduledTask { [CmdletBinding()]param($TaskPath); if ($script:taskState) { $script:taskState } }
function Export-ScheduledTask { [CmdletBinding()]param($TaskName, $TaskPath); '<Task>previous definition</Task>' }
function New-ScheduledTaskAction { [CmdletBinding()]param($Execute, $Argument); [pscustomobject]@{ Execute = $Execute; Arguments = $Argument } }
function New-ScheduledTaskSettingsSet {
    [CmdletBinding()]param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, [switch]$StartWhenAvailable, $MultipleInstances, $ExecutionTimeLimit)
    Assert-True ($ExecutionTimeLimit.TotalMinutes -eq 6 -and $MultipleInstances -eq 'IgnoreNew') 'Task limits were not set.'
    [pscustomobject]@{ ExecutionTimeLimit = 'PT6M'; MultipleInstances = 'IgnoreNew' }
}
function New-ScheduledTaskPrincipal { [CmdletBinding()]param($UserId, $RunLevel, $LogonType); [pscustomobject]@{ UserId = $UserId; RunLevel = $RunLevel } }
function New-ScheduledTaskTrigger { [CmdletBinding()]param([switch]$AtLogOn, $User); [pscustomobject]@{ UserId = $User } }
function Set-ScheduledTask {
    [CmdletBinding()]param($TaskName, $TaskPath, $Action, $Settings, $Principal)
    $script:taskState.Actions = @($Action); $script:taskState.Settings = $Settings; $script:taskState.Principal = $Principal
    if ($script:failure -eq 'Task') { Write-Error 'Simulated task registration failure' }
}
function Enable-ScheduledTask { [CmdletBinding()]param($TaskName, $TaskPath); $script:taskState.State = 'Ready' }
function Register-ScheduledTask {
    [CmdletBinding()]param($TaskName, $TaskPath, $Xml, [switch]$Force, $Description, $Action, $Trigger, $Principal, $Settings)
    if ($script:failure -eq 'Denied') { Write-Error 'Access is denied.'; return }
    if ($Xml -eq '<Task>previous definition</Task>') { $script:taskState = $script:originalTask | ConvertTo-Json -Depth 8 | ConvertFrom-Json; return }
    if ($Xml) {
        [xml]$definition = $Xml
        $script:taskState = [pscustomobject]@{
            TaskName = $TaskName
            Actions = @([pscustomobject]@{ Execute = $definition.Task.Actions.Exec.Command; Arguments = $definition.Task.Actions.Exec.Arguments })
            Settings = [pscustomobject]@{ ExecutionTimeLimit = $definition.Task.Settings.ExecutionTimeLimit; MultipleInstances = $definition.Task.Settings.MultipleInstancesPolicy }
            Principal = [pscustomobject]@{ UserId = $definition.Task.Principals.Principal.UserId; RunLevel = 'Limited' }
            State = if ($definition.Task.Settings.Enabled -eq 'false') { 'Disabled' } else { 'Ready' }
        }
        if ($script:failure -eq 'Task') { Write-Error 'Simulated task registration failure' }
        return
    }
    $script:taskState = [pscustomobject]@{ TaskName = $TaskName; Actions = @($Action); Settings = $Settings; Principal = $Principal; State = 'Ready' }
    if ($script:failure -eq 'Task') { Write-Error 'Simulated task registration failure' }
}
function Unregister-ScheduledTask { [CmdletBinding(SupportsShouldProcess)]param($TaskName, $TaskPath); $script:taskState = $null }
function Copy-Item {
    [CmdletBinding()]param($LiteralPath, $Destination, [switch]$Force)
    if ($script:failure -eq 'Copy' -and $LiteralPath -eq $SourceScript) { Write-Error 'Simulated staged copy failure'; return }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force -ErrorAction Stop
}
function Reset-Deployment {
    $script:failure = ''
    $script:caseDir = Join-Path $script:testRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:caseDir | Out-Null
    $script:destination = Join-Path $script:caseDir 'FixAudio.ps1'
    $script:configFile = Join-Path $script:caseDir 'FixAudio.config.json'
    "`$SetCommunications = `$true`r`n`$LaunchSpatialApp = `$true" | Set-Content -LiteralPath $script:destination
    $script:oldHash = (Get-FileHash -LiteralPath $script:destination).Hash
    $script:taskState = [pscustomobject]@{
        TaskName = 'FixAudio'; State = 'Ready'
        Actions = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = "-File `"$script:destination`"" })
        Principal = [pscustomobject]@{ UserId = $script:userSid; RunLevel = 'Highest' }
        Settings = [pscustomobject]@{ ExecutionTimeLimit = 'PT72H' }
    }
    $script:originalTask = $script:taskState | ConvertTo-Json -Depth 8 | ConvertFrom-Json
}

try {
    Test-Case 'Existing installation updates the discovered path and migrates legacy preferences' {
        Reset-Deployment
        $result = Publish-FixAudio -Destination (Get-TaskScriptPath (Get-FixAudioTask))
        $config = Get-Content -LiteralPath $script:configFile -Raw | ConvertFrom-Json
        Assert-True ($config.SetCommunications -and $config.SpatialApp -eq 'DTS') 'Legacy preferences were not migrated.'
        Assert-True ((Get-FileHash -LiteralPath $script:destination).Hash -eq (Get-FileHash -LiteralPath $SourceScript).Hash) 'Installed copy differs.'
        Assert-True (Test-Path -LiteralPath (Join-Path $result.Backup 'Task.xml')) 'Task backup is missing.'
        Assert-True ($script:taskState.Actions[0].Arguments -like '*-NoProfile -NonInteractive*') 'Task lacks unattended settings.'
    }
    Test-Case 'Updates preserve existing Dolby and communications preferences' {
        Reset-Deployment
        '{"SetCommunications":false,"SpatialApp":"Dolby"}' | Set-Content -LiteralPath $script:configFile
        Publish-FixAudio -Destination $script:destination | Out-Null
        $config = Get-Content -LiteralPath $script:configFile -Raw | ConvertFrom-Json
        Assert-True (-not $config.SetCommunications -and $config.SpatialApp -eq 'Dolby') 'Existing preferences were overwritten.'
    }
    Test-Case 'Failed staged copying leaves the installation and task untouched' {
        Reset-Deployment; $script:failure = 'Copy'
        Assert-Throws { Publish-FixAudio -Destination $script:destination } '*Simulated staged copy failure*'
        Assert-True ((Get-FileHash -LiteralPath $script:destination).Hash -eq $script:oldHash) 'Original script changed after copy failure.'
        Assert-True ($script:taskState.Settings.ExecutionTimeLimit -eq 'PT72H') 'Task changed after copy failure.'
    }
    Test-Case 'Task failure rolls back the script, preferences, and task definition' {
        Reset-Deployment
        '{"SetCommunications":false,"SpatialApp":"Dolby"}' | Set-Content -LiteralPath $script:configFile
        $configHash = (Get-FileHash -LiteralPath $script:configFile).Hash
        $script:failure = 'Task'
        Assert-Throws { Publish-FixAudio -Destination $script:destination } '*Simulated task registration failure*'
        Assert-True ((Get-FileHash -LiteralPath $script:destination).Hash -eq $script:oldHash) 'Original script was not restored.'
        Assert-True ((Get-FileHash -LiteralPath $script:configFile).Hash -eq $configHash) 'Original settings were not restored.'
        Assert-True ($script:taskState.Settings.ExecutionTimeLimit -eq 'PT72H') 'Original task was not restored.'
    }
    Test-Case 'A failed first installation removes only its newly deployed files and task' {
        Reset-Deployment
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:destination
        $script:taskState = $null; $script:failure = 'Task'
        Assert-Throws { Publish-FixAudio -Destination $script:destination } '*Simulated task registration failure*'
        Assert-True (-not (Test-Path -LiteralPath $script:destination) -and -not (Test-Path -LiteralPath $script:configFile)) 'New files remained after rollback.'
        Assert-True ($null -eq $script:taskState) 'New task remained after rollback.'
    }
    Test-Case 'A task that needs administrator rights stops before files or backups change' {
        Reset-Deployment; $script:failure = 'Denied'
        Assert-Throws { Publish-FixAudio -Destination $script:destination } '*administrator rights*nothing was changed*Access is denied*'
        Assert-True ((Get-FileHash -LiteralPath $script:destination).Hash -eq $script:oldHash) 'The script changed without permission to update the task.'
        Assert-True (-not (Test-Path -LiteralPath $script:configFile)) 'Settings were written without permission to update the task.'
        Assert-True (@(Get-ChildItem -LiteralPath $script:caseDir -Force -Filter '.FixAudio-backup-*').Count -eq 0) 'A backup was created for an update that could not run.'
        Assert-True ($script:taskState.Settings.ExecutionTimeLimit -eq 'PT72H') 'The task changed without permission.'
        Assert-Throws { Uninstall-FixAudio } '*administrator rights*nothing was changed*'
        Assert-True ((Test-Path -LiteralPath $script:destination) -and $null -ne $script:taskState) 'Uninstall removed files without permission to remove the task.'
    }
    Test-Case 'Invalid settings and dependency failures stop before deployment' {
        Reset-Deployment
        '{"SetCommunications":"false","SpatialApp":"Dolby"}' | Set-Content -LiteralPath $script:configFile
        Assert-Throws { Publish-FixAudio -Destination $script:destination } '*Invalid FixAudio.config.json*'
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $script:configFile
        $script:failure = 'Dependency'
        Assert-Throws { Publish-FixAudio -Destination $script:destination } '*Simulated dependency failure*'
        Assert-True ((Get-FileHash -LiteralPath $script:destination).Hash -eq $script:oldHash) 'Preflight failure changed the installed script.'
    }
    Test-Case 'A running task is not replaced during an update' {
        Reset-Deployment; $script:taskState.State = 'Running'
        Assert-Throws { Publish-FixAudio -Destination $script:destination } '*FixAudio is running*'
        Assert-True ((Get-FileHash -LiteralPath $script:destination).Hash -eq $script:oldHash) 'Running installation was changed.'
    }
    Test-Case 'Automatic cooldown handles recent, old, and corrupt run-state files' {
        Reset-Deployment
        $RunStatePath = Join-Path $script:caseDir 'last-run.json'
        Save-RunResult -ExitCode 1 -StartedUtc ([DateTime]::UtcNow) -ErrorMessage 'Test failure'
        Assert-True (Test-RecoveryCooldown) 'A recent automatic repair was not throttled.'
        $state = Get-Content -LiteralPath $RunStatePath -Raw | ConvertFrom-Json
        Assert-True ($state.ExitCode -eq 1 -and $state.Error -eq 'Test failure') 'Run outcome was not recorded.'
        $state.CompletedUtc = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
        $state | ConvertTo-Json | Set-Content -LiteralPath $RunStatePath
        Assert-True (-not (Test-RecoveryCooldown)) 'An old run still blocked recovery.'
        'invalid JSON' | Set-Content -LiteralPath $RunStatePath
        Assert-True (-not (Test-RecoveryCooldown)) 'Corrupt run state blocked recovery.'
    }
    Test-Case 'Recovery options produce only the requested user-specific triggers' {
        Reset-Deployment
        $settings = [pscustomobject]@{ SetCommunications = $false; SpatialApp = 'DTS'; RepairOnUnlock = $true; RepairOnResume = $true }
        [xml]$xml = New-FixAudioTaskXml $script:destination $settings $false $script:userSid
        Assert-True ($xml.Task.Triggers.SessionStateChangeTrigger.UserId -eq $script:userSid -and $xml.Task.Triggers.SessionStateChangeTrigger.StateChange -eq 'SessionUnlock') 'Unlock trigger is not scoped correctly.'
        Assert-True ($xml.Task.Triggers.EventTrigger.Subscription -like '*Power-Troubleshooter*EventID=1*') 'Resume trigger query is incorrect.'
        Assert-True ($xml.Task.Settings.Enabled -eq 'false' -and $xml.Task.Actions.Exec.Arguments -like '*-Automatic') 'Paused state or automatic mode was lost.'
        $settings.RepairOnUnlock = $false; $settings.RepairOnResume = $false
        [xml]$disabled = New-FixAudioTaskXml $script:destination $settings $true $script:userSid
        Assert-True ($null -eq $disabled.Task.Triggers.SessionStateChangeTrigger -and $null -eq $disabled.Task.Triggers.EventTrigger) 'Recovery triggers were enabled without opt-in.'
    }
    Test-Case 'Updating a paused task does not silently resume automatic repair' {
        Reset-Deployment; $script:taskState.State = 'Disabled'
        Publish-FixAudio -Destination $script:destination | Out-Null
        Assert-True ($script:taskState.State -eq 'Disabled') 'Update resumed an intentionally paused task.'
    }
    Test-Case 'Optional recovery settings are validated and migrated safely' {
        Reset-Deployment
        $settings = Get-InstallSettings $script:destination
        Assert-True (-not $settings.RepairOnUnlock -and -not $settings.RepairOnResume) 'New recovery options were enabled during migration.'
        $settings.RepairOnResume = 'false'
        Assert-Throws { Test-Settings $settings } '*RepairOnResume must be true or false*'
    }
    Test-Case 'A valid backup can restore the previous script and options' {
        Reset-Deployment
        '{"SetCommunications":false,"SpatialApp":"Dolby"}' | Set-Content -LiteralPath $script:configFile
        $oldConfigHash = (Get-FileHash -LiteralPath $script:configFile).Hash
        $settings = Get-InstallSettings $script:destination
        $backup = Save-InstallationSnapshot $script:destination (New-FixAudioTaskXml $script:destination $settings $true $script:userSid)
        Publish-FixAudio -Destination $script:destination | Out-Null
        Restore-FixAudioBackup $backup | Out-Null
        Assert-True ((Get-FileHash -LiteralPath $script:destination).Hash -eq $script:oldHash) 'The prior script was not restored.'
        Assert-True ((Get-FileHash -LiteralPath $script:configFile).Hash -eq $oldConfigHash) 'The prior preferences were not restored.'
    }
    Test-Case 'A modified backup is rejected before changing the installation' {
        Reset-Deployment
        $backup = Save-InstallationSnapshot $script:destination (New-FixAudioTaskXml $script:destination (Get-InstallSettings $script:destination) $true $script:userSid)
        '# Modified backup' | Add-Content -LiteralPath (Join-Path $backup 'FixAudio.ps1')
        Assert-Throws { Restore-FixAudioBackup $backup } '*Backup checksum verification failed*'
        Assert-True ((Get-FileHash -LiteralPath $script:destination).Hash -eq $script:oldHash) 'A rejected backup changed the installation.'
    }
    Test-Case 'An incomplete backup checksum manifest is rejected' {
        Reset-Deployment
        $backup = Save-InstallationSnapshot $script:destination (New-FixAudioTaskXml $script:destination (Get-InstallSettings $script:destination) $true $script:userSid)
        '{"Files":{}}' | Set-Content -LiteralPath (Join-Path $backup 'backup-manifest.json')
        Assert-Throws { Restore-FixAudioBackup $backup } '*Backup checksum manifest is incomplete*'
    }
    Test-Case 'Backup paths outside the installation are rejected' {
        Reset-Deployment
        Assert-Throws { Assert-BackupPath $script:destination $script:testRoot } '*Backup must be a FixAudio backup*'
    }
    Test-Case 'Backup retention keeps the newest three and preserves unexpected files' {
        Reset-Deployment
        $backups = @()
        foreach ($i in 0..4) {
            $backup = Save-InstallationSnapshot $script:destination ''
            (Get-Item -LiteralPath $backup).CreationTimeUtc = [DateTime]::UtcNow.AddMinutes(-$i)
            $backups += $backup
        }
        Remove-OldFixAudioBackups $script:destination
        Assert-True (@(Get-FixAudioBackups $script:destination).Count -eq 3) 'Retention did not keep three backups.'
        Assert-True ((Test-Path -LiteralPath $backups[0]) -and -not (Test-Path -LiteralPath $backups[4])) 'Retention removed the wrong backup.'
        'Personal file' | Set-Content -LiteralPath (Join-Path $backups[2] 'keep-me.txt')
        Remove-OldFixAudioBackups $script:destination -Keep 1
        Assert-True (Test-Path -LiteralPath (Join-Path $backups[2] 'keep-me.txt')) 'Cleanup removed an unexpected user file.'
    }
    Test-Case 'Uninstall removes only the managed files and task' {
        Reset-Deployment
        '{"SetCommunications":false,"SpatialApp":"Dolby"}' | Set-Content -LiteralPath $script:configFile
        $personal = Join-Path $script:caseDir 'personal-document.txt'; 'Keep' | Set-Content -LiteralPath $personal
        $result = Uninstall-FixAudio
        Assert-True ($null -eq $script:taskState -and -not (Test-Path -LiteralPath $script:destination) -and -not (Test-Path -LiteralPath $script:configFile)) 'Managed files/task were not removed.'
        Assert-True ((Test-Path -LiteralPath $personal) -and (Test-Path -LiteralPath $result.Backup)) 'Uninstall removed unrelated files or backups.'
    }
    Test-Case 'Diagnostic reports redact local account and machine details' {
        $snapshot = [pscustomobject]@{ Version = 'test'; InstalledVersion = 'test'; TaskState = 'Ready'; LastTaskRun = ''; LastTaskResult = ''; Playback = ''; Communications = ''; Settings = @{}; Checks = @(); ManualChecks = 'Unverified'; Log = @("$env:USERPROFILE\FixAudio.ps1 on $env:COMPUTERNAME for $env:USERNAME") }
        $report = Get-DiagnosticReport $snapshot
        Assert-True (-not $report.Contains($env:USERPROFILE) -and -not $report.Contains($env:COMPUTERNAME) -and -not $report.Contains($env:USERNAME)) 'Diagnostic redaction missed identifying text.'
    }
    Test-Case 'The selected spatial provider must actually be installed' {
        Reset-Deployment; Reset-Audio
        '{"SetCommunications":false,"SpatialApp":"Dolby"}' | Set-Content -LiteralPath $script:configFile
        $script:hasDolby = $false
        $snapshot = Get-ControlSnapshot
        $provider = @($snapshot.Checks | Where-Object { $_.Name -eq 'Spatial app' })[0]
        Assert-True ($provider.State -eq 'Attention') 'A missing selected provider was reported as available.'
    }
    Test-Case 'An unrecognized driver archive is rejected without executing it' {
        Reset-Deployment
        $archive = Join-Path $script:caseDir 'not-the-driver.zip'; 'Invalid archive' | Set-Content -LiteralPath $archive
        Assert-Throws { Test-DriverArchive $archive } '*archive checksum does not match*'
    }
}
finally {
    # The only recursive deletion is this generated test directory, verified
    # against the resolved package root before removal.
    $resolvedRoot = [IO.Path]::GetFullPath($script:testRoot)
    $allowedRoot = [IO.Path]::GetFullPath($packageRoot).TrimEnd('\') + '\'
    if ($resolvedRoot.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot) -like '.FixAudio-regression-*') {
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
Write-Host "$script:passed regression cases passed under PowerShell $($PSVersionTable.PSVersion)."
