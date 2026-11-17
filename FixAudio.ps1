#requires -Version 5.1
<#
Keeps VB-CABLE selected during Sonar startup. Dependencies are installed by Setup.
Use -CheckOnly to inspect defaults and endpoints without changing audio or opening apps.
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$Automatic,
    [string]$LogPath = "$env:USERPROFILE\FixAudio.log"
)

$ScriptVersion = '1.2.1'
$AudioModuleVersion = '3.1.0.2'
$PlaybackDeviceName = 'CABLE Input'
$ListenSourceName = 'CABLE Output'
$SonarPlaybackDeviceName = 'SteelSeries Sonar - Gaming'
$SonarProcessName = 'SteelSeriesGG'
$SetCommunications = $false
$SpatialAppPreference = 'Auto'
$MaxWaitSeconds = 120
$PollIntervalSeconds = 3
$DevicePollSeconds = 30
$RetryDelaySeconds = 20
$RetryCount = 6
$LogFile = $LogPath
$LogMaxKB = 256
$ConfigPath = Join-Path $PSScriptRoot 'FixAudio.config.json'
$RecoveryCooldownSeconds = 120
$RunStatePath = Join-Path $env:LOCALAPPDATA 'FixAudio\last-run.json'
$script:SpatialAppHandled = $false

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $entry
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8 -ErrorAction Stop }
}

function Read-Configuration {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $config -or $config.SetCommunications -isnot [bool] -or
        $config.SpatialApp -notin @('Auto', 'DTS', 'Dolby', 'None')) {
        throw "Invalid settings in '$ConfigPath'. Expected SetCommunications (true/false) and SpatialApp (Auto/DTS/Dolby/None)."
    }
    $script:SetCommunications = $config.SetCommunications
    $script:SpatialAppPreference = $config.SpatialApp
}

function Initialize-AudioModule {
    try {
        Import-Module AudioDeviceCmdlets -RequiredVersion $AudioModuleVersion -ErrorAction Stop
        Write-Log "AudioDeviceCmdlets $AudioModuleVersion loaded."
        return $true
    }
    catch {
        Write-Log "AudioDeviceCmdlets $AudioModuleVersion unavailable: $_. Run Setup.bat to install or repair it; login never downloads dependencies." 'ERROR'
        return $false
    }
}

function Test-EndpointName {
    param([string]$Name, [string]$Expected)
    return ($Name -ieq $Expected -or $Name.StartsWith($Expected + ' (', [StringComparison]::OrdinalIgnoreCase))
}

function Get-TargetDevice {
    $targets = @(Get-AudioDevice -List -ErrorAction Stop | Where-Object {
        $_.Type -eq 'Playback' -and (Test-EndpointName $_.Name $PlaybackDeviceName)
    })
    if ($targets.Count -gt 1) { throw "Multiple playback endpoints match '$PlaybackDeviceName'. Rename or disable duplicates before running FixAudio." }
    if ($targets.Count -eq 1) { return $targets[0] }
    return $null
}

function Wait-ForSonar {
    Write-Log "Waiting for CABLE and Sonar audio endpoints (max ${MaxWaitSeconds}s)..."
    for ($elapsed = 0; $elapsed -lt $MaxWaitSeconds; $elapsed += $PollIntervalSeconds) {
        $devices = @(Get-AudioDevice -List -ErrorAction Stop)
        $cable = @($devices | Where-Object { $_.Type -eq 'Playback' -and (Test-EndpointName $_.Name $PlaybackDeviceName) })
        $bridge = @($devices | Where-Object { $_.Type -eq 'Recording' -and (Test-EndpointName $_.Name $ListenSourceName) })
        $sonar = @($devices | Where-Object { $_.Type -eq 'Playback' -and (Test-EndpointName $_.Name $SonarPlaybackDeviceName) })
        if ($cable.Count -gt 0 -and $bridge.Count -gt 0 -and $sonar.Count -gt 0) { return }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    Write-Log 'Required endpoints did not all become ready. Attempting repair; final checks will identify missing endpoints.' 'WARN'
}

function Wait-ForDevice {
    Write-Log "Waiting for '$PlaybackDeviceName' (max ${DevicePollSeconds}s)..."
    for ($elapsed = 0; $elapsed -lt $DevicePollSeconds; $elapsed += 2) {
        $device = Get-TargetDevice
        if ($device) { return $device }
        Start-Sleep -Seconds 2
    }
    throw "Playback endpoint '$PlaybackDeviceName' is unavailable. Check the VB-CABLE installation."
}

function Test-DefaultDevices {
    param($Target)
    $playback = Get-AudioDevice -Playback -ErrorAction Stop
    $playbackOK = $playback -and $playback.ID -eq $Target.ID
    $commsOK = $true
    if ($SetCommunications) {
        $comms = Get-AudioDevice -PlaybackCommunication -ErrorAction Stop
        $commsOK = $comms -and $comms.ID -eq $Target.ID
    }
    return ($playbackOK -and $commsOK)
}

function Set-DefaultDevice {
    param($Target)
    try {
        # Endpoint IDs remain stable when enumeration indexes change.
        Set-AudioDevice -ID $Target.ID -DefaultOnly -ErrorAction Stop | Out-Null
        if ($SetCommunications) {
            Set-AudioDevice -ID $Target.ID -CommunicationOnly -ErrorAction Stop | Out-Null
        }
        Start-Sleep -Seconds 1
        if (-not (Test-DefaultDevices $Target)) { throw 'Default device readback did not match the requested endpoint.' }
        Write-Log "Verified requested defaults: '$($Target.Name)'." 'SUCCESS'
        return $true
    }
    catch {
        Write-Log "Could not set/verify defaults: $_" 'ERROR'
        return $false
    }
}

function Watch-DefaultDevices {
    param($Target)
    Write-Log "Watching requested playback/communications defaults for $($RetryCount * $RetryDelaySeconds)s..."
    for ($i = 1; $i -le $RetryCount; $i++) {
        Start-Sleep -Seconds $RetryDelaySeconds
        try {
            if (Test-DefaultDevices $Target) {
                Write-Log "Watch pass ${i}/${RetryCount}: requested defaults are unchanged."
            }
            else {
                Write-Log "Watch pass ${i}/${RetryCount}: a requested default changed; reclaiming it." 'WARN'
                if (Set-DefaultDevice $Target) { Invoke-SpatialAppOnce }
            }
        }
        catch { Write-Log "Watch pass ${i}/${RetryCount}: audio query failed: $_" 'WARN' }
    }
}

function Invoke-SpatialAppOnce {
    if (-not $script:SpatialAppHandled) {
        $script:SpatialAppHandled = $true
        Start-SpatialApp
    }
}

function Test-RecoveryCooldown {
    if (-not (Test-Path -LiteralPath $RunStatePath)) { return $false }
    try {
        $last = Get-Content -LiteralPath $RunStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $age = ([DateTime]::UtcNow - [DateTime]::Parse($last.CompletedUtc).ToUniversalTime()).TotalSeconds
        return ($age -ge 0 -and $age -lt $RecoveryCooldownSeconds)
    }
    catch { return $false }
}

function Save-RunResult {
    param([int]$ExitCode, [DateTime]$StartedUtc, [string]$ErrorMessage = '')
    $parent = Split-Path -Parent $RunStatePath
    New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    $temporary = $RunStatePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [pscustomobject]@{ Version = $ScriptVersion; StartedUtc = $StartedUtc.ToString('o'); CompletedUtc = [DateTime]::UtcNow.ToString('o'); ExitCode = $ExitCode; Error = $ErrorMessage; Automatic = [bool]$Automatic } |
            ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        if (Test-Path -LiteralPath $RunStatePath) { [IO.File]::Replace($temporary, $RunStatePath, [NullString]::Value) }
        else { Move-Item -LiteralPath $temporary -Destination $RunStatePath -ErrorAction Stop }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue } }
}

function Get-SpatialAppSelection {
    if ($SpatialAppPreference -eq 'None') { return $null }
    $candidates = @(
        @{ Key = 'DTS'; Label = 'DTS Sound Unbound'; PkgLike = '*DTSSoundUnbound*'; Proc = 'DTSSoundUnbound*' },
        @{ Key = 'Dolby'; Label = 'Dolby Access'; PkgLike = '*DolbyAccess*'; Proc = 'DolbyAccess*' }
    )
    if ($SpatialAppPreference -ne 'Auto') {
        $candidates = @($candidates | Where-Object { $_.Key -eq $SpatialAppPreference })
    }
    $installed = @(foreach ($candidate in $candidates) {
        $pkg = Get-AppxPackage -Name $candidate.PkgLike -ErrorAction Stop | Select-Object -First 1
        if ($pkg) { @{ Label = $candidate.Label; Package = $pkg; Proc = $candidate.Proc } }
    })
    if ($installed.Count -gt 1) {
        Write-Log "Both spatial apps are installed. Choose DTS or Dolby in '$ConfigPath'; no app was selected automatically." 'WARN'
        return $null
    }
    if ($installed.Count -eq 0) {
        Write-Log "No installed spatial app matches '$SpatialAppPreference'. Check setup and Windows Spatial sound settings." 'WARN'
        return $null
    }
    return $installed[0]
}

function Get-SpatialWindowHandle {
    # Return visible top-level windows titled exactly $Title. DTS Sound Unbound and Dolby Access
    # are packaged (UWP) apps whose window is an ApplicationFrameWindow owned by ApplicationFrameHost.exe,
    # so the title bar -- not the app's own process -- is the reliable way to find the window. The
    # exact title and window class keep a browser tab or folder that mentions the app from matching.
    param([string]$Title)
    if (-not ([System.Management.Automation.PSTypeName]'FixAudio.AppWindow').Type) {
        Add-Type -ErrorAction Stop -Namespace FixAudio -Name AppWindow -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumProc lpEnumFunc, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowTextLength(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool PostMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
'@
    }
    $script:spatialHandles = New-Object 'System.Collections.Generic.List[System.IntPtr]'
    $enum = [FixAudio.AppWindow+EnumProc] {
        param([System.IntPtr]$hWnd, [System.IntPtr]$lParam)
        if ([FixAudio.AppWindow]::IsWindowVisible($hWnd)) {
            $length = [FixAudio.AppWindow]::GetWindowTextLength($hWnd)
            if ($length -gt 0) {
                $builder = New-Object System.Text.StringBuilder ($length + 1)
                [void][FixAudio.AppWindow]::GetWindowText($hWnd, $builder, $builder.Capacity)
                if ($builder.ToString() -ceq $Title) {
                    $class = New-Object System.Text.StringBuilder 64
                    [void][FixAudio.AppWindow]::GetClassName($hWnd, $class, $class.Capacity)
                    if ($class.ToString() -ceq 'ApplicationFrameWindow') { $script:spatialHandles.Add($hWnd) }
                }
            }
        }
        return $true
    }
    [void][FixAudio.AppWindow]::EnumWindows($enum, [System.IntPtr]::Zero)
    return @($script:spatialHandles)
}

function Close-SpatialAppWindow {
    # Wait for the spatial app's window to actually appear (a cold UWP start can take well over
    # 5 seconds), then ask it to close gracefully with WM_CLOSE. Never force-kill an application.
    param([string]$Title)
    $wmClose = [uint32]0x0010
    $deadline = (Get-Date).AddSeconds(20)
    $handles = @()
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $handles = @(Get-SpatialWindowHandle -Title $Title)
        if ($handles.Count -gt 0) {
            foreach ($handle in $handles) { [void][FixAudio.AppWindow]::PostMessage($handle, $wmClose, [System.IntPtr]::Zero, [System.IntPtr]::Zero) }
            break
        }
    }
    if ($handles.Count -eq 0) {
        Write-Log "$Title window did not appear within 20s; nothing to close."
        return
    }
    # Give the window a moment to disappear, then retry the graceful close once if it lingers.
    Start-Sleep -Seconds 2
    $remaining = @(Get-SpatialWindowHandle -Title $Title)
    foreach ($handle in $remaining) { [void][FixAudio.AppWindow]::PostMessage($handle, $wmClose, [System.IntPtr]::Zero, [System.IntPtr]::Zero) }
    if ($remaining.Count -gt 0) {
        Write-Log "$Title did not close its window on request; close it manually if it stays open." 'WARN'
    }
    else {
        Write-Log "$Title window closed; its spatial processing stays registered with Windows."
    }
}

function Start-SpatialApp {
    try {
        $app = Get-SpatialAppSelection
        if (-not $app) { return }
        if (Get-Process -Name $app.Proc -ErrorAction SilentlyContinue) {
            Write-Log "$($app.Label) is already running. Spatial format remains unverified."
            return
        }
        $manifest = Get-AppxPackageManifest -Package $app.Package.PackageFullName -ErrorAction Stop
        $appId = @($manifest.Package.Applications.Application)[0].Id
        if (-not $appId) { throw 'The package has no launchable application ID.' }
        $aumid = "$($app.Package.PackageFamilyName)!$appId"
        Start-Process -FilePath "shell:AppsFolder\$aumid" -ErrorAction Stop
        Write-Log "$($app.Label) launch requested. This does not verify or select the Windows spatial format."
        # Nudging the app registers its spatial processing with Windows; its window does not need
        # to stay open. Close it by its title (see Close-SpatialAppWindow) -- closing by the app's
        # own process handle fails for these UWP apps because their window lives on another process.
        try { Close-SpatialAppWindow -Title $app.Label }
        catch { Write-Log "Could not close the $($app.Label) window automatically: $_" 'WARN' }
    }
    catch { Write-Log "Spatial app launch failed: $_" 'WARN' }
}

function Invoke-FinalChecks {
    param($Target)
    $fail = 0
    Write-Log 'Running final checks...'
    if (-not $Target) { $Target = Get-TargetDevice }
    if ($Target -and (Test-DefaultDevices $Target)) {
        Write-Log 'Requested Windows defaults match CABLE Input.' 'SUCCESS'
    }
    else { Write-Log 'One or more requested Windows defaults do not match CABLE Input.' 'ERROR'; $fail++ }
    $devices = @(Get-AudioDevice -List -ErrorAction Stop)
    $bridge = @($devices | Where-Object { $_.Type -eq 'Recording' -and (Test-EndpointName $_.Name $ListenSourceName) })
    $sonar = @($devices | Where-Object { $_.Type -eq 'Playback' -and (Test-EndpointName $_.Name $SonarPlaybackDeviceName) })
    foreach ($check in @(
        @{ Found = $bridge.Count -gt 0; Name = $ListenSourceName },
        @{ Found = $sonar.Count -gt 0; Name = $SonarPlaybackDeviceName }
    )) {
        if ($check.Found) { Write-Log "Required endpoint '$($check.Name)' is present." 'SUCCESS' }
        else { Write-Log "Required endpoint '$($check.Name)' is missing or disabled." 'ERROR'; $fail++ }
    }
    if (-not (Get-Process -Name $SonarProcessName -ErrorAction SilentlyContinue)) {
        Write-Log 'GG is not running. Endpoint presence alone does not confirm Sonar is processing audio.' 'WARN'
    }
    Write-Log 'UNVERIFIED: Listen routing, headset output, and active DTS/Atmos format. Check these in Windows/GG and listen to a test sound.' 'WARN'
    Write-Log "Final checks: $fail required checks failed."
    return ($fail -eq 0)
}

function Main {
    $script:SpatialAppHandled = $false
    if ($LogFile -and (Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt ($LogMaxKB * 1KB)) {
        $lines = @(Get-Content -LiteralPath $LogFile -ErrorAction Stop)
        $lines | Select-Object -Last ([Math]::Max(1, [int]($lines.Count / 2))) |
            Set-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction Stop
    }
    Read-Configuration
    $hash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'FixAudio.ps1') -Algorithm SHA256 -ErrorAction Stop).Hash
    Write-Log "FixAudio $ScriptVersion starting; SHA256=$hash; CheckOnly=$CheckOnly; SetCommunications=$SetCommunications; SpatialApp=$SpatialAppPreference"
    if (-not (Initialize-AudioModule)) { return 1 }
    if ($CheckOnly) {
        if (Invoke-FinalChecks) { return 0 }
        return 1
    }
    Wait-ForSonar
    $target = Wait-ForDevice
    if (Set-DefaultDevice $target) { Invoke-SpatialAppOnce }
    Watch-DefaultDevices $target
    if (Invoke-FinalChecks $target) {
        Write-Log 'Completed: requested defaults and required endpoints verified. Routing and spatial format still require manual confirmation.' 'SUCCESS'
        return 0
    }
    Write-Log 'Completed with failures. Review the ERROR entries above.' 'ERROR'
    return 1
}

if ($MyInvocation.InvocationName -ne '.') {
    $mutex = $null; $ownsMutex = $false
    $startedUtc = [DateTime]::UtcNow
    $exitCode = 1; $errorMessage = ''; $recordResult = $false
    try {
        if (-not $CheckOnly) {
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $mutex = New-Object Threading.Mutex($false, "Local\FixAudio-$sid")
            try { $ownsMutex = $mutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
            if (-not $ownsMutex) { Write-Log 'Another FixAudio repair is already running. Skipping.'; $exitCode = 0 }
            elseif ($Automatic -and (Test-RecoveryCooldown)) { Write-Log 'Automatic repair skipped during the two-minute cooldown.'; $exitCode = 0 }
            else { $recordResult = $true; $exitCode = Main }
        }
        else { $exitCode = Main }
    }
    catch {
        $errorMessage = $_.Exception.Message
        try { Write-Log "FixAudio failed: $_" 'ERROR' }
        catch { Write-Error "FixAudio failed and could not write its log: $_" }
    }
    finally {
        if ($recordResult) {
            try { Save-RunResult -ExitCode $exitCode -StartedUtc $startedUtc -ErrorMessage $errorMessage }
            catch { Write-Warning "Could not record the last run result: $_" }
        }
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
    exit $exitCode
}
