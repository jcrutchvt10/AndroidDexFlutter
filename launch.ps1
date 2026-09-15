# Canonical AndroidDexFlutter launcher.
# Starts the packaged Flutter Windows host produced by build.ps1.
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Exe = [System.IO.Path]::GetFullPath((Join-Path $Root 'build\windows\x64\runner\Release\androiddex_host.exe'))

if (-not (Test-Path -LiteralPath $Exe)) {
    throw "AndroidDexFlutter has not been built. Run .\build.ps1 first.`nExpected: $Exe"
}

Write-Host "Starting: $Exe"
Start-Process -FilePath $Exe -WorkingDirectory (Split-Path -Parent $Exe)
