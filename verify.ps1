param(
    [string]$Serial,
    [switch]$SkipDevice
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$bundle = Join-Path $root 'host_bundle'
$adb = Join-Path $bundle 'adb-windows\adb.exe'
$apk = Join-Path $bundle 'AndroidDex.apk'
$scrcpy = Join-Path $root 'third_party\scrcpy\scrcpy-fork.exe'
$server = Join-Path $root 'third_party\scrcpy\scrcpy-server'
$hostExe = Join-Path $root 'build\windows\x64\runner\Release\androiddex_host.exe'

foreach ($path in @($adb, $apk, $scrcpy, $server)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing AndroidDexFlutter runtime artifact: $path"
    }
}

$help = (& $scrcpy --help 2>&1 | Out-String)
foreach ($option in @('--desktop-transport', '--display-ime-policy', '--new-display')) {
    if ($help -notmatch [regex]::Escape($option)) {
        throw "The bundled scrcpy client does not expose $option."
    }
}

if (Test-Path -LiteralPath $hostExe -PathType Leaf) {
    Write-Host "Flutter host: $hostExe"
} else {
    Write-Warning 'Release host is not built yet. Run .\build.ps1 before launching.'
}
Write-Host 'Runtime artifacts and scrcpy capabilities: OK'

if ($SkipDevice) { return }

if (-not $Serial) {
    $Serial = (& $adb devices) |
        Select-String -Pattern '^([^\s]+)\s+device$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Where-Object { $_ -notlike 'emulator-*' } |
        Select-Object -First 1
}
if (-not $Serial) { throw 'No authorized physical Android device was found.' }

$package = (& $adb -s $Serial shell pm path com.shrey.androiddex 2>&1 | Out-String).Trim()
if (-not $package -or $package -match 'Unknown package') {
    throw "Android-Dex companion package com.shrey.androiddex is not installed on $Serial."
}

Write-Host "Authorized device: $Serial"
Write-Host 'Android-Dex companion APK: installed'
