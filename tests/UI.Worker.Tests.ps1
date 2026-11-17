#requires -Version 5.1
# Test the real worker protocol using only read-only Snapshot operations.
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $packageRoot 'Setup.ps1')
. (Join-Path $packageRoot 'FixAudio.UI.ps1')
$script:ui = @{
    Job = $null; Snapshot = $null
    Footer = New-Object Windows.Forms.Label
    Progress = New-Object Windows.Forms.ProgressBar
    ActionButtons = @((New-Object Windows.Forms.Button))
}
function Set-UiSnapshot { param($Snapshot); $script:ui.Snapshot = $Snapshot }
try {
    Start-UiOperation 'Snapshot'
    if (-not $script:ui.Job) { throw "Worker did not start: $($script:ui.Footer.Text)" }
    $jobDirectory = $script:ui.Job.Directory
    Write-Host "Snapshot worker started (PID $($script:ui.Job.Process.Id))."
    if ($script:ui.ActionButtons[0].Enabled) { throw 'The UI did not mark an operation as busy.' }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ($script:ui.Job -and [DateTime]::UtcNow -lt $deadline) {
        Complete-UiOperation
        if ($script:ui.Job) { [Threading.Thread]::Sleep(50) }
    }
    if ($script:ui.Job) {
        Get-Content -LiteralPath $script:ui.Job.Log -Tail 15 -ErrorAction SilentlyContinue | Write-Host
        throw "Snapshot worker timed out (PID $($script:ui.Job.Process.Id))."
    }
    if (-not $script:ui.Snapshot -or -not $script:ui.Snapshot.Checks) { throw "Snapshot worker failed: $($script:ui.Footer.Text)" }
    if (-not $script:ui.ActionButtons[0].Enabled -or (Test-Path -LiteralPath $jobDirectory)) { throw 'Busy state or job-file cleanup failed.' }
    Write-Host 'PASS: Background Snapshot worker returns data and restores responsive UI state.'

    $timeoutDirectory = Join-Path $packageRoot ('.ui-timeout-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $timeoutDirectory | Out-Null
    $fakeProcess = [pscustomobject]@{ HasExited = $false; Killed = $false }
    $fakeProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value { $this.HasExited = $true; $this.Killed = $true }
    $fakeProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds); return $true }
    $fakeProcess | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    $script:ui.Job = @{ Process = $fakeProcess; Operation = 'Snapshot'; StartedUtc = [DateTime]::UtcNow.AddSeconds(-46); Directory = $timeoutDirectory; ResultPath = (Join-Path $timeoutDirectory 'result.json'); Log = (Join-Path $timeoutDirectory 'worker.log'); Elevated = $false; TimedOut = $false }
    Complete-UiOperation
    if (-not $fakeProcess.Killed -or $script:ui.Job -or (Test-Path -LiteralPath $timeoutDirectory) -or $script:ui.Footer.Text -notlike '*timed out*') { throw 'A stalled status worker was not stopped and cleaned up.' }
    Write-Host 'PASS: A stalled read-only status worker times out and cleans up safely.'

    $resultPath = Join-Path $packageRoot ('.identity-test-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $packageRoot 'Setup.ps1') -Operation Snapshot -ExpectedUserSid 'S-1-5-21-0-0-0-9999' -ResultPath $resultPath
        $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        if ($LASTEXITCODE -ne 1 -or $result.Success -or $result.Error -notlike '*different Windows account*') { throw 'The worker did not reject a changed Windows identity.' }
        Write-Host 'PASS: A changed Windows identity is rejected before any operation.'
    }
    finally { if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force } }
}
finally {
    if ($script:ui.Job) {
        if (-not $script:ui.Job.Process.HasExited) { $script:ui.Job.Process.Kill(); $script:ui.Job.Process.WaitForExit() }
        Complete-UiOperation
    }
    $script:ui.Footer.Dispose(); $script:ui.Progress.Dispose(); $script:ui.ActionButtons[0].Dispose()
}
Write-Host '3 UI/worker checks passed.'
# The identity check deliberately leaves a worker exit code of 1; CI ends a step with that code.
exit 0
