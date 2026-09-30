param(
    [string]$Version = '2.0.0',
    [string]$OutDir = '.'
)

# Packages the Flutter Windows host (androiddex_host.exe) into a zip together
# with its sidecar runtime. The sidecars are produced by `build.ps1` and were
# fetched for a fresh checkout by `bootstrap.ps1`.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$releaseDir = Join-Path $root 'build\windows\x64\runner\Release'
$hostExe = Join-Path $releaseDir 'androiddex_host.exe'
$bundleDir = Join-Path $releaseDir 'host_bundle'

foreach ($path in @($hostExe, $bundleDir)) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing build artefact: $path. Run .\build.ps1 first."
    }
}

$stage = Join-Path $env:TEMP ("androiddex-package-" + [guid]::NewGuid().ToString('N'))
$zip = Join-Path (Join-Path $root $OutDir) "AndroidDEX-$Version.zip"
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    Copy-Item -LiteralPath $hostExe -Destination $stage
    Copy-Item -Path $bundleDir -Destination (Join-Path $stage 'host_bundle') -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'LICENSE.md') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $root 'launch.ps1') -Destination $stage
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
} finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
Write-Host "Created $zip"