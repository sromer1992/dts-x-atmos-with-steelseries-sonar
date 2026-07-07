@echo off
:: DTS X / Atmos with Sonar -- setup launcher -- double-click me!
:: This asks for administrator permission, then opens the setup wizard.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%~dp0Setup.ps1\"'"
