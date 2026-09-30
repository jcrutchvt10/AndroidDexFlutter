param(
    [string]$Release = 'Android-Dex-v.1.2',
    [string]$OutDir = '.',
    [string]$RepoUrl = 'https://github.com/Shrey113/Android-Dex'
)

# Downloads the Android-Dex v1.2 release bundle and extracts the host runtime
# (adb, scrcpy, AndroidDex.apk, androiddex.jar) into host_bundle/.
#
# Running this script is required before `build.ps1` on a fresh clone that does
# NOT ship host_bundle/ as a committed artefact.
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$bundleDir = Join-Path $root $OutDir | Join-Path -ChildPath 'host_bundle'
if (-not (Test-Path (Join-Path $bundleDir 'adb-windows\adb.exe'))) {
    $url = "$RepoUrl/releases/download/$Release/Android_Dex_Windows.zip"
    $zipPath = Join-Path $env:TEMP "Android_Dex_Windows.zip"
    $extractPath = Join-Path $env:TEMP "Android_Dex_extract"
    Write-Host "Downloading $url …"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zipPath
    Write-Host "Extracting to $extractPath …"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
    Write-Host "Staging host_bundle/ …"
    if (-not (Test-Path $bundleDir)) {
        New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $extractPath '*') -Destination $bundleDir -Recurse -Force
    Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "host_bundle/ is ready."
} else {
    Write-Host "host_bundle/ is already populated."
}