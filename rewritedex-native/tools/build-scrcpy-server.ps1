# Rebuild scrcpy-server (Java) for RewriteDEX pause support and deploy.
$ErrorActionPreference = 'Stop'

$Project = Split-Path $PSScriptRoot -Parent
$Repo = Split-Path $Project -Parent
$Sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
# Compile against 35+ so VERSION_CODES.VANILLA_ICE_CREAM exists.
# aidl.exe from build-tools 36 breaks on oneway interfaces; use 34 for AIDL only.
$Platform = '35'
$BuildTools = '34.0.0'   # aidl only (36+ aidl breaks oneway interfaces)
$D8BuildTools = '36.0.0' # modern d8/r8
$AidlPlatform = '34'
$ServerDir = Join-Path $Repo 'third_party\scrcpy-fork\server'
$BuildDir = Join-Path $env:TEMP 'rewritedex-scrcpy-server-build'

$PlatformTools = Join-Path $Sdk "platforms\android-$Platform"
$BuildToolsDir = Join-Path $Sdk "build-tools\$BuildTools"
$AndroidJar = Join-Path $PlatformTools 'android.jar'
$AndroidAidl = Join-Path $Sdk "platforms\android-$AidlPlatform\framework.aidl"
$LambdaJar = Join-Path $BuildToolsDir 'core-lambda-stubs.jar'
$Aidl = Join-Path $BuildToolsDir 'aidl.exe'
$D8Dir = Join-Path $Sdk "build-tools\$D8BuildTools"
$D8 = Join-Path $D8Dir 'd8.bat'
if (-not (Test-Path -LiteralPath $D8)) { $D8 = Join-Path $BuildToolsDir 'd8.bat' }

foreach ($p in @($AndroidJar, $Aidl, $D8, $LambdaJar)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" }
}

if (Test-Path -LiteralPath $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
$ClassesDir = Join-Path $BuildDir 'classes'
$HiddenClassesDir = Join-Path $BuildDir 'hidden-api-classes'
$GenDir = Join-Path $BuildDir 'gen'
New-Item -ItemType Directory -Force -Path $ClassesDir | Out-Null
New-Item -ItemType Directory -Force -Path $HiddenClassesDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $GenDir 'com\genymobile\scrcpy') | Out-Null

$buildConfig = @"
package com.genymobile.scrcpy;

public final class BuildConfig {
  public static final boolean DEBUG = false;
  // MUST match client SCRCPY_VERSION exactly or server aborts on connect.
  public static final String VERSION_NAME = "4.1";
}
"@
Set-Content -LiteralPath (Join-Path $GenDir 'com\genymobile\scrcpy\BuildConfig.java') -Value $buildConfig -Encoding ASCII

Write-Host '[server] Generating java from aidl (build-tools 34)...'
$aidlRoot = Join-Path $ServerDir 'src\main\aidl'
Push-Location $aidlRoot
try {
    & $Aidl "-o$GenDir" '-I.' 'android/content/IOnPrimaryClipChangedListener.aidl'
    if ($LASTEXITCODE -ne 0) { throw "aidl clip failed: $LASTEXITCODE" }
    & $Aidl "-o$GenDir" '-I.' "-p$AndroidAidl" 'android/view/IDisplayWindowListener.aidl'
    if ($LASTEXITCODE -ne 0) { throw "aidl display failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

Write-Host '[server] Collecting sources...'
$javaRoot = Join-Path $ServerDir 'src\main\java'
$hiddenApiRoot = Join-Path $ServerDir 'hidden-api'
$hiddenSources = Get-ChildItem -LiteralPath $hiddenApiRoot -Recurse -Filter '*.java' |
    ForEach-Object FullName
if ($hiddenSources.Count -eq 0) { throw "No hidden API stubs found in $hiddenApiRoot" }
Write-Host ("[server] Compiling {0} hidden API stubs (classpath only)..." -f $hiddenSources.Count)
& javac `
    -encoding UTF-8 `
    -bootclasspath $AndroidJar `
    -d $HiddenClassesDir `
    -source 1.8 `
    -target 1.8 `
    $hiddenSources
if ($LASTEXITCODE -ne 0) { throw "hidden API javac failed: $LASTEXITCODE" }

$sources = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath (Join-Path $javaRoot 'android\content') -Filter '*.java' -ErrorAction SilentlyContinue |
    ForEach-Object { [void]$sources.Add($_.FullName) }
foreach ($rel in @(
    'com\genymobile\scrcpy',
    'com\genymobile\scrcpy\audio',
    'com\genymobile\scrcpy\control',
    'com\genymobile\scrcpy\compositor',
    'com\genymobile\scrcpy\device',
    'com\genymobile\scrcpy\display',
    'com\genymobile\scrcpy\model',
    'com\genymobile\scrcpy\opengl',
    'com\genymobile\scrcpy\util',
    'com\genymobile\scrcpy\video',
    'com\genymobile\scrcpy\wrappers'
)) {
    $dir = Join-Path $javaRoot $rel
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -Filter '*.java' | ForEach-Object { [void]$sources.Add($_.FullName) }
    }
}
Get-ChildItem -LiteralPath $GenDir -Recurse -Filter '*.java' | ForEach-Object { [void]$sources.Add($_.FullName) }

$argFile = Join-Path $BuildDir 'sources.rsp'
# javac @file wants one path per line
$sources | Set-Content -LiteralPath $argFile -Encoding ASCII
Write-Host ("[server] Compiling {0} java files..." -f $sources.Count)

$javacArgs = @(
    '-encoding', 'UTF-8',
    '-bootclasspath', $AndroidJar,
    '-cp', "$LambdaJar;$GenDir;$HiddenClassesDir",
    '-d', $ClassesDir,
    '-source', '1.8',
    '-target', '1.8',
    "@$argFile"
)
& javac @javacArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host '[server] bootclasspath compile failed; trying -classpath only'
    $javacArgs = @(
        '-encoding', 'UTF-8',
        '-classpath', "$AndroidJar;$LambdaJar;$GenDir;$HiddenClassesDir",
        '-d', $ClassesDir,
        '-source', '1.8',
        '-target', '1.8',
        "@$argFile"
    )
    & javac @javacArgs
    if ($LASTEXITCODE -ne 0) { throw "javac failed: $LASTEXITCODE" }
}

Write-Host '[server] Dexing with d8...'
$classFiles = Get-ChildItem -LiteralPath $ClassesDir -Recurse -Filter '*.class' | ForEach-Object FullName
if ($classFiles.Count -eq 0) { throw 'No .class files produced' }

# Avoid Windows command-line length limits: zip classes first, then d8 the zip.
$classesJar = Join-Path $BuildDir 'all-classes.jar'
if (Test-Path -LiteralPath $classesJar) { Remove-Item -Force $classesJar }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$za = [System.IO.Compression.ZipFile]::Open($classesJar, 'Create')
try {
    Get-ChildItem -LiteralPath $ClassesDir -Recurse -Filter '*.class' | ForEach-Object {
        $rel = $_.FullName.Substring($ClassesDir.Length).TrimStart('\', '/').Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $za, $_.FullName, $rel,
            [System.IO.Compression.CompressionLevel]::NoCompression) | Out-Null
    }
} finally {
    $za.Dispose()
}
Write-Host ("[server] packed {0} bytes of classes" -f (Get-Item $classesJar).Length)

Push-Location $BuildDir
try {
    & $D8 --classpath $AndroidJar --classpath $HiddenClassesDir --output $BuildDir $classesJar
    if ($LASTEXITCODE -ne 0) { throw "d8 failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

$serverOut = Join-Path $BuildDir 'scrcpy-server'
$dex = Join-Path $BuildDir 'classes.dex'
$zip = Join-Path $BuildDir 'classes.zip'

if (Test-Path -LiteralPath $dex) {
    # scrcpy expects a jar/zip containing classes.dex
    Push-Location $BuildDir
    try {
        if (Get-Command jar -ErrorAction SilentlyContinue) {
            & jar cvfM scrcpy-server classes.dex | Out-Null
        } else {
            # Fallback: zip via Compress-Archive is not jar-compatible easily;
            # use PowerShell .NET ZipFile
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            if (Test-Path -LiteralPath $serverOut) { Remove-Item -Force $serverOut }
            $zipTmp = Join-Path $BuildDir 'server.zip'
            if (Test-Path $zipTmp) { Remove-Item -Force $zipTmp }
            $za = [System.IO.Compression.ZipFile]::Open($zipTmp, 'Create')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, $dex, 'classes.dex') | Out-Null
            $za.Dispose()
            Move-Item -Force $zipTmp $serverOut
        }
    } finally { Pop-Location }
} elseif (Test-Path -LiteralPath $zip) {
    Copy-Item -LiteralPath $zip -Destination $serverOut -Force
} else {
    Get-ChildItem -LiteralPath $BuildDir | Format-Table Name, Length
    throw 'd8 produced neither classes.dex nor classes.zip'
}

if (-not (Test-Path -LiteralPath $serverOut)) { throw "Missing $serverOut" }

$dests = @((Join-Path $Repo 'third_party\scrcpy\scrcpy-server'))
foreach ($d in $dests) {
    $dir = Split-Path $d -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Copy-Item -LiteralPath $serverOut -Destination $d -Force
    $len = (Get-Item -LiteralPath $d).Length
    Write-Host "[server] deployed $d ($len bytes)"
}

Write-Host '[server] DONE'
Get-Item -LiteralPath $serverOut | Format-List FullName, Length, LastWriteTime
