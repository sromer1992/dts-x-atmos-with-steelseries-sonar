@echo off
setlocal
:: DTS X / Atmos with Sonar -- setup launcher -- double-click me!
:: The dashboard runs as your user; individual operations elevate if needed.
:: Pass the path as data so apostrophes and spaces do not break PowerShell code.
set "FIXAUDIO_SETUP=%~dp0Setup.ps1"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { $engine = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + [char]34 + $env:FIXAUDIO_SETUP + [char]34; $process = Start-Process -FilePath $engine -WindowStyle Hidden -ArgumentList $arguments -PassThru -Wait -ErrorAction Stop; exit $process.ExitCode } catch { Write-Error $_; exit 1 }"
exit /b %errorlevel%
