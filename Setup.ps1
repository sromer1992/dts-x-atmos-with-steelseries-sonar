#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$UpdateInstalled,
    [ValidateSet('Snapshot', 'Install', 'Update', 'Options', 'Repair', 'Restore', 'Uninstall', 'Pause', 'Resume', 'Driver')]
    [string]$Operation,
    [string]$Destination,
    [string]$RequestPath,
    [string]$ResultPath,
    [string]$ExpectedUserSid,
    [string]$PreviewPath,
    [ValidateSet('Overview', 'Audio options', 'Setup guide', 'History & logs')][string]$PreviewPage = 'Overview'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'FixAudio.Core.ps1')
. (Join-Path $PSScriptRoot 'FixAudio.Management.ps1')
if ($MyInvocation.InvocationName -eq '.') { return }

if ($UpdateInstalled) { $Operation = 'Update' }
if ($Operation) {
    $exitCode = 0
    try {
        if ($ExpectedUserSid -and $ExpectedUserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
            throw 'Elevation used a different Windows account. Cancel and run FixAudio as the intended user; no changes were made.'
        }
        $request = $null
        if ($RequestPath) { $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json }
        $data = Invoke-ControlOperation -Operation $Operation -Destination $Destination -Request $request
        $result = [pscustomobject]@{ Success = $true; Data = $data; Error = ''; NeedsElevation = $false }
    }
    catch {
        $exitCode = 1
        $message = $_.Exception.Message
        $result = [pscustomobject]@{ Success = $false; Data = $null; Error = $message; NeedsElevation = ($message -match 'Access is denied|0x80070005|UnauthorizedAccess|administrator rights') }
    }
    if ($ResultPath) {
        $temporary = $ResultPath + '.tmp'
        $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $ResultPath -Force
    }
    else { $result | Format-List }
    exit $exitCode
}

. (Join-Path $PSScriptRoot 'FixAudio.UI.ps1')
Show-FixAudioWindow -PreviewPath $PreviewPath -PreviewPage $PreviewPage
