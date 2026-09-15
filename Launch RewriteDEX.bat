@echo off
rem Thin wrapper around the AndroidDexFlutter launch.ps1 (console briefly flashes).
rem Prefer RewriteDEX.vbs for a no-console launch.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1"
