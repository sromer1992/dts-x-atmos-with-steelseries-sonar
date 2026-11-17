#requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory = '')
$ErrorActionPreference = 'Stop'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'FixAudio.ps1') -Raw
if ($source -notmatch '(?m)^\$ScriptVersion\s*=\s*''([0-9]+\.[0-9]+\.[0-9]+)''') { throw 'Cannot read the runtime version.' }
$version = $Matches[1]
$required = @('Setup.bat', 'Setup.ps1', 'FixAudio.ps1', 'FixAudio.Core.ps1', 'FixAudio.Management.ps1', 'FixAudio.UI.ps1', 'FixAudio.config.json', 'README.md', 'LICENSE', 'CHANGELOG.md', 'Build-Release.ps1', 'tests\Regression.Tests.ps1', 'tests\UI.Worker.Tests.ps1')
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $output -Force | Out-Null
$stage = Join-Path $output ('.FixAudio-stage-' + [guid]::NewGuid().ToString('N'))
$package = Join-Path $stage 'FixAudio'
New-Item -ItemType Directory -Path $package -Force | Out-Null
try {
    $manifest = [ordered]@{}
    foreach ($name in $required) {
        $path = Join-Path $PSScriptRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing package file: $name" }
        if ($name.EndsWith('.ps1')) {
            $tokens = $null; $errors = $null
            [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors.Count) { throw "Syntax errors in $name" }
        }
        $target = Join-Path $package $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $path -Destination $target
        $manifest[$name.Replace('\', '/')] = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    }
    [pscustomobject]@{ Version = $version; Files = $manifest } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $package 'release-manifest.json') -Encoding UTF8
    $archive = Join-Path $output "FixAudio-$version.zip"
    # Explicit entry names avoid Windows PowerShell 5.1's legacy ZIP backslashes.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in @($required) + @('release-manifest.json')) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $package $name), ('FixAudio/' + $name.Replace('\', '/')), [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally { $zip.Dispose() }
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($name in $required) {
            $relative = $name.Replace('\', '/')
            $entry = $zip.GetEntry('FixAudio/' + $relative)
            if (-not $entry) { throw "Package entry is missing: $relative" }
            $stream = $entry.Open()
            try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
            finally { $stream.Dispose() }
            if ($actual -ne $manifest[$relative]) { throw "Package checksum mismatch: $relative" }
        }
    }
    finally { $sha.Dispose(); $zip.Dispose() }
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    "$hash  $([IO.Path]::GetFileName($archive))" | Set-Content -LiteralPath ($archive + '.sha256') -Encoding ASCII
    [pscustomobject]@{ Archive = $archive; SHA256 = $hash; VerifiedFiles = $required.Count }
}
finally {
    $resolved = [IO.Path]::GetFullPath($stage)
    if ((Split-Path -Parent $resolved).TrimEnd('\') -ieq $output.TrimEnd('\') -and [IO.Path]::GetFileName($resolved) -match '^\.FixAudio-stage-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
