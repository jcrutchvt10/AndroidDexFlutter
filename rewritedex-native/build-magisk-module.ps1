param(
    [string]$Version = '2.2.0',
    [string]$OutDir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$project = $PSScriptRoot
$source = Join-Path $project 'magisk-module'
$overlay = Join-Path $project 'android-agent\framework-overlay\build\outputs\apk\debug\framework-overlay-debug.apk'
$stage = Join-Path $env:TEMP ("rewritedex-magisk-" + [guid]::NewGuid().ToString('N'))
$output = Join-Path $OutDir "RewriteDEX-Desktop-Wallpaper-$Version.zip"

foreach ($artifact in @($overlay)) {
    if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
        throw "Missing artifact: $artifact"
    }
}

try {
    Copy-Item -LiteralPath $source -Destination $stage -Recurse
    $overlayDir = Join-Path $stage 'system\product\overlay'
    New-Item -ItemType Directory -Force -Path $overlayDir | Out-Null
    Copy-Item -LiteralPath $overlay -Destination (Join-Path $overlayDir 'RewriteDEXWallpaperOverlay.apk')
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $output -Force
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}

Write-Host "Created $output"
