param(
    [string]$Msys2Root = 'C:\msys64',
    [string]$ScrcpyBuildDir = $null
)

$ErrorActionPreference = 'Stop'

$Project = $PSScriptRoot
$Repo = Split-Path $Project -Parent
$ScrcpyDist = Join-Path $Repo 'third_party\scrcpy'
$Bash = Join-Path $Msys2Root 'usr\bin\bash.exe'

if (-not $ScrcpyBuildDir) {
    $ScrcpyBuildDir = if ($env:SCRCPY_BUILD_DIR) {
        $env:SCRCPY_BUILD_DIR
    } else {
        Join-Path $env:TEMP 'build-scrcpy-fork-final-pixel-dex-native'
    }
}

cmake -S (Join-Path $Project 'native-controller') `
    -B (Join-Path $Project 'build') `
    -G Ninja `
    -DCMAKE_BUILD_TYPE=Release
cmake --build (Join-Path $Project 'build')

Push-Location (Join-Path $Project 'android-agent')
try {
    cmd /c gradlew.bat :app:testDebugUnitTest :app:assembleDebug :framework-overlay:assembleDebug
    if ($LASTEXITCODE -ne 0) { throw "Android build failed: $LASTEXITCODE" }
} finally { Pop-Location }

if ((Test-Path $Bash) -and (Test-Path (Join-Path $ScrcpyBuildDir 'build.ninja'))) {
    $scrcpyBuildDirUnix = $ScrcpyBuildDir -replace '\\','/' -replace '^([A-Za-z]):','/$1'
    & $Bash -lc "export MSYSTEM=UCRT64; export PATH=/ucrt64/bin:`$PATH; ninja -C $scrcpyBuildDirUnix"
    if ($LASTEXITCODE -ne 0) { throw "scrcpy client build failed: $LASTEXITCODE" }

    $client = Join-Path $ScrcpyBuildDir 'scrcpy.exe'
    Copy-Item -LiteralPath $client -Destination (Join-Path $ScrcpyDist 'scrcpy.exe') -Force
    Copy-Item -LiteralPath $client -Destination (Join-Path $ScrcpyDist 'scrcpy-fork.exe') -Force
} else {
    Write-Warning 'The existing MSYS2 scrcpy build tree was not found; the deployed client was left unchanged.'
}

$versionFile = Join-Path $Repo 'third_party\scrcpy-fork\app\meson.build'
$serverBuildScript = Join-Path $Project 'tools\build-scrcpy-server.ps1'
if (Test-Path $versionFile) {
    $clientVersionMatch = Get-Content $versionFile |
        Select-String "version\s*:\s*'([^']+)'" |
        Select-Object -First 1
    $clientVersion = if ($clientVersionMatch) {
        $clientVersionMatch.Matches.Groups[1].Value
    } else { $null }
    $serverVersion = if (Test-Path $serverBuildScript) {
        $serverVersionMatch = Get-Content $serverBuildScript |
            Select-String 'VERSION_NAME\s+=\s+"([^"]+)"' |
            Select-Object -First 1
        if ($serverVersionMatch) {
            $serverVersionMatch.Matches.Groups[1].Value
        } else { $null }
    } else { $null }
    if (-not $clientVersion -or -not $serverVersion) {
        throw 'Could not determine the scrcpy client and server versions.'
    }
    if ($clientVersion -and $serverVersion -and $clientVersion -ne $serverVersion) {
        throw "Version skew: client=$clientVersion server=$serverVersion. Update both before building."
    }
}

$serverBuilder = Join-Path $Project 'tools\build-scrcpy-server.ps1'
if (Test-Path $serverBuilder) {
    & $serverBuilder
} else {
    Write-Warning 'The scrcpy server builder was not found; the deployed server was left unchanged.'
}

Write-Host 'Built:'
Write-Host "  $(Join-Path $Project 'build\rewritedex-native.exe')"
Write-Host "  $(Join-Path $Project 'android-agent\app\build\outputs\apk\debug\app-debug.apk')"
Write-Host "  $(Join-Path $Project 'android-agent\framework-overlay\build\outputs\apk\debug\framework-overlay-debug.apk')"
Write-Host "  $(Join-Path $ScrcpyDist 'scrcpy-fork.exe')"
Write-Host "  $(Join-Path $ScrcpyDist 'scrcpy-server')"
