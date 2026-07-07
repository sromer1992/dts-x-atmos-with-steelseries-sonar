# ============================================================================
# FixAudio.ps1 - SteelSeries Sonar + VB-CABLE + DTS Headphone:X Fix
# ============================================================================
# Sets CABLE Input as default playback/comms device on login, retries if Sonar
# steals the default, and launches DTS Sound Unbound to re-assert spatial sound.
#
# Usage: Run via Task Scheduler at logon with highest privileges
#   Action:  powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\Sean\Documents\FixAudio.ps1"
# ============================================================================

# -- CONFIGURATION --
$PlaybackDeviceName   = "CABLE Input"
$SonarProcessName     = "SteelSeriesGG"
$MaxWaitSeconds       = 120
$PollIntervalSeconds  = 3
$DevicePollSeconds    = 30
$RetryDelaySeconds    = 20
$RetryCount           = 6                                      # 6 x 20s = watches for ~2 minutes after login
$LogFile              = "$env:USERPROFILE\FixAudio.log"
$LogMaxKB             = 256                                    # Trim log at startup if larger than this

# DTS Sound Unbound launch (re-asserts spatial sound on the default endpoint)
$LaunchDTS            = $true
$DTSAppIdFallback     = "DTSInc.DTSSoundUnbound_t5j2fzbtdg37r!App"

# ============================================================================
# LOGGING
# ============================================================================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry -ForegroundColor Cyan }
    }

    if ($LogFile) {
        $entry | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

# ============================================================================
# MODULE CHECK
# ============================================================================
function Initialize-AudioModule {
    if (-not (Get-Module -ListAvailable -Name AudioDeviceCmdlets)) {
        Write-Log "AudioDeviceCmdlets module not found. Installing..." "WARN"
        try {
            Install-Module -Name AudioDeviceCmdlets -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
            Write-Log "AudioDeviceCmdlets installed successfully." "SUCCESS"
        }
        catch {
            Write-Log "Failed to install AudioDeviceCmdlets: $_" "ERROR"
            return $false
        }
    }
    try {
        Import-Module AudioDeviceCmdlets -ErrorAction Stop
        Write-Log "AudioDeviceCmdlets module loaded."
        return $true
    }
    catch {
        Write-Log "Failed to import AudioDeviceCmdlets: $_" "ERROR"
        return $false
    }
}

# ============================================================================
# WAIT FOR SONAR
# ============================================================================
function Wait-ForSonar {
    Write-Log "Waiting for SteelSeries GG/Sonar to start (max ${MaxWaitSeconds}s)..."
    $elapsed = 0

    while ($elapsed -lt $MaxWaitSeconds) {
        $proc = Get-Process -Name $SonarProcessName -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Log "SteelSeries GG detected (PID: $($proc.Id))." "SUCCESS"
            return $true
        }
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }

    Write-Log "Timed out waiting for SteelSeries GG after ${MaxWaitSeconds}s." "WARN"
    return $false
}

# ============================================================================
# WAIT FOR DEVICE
# ============================================================================
function Wait-ForDevice {
    param([string]$DeviceName)

    Write-Log "Polling for '$DeviceName' to appear (max ${DevicePollSeconds}s)..."
    $elapsed = 0

    while ($elapsed -lt $DevicePollSeconds) {
        $found = Get-AudioDevice -List | Where-Object { $_.Name -like "*$DeviceName*" }
        if ($found) {
            Write-Log "Device '$DeviceName' is now available." "SUCCESS"
            return
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
    }

    Write-Log "Timed out waiting for '$DeviceName'. Proceeding anyway." "WARN"
}

# ============================================================================
# SET DEFAULT DEVICE
# ============================================================================
function Set-DefaultDevice {
    param([string]$DeviceName)

    $target = Get-AudioDevice -List |
              Where-Object { $_.Type -eq "Playback" -and $_.Name -like "*$DeviceName*" } |
              Select-Object -First 1

    if (-not $target) {
        Write-Log "Could not find playback device matching '$DeviceName'" "ERROR"
        return $false
    }

    Write-Log "Found device: $($target.Name) (Index: $($target.Index))"

    try {
        Set-AudioDevice -Index $target.Index -DefaultOnly | Out-Null
        Write-Log "Set as Default Playback Device." "SUCCESS"
    }
    catch {
        Write-Log "Failed to set default playback: $_" "ERROR"
        return $false
    }

    try {
        Set-AudioDevice -Index $target.Index -CommunicationOnly | Out-Null
        Write-Log "Set as Default Communication Device." "SUCCESS"
    }
    catch {
        Write-Log "Failed to set default comms device: $_" "ERROR"
    }

    Start-Sleep -Seconds 1
    $currentDefault = Get-AudioDevice -Playback
    if ($currentDefault.Name -like "*$DeviceName*") {
        Write-Log "Verified: default playback is now '$($currentDefault.Name)'" "SUCCESS"
        return $true
    }

    Write-Log "Verification FAILED: default is '$($currentDefault.Name)'" "ERROR"
    return $false
}

# ============================================================================
# LAUNCH DTS SOUND UNBOUND
# ============================================================================
function Start-DTSSoundUnbound {
    if (-not $LaunchDTS) { return }

    Write-Log "Launching DTS Sound Unbound to re-assert spatial sound..."

    try {
        $dtsProc = Get-Process -Name "DTSSoundUnbound*" -ErrorAction SilentlyContinue
        if ($dtsProc) {
            Write-Log "DTS Sound Unbound is already running (PID: $($dtsProc.Id))." "SUCCESS"
            return
        }

        $appId = $null
        $dtsPackage = Get-AppxPackage -Name "*DTSSoundUnbound*" -ErrorAction SilentlyContinue
        if (-not $dtsPackage) {
            $dtsPackage = Get-AppxPackage -Name "*DTS*" -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -like "*Sound*" -or $_.Name -like "*Unbound*" } |
                          Select-Object -First 1
        }

        if ($dtsPackage) {
            $appId = "$($dtsPackage.PackageFamilyName)!App"
            Write-Log "Found DTS package: $($dtsPackage.Name)"
        }
        else {
            Write-Log "DTS package not found via Get-AppxPackage. Using fallback App ID." "WARN"
            $appId = $DTSAppIdFallback
        }

        Start-Process "shell:AppsFolder\$appId" -ErrorAction Stop
        Write-Log "DTS Sound Unbound launched." "SUCCESS"

        Start-Sleep -Seconds 5

        $dtsProc = Get-Process -Name "DTSSoundUnbound*" -ErrorAction SilentlyContinue
        if ($dtsProc) {
            $dtsProc | ForEach-Object { $_.CloseMainWindow() | Out-Null }
            Start-Sleep -Seconds 2
            $dtsProc = Get-Process -Name "DTSSoundUnbound*" -ErrorAction SilentlyContinue
            if ($dtsProc) {
                $dtsProc | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Write-Log "DTS Sound Unbound closed." "SUCCESS"
        }
    }
    catch {
        Write-Log "Failed to launch DTS Sound Unbound: $_" "WARN"
    }
}

# ============================================================================
# MAIN
# ============================================================================
function Main {
    # Trim log if it has grown too large (keep the most recent half)
    if ($LogFile -and (Test-Path $LogFile)) {
        $sizeKB = (Get-Item $LogFile).Length / 1KB
        if ($sizeKB -gt $LogMaxKB) {
            $lines = Get-Content $LogFile
            $lines[[int]($lines.Count / 2)..($lines.Count - 1)] | Set-Content $LogFile -Encoding UTF8
        }
    }

    Write-Log "=========================================="
    Write-Log "FixAudio.ps1 starting"
    Write-Log "=========================================="

    Wait-ForSonar

    if (-not (Initialize-AudioModule)) {
        Write-Log "Cannot continue without AudioDeviceCmdlets. Exiting." "ERROR"
        Start-Sleep -Seconds 5
        [Environment]::Exit(1)
    }

    Wait-ForDevice -DeviceName $PlaybackDeviceName

    Set-DefaultDevice -DeviceName $PlaybackDeviceName | Out-Null

    # Watch the default for a while after login -- Sonar can steal it late
    Write-Log "Watching default device for $($RetryCount * $RetryDelaySeconds)s in case Sonar changes it..."
    for ($i = 1; $i -le $RetryCount; $i++) {
        Start-Sleep -Seconds $RetryDelaySeconds

        $currentDefault = Get-AudioDevice -Playback
        if ($currentDefault.Name -like "*$PlaybackDeviceName*") {
            Write-Log "Watch pass ${i}/${RetryCount}: default still '$($currentDefault.Name)'."
        }
        else {
            Write-Log "Watch pass ${i}/${RetryCount}: Sonar stole default! Current: '$($currentDefault.Name)'. Reclaiming..." "WARN"
            Set-DefaultDevice -DeviceName $PlaybackDeviceName | Out-Null
        }
    }

    Start-DTSSoundUnbound

    Write-Log "=========================================="
    $finalDefault = Get-AudioDevice -Playback
    if ($finalDefault.Name -like "*$PlaybackDeviceName*") {
        Write-Log "FixAudio completed. Default: '$($finalDefault.Name)'" "SUCCESS"
    }
    else {
        Write-Log "FixAudio completed but default is '$($finalDefault.Name)'." "WARN"
    }
    Write-Log "=========================================="

    Start-Sleep -Seconds 2
    [Environment]::Exit(0)
}

Main
