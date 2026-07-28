@echo off
rem Thin wrapper around the canonical launch.ps1 (console briefly flashes).
rem Prefer RewriteDEX.vbs or the Desktop RewriteDEX shortcut for no-console launch.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.ps1"
