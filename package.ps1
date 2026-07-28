param(
    [string]$Version = '2.3.0',
    [string]$OutDir = '.'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$controller = Join-Path $root 'rewritedex-native\build\rewritedex-native.exe'
$agent = Join-Path $root 'rewritedex-native\android-agent\app\build\outputs\apk\debug\app-debug.apk'
$scrcpy = Join-Path $root 'third_party\scrcpy'
$moduleBuilder = Join-Path $root 'rewritedex-native\build-magisk-module.ps1'

& $moduleBuilder -Version $Version -OutDir $root
$wallpaperModule = Join-Path $root "RewriteDEX-Desktop-Wallpaper-$Version.zip"

foreach ($path in @($controller, $agent, $scrcpy, $wallpaperModule)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing build artifact: $path. Run .\build.ps1 first."
    }
}

$stage = Join-Path $env:TEMP ("rewritedex-package-" + [guid]::NewGuid().ToString('N'))
$zip = Join-Path (Join-Path $root $OutDir) "RewriteDEX-$Version.zip"
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'scrcpy') | Out-Null
try {
    Copy-Item -LiteralPath $controller -Destination (Join-Path $stage 'rewritedex-native.exe')
    Copy-Item -LiteralPath $agent -Destination (Join-Path $stage 'rewritedex-agent.apk')
    Copy-Item -LiteralPath $wallpaperModule -Destination $stage
    Copy-Item -Path (Join-Path $scrcpy '*') -Destination (Join-Path $stage 'scrcpy') -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'install-wallpaper.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'disable-wallpaper.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE.md') -Destination $stage
    # Single launch story: launch.ps1 is canonical; VBS hides the PowerShell host.
    Copy-Item -LiteralPath (Join-Path $root 'launch.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'RewriteDEX.vbs') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'Launch RewriteDEX.bat') -Destination $stage
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}

Write-Host "Created $zip"
