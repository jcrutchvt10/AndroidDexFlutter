#Requires -Version 5.1
# RewriteDEX: post-fix desktop-launch verification.
# Source of truth for this script:
#   https://github.com/.../rewritedex/...
# Prerequisites: a connected Pixel (adb), scrcpy-fork + scrcpy-server in the directory
# below, the DexAgentService APK installed (adb install -r ...), and a 64-char hex
# session token. The controller normally generates this; for this standalone test
# we'll inject one via am.

$ErrorActionPreference = 'Continue'
$Serials = & adb devices | Where-Object { $_ -match 'device$' } | ForEach-Object { ($_ -split '\s+')[0] }
if ($Serials.Count -ne 1) { throw "Expected exactly one adb device; found $($Serials.Count)" }
$Serial = $Serials[0]
Write-Host "Using device $Serial"

$ScrcpyExe = "$PSScriptRoot\scrcpy-fork.exe"
$ScrcpyServer = "$PSScriptRoot\scrcpy-server"
if (-not (Test-Path $ScrcpyExe))  { throw "Missing $ScrcpyExe" }
if (-not (Test-Path $ScrcpyServer)) { throw "Missing $ScrcpyServer" }
$env:SCRCPY_SERVER_PATH = $ScrcpyServer

# Known-good test package (Settings always present on Pixel).
$TargetPackage = 'com.android.settings'
$TargetActivity = '.Settings'

# Bootstrap session token (matches agent's TOKEN_PATTERN = ^[a-f0-9]{64}$).
$Token = -join ((1..32) | ForEach-Object { '{0:x2}' -f (Get-Random -Max 256) })

# Fresh agent + scrcpy session.
& adb -s $Serial shell am stopservice com.rewritedex.nativeagent/.DexAgentService | Out-Null
& adb -s $Serial shell am start-foreground-service -n com.rewritedex.nativeagent/.DexAgentService --es token $Token | Out-Null
& adb -s $Serial forward tcp:8792 tcp:8792 | Out-Null
Start-Sleep -Seconds 3

# Boot scrcpy-fork in the background. --record keeps the video pipeline alive while
# --no-window discards the decoded frames. --display-ime-policy=hide is exercised
# separately by Bug 2 (IME on text fields). --new-display creates the desktop displayId.
$ScrcpyArgs = @(
  '-s', $Serial,
  '--new-display=1280x720/240',
  '--window-title=VerifyDesktopLaunch',
  '--display-ime-policy=hide',
  '--keyboard=uhid', '--mouse=uhid', '--gamepad=uhid',
  '--shortcut-mod=lsuper',
  '--no-window-aspect-ratio-lock',
  '--push-target=/sdcard/Download/',
  '--record="$env:TEMP\scrcpy-out.mp4"',
  '--video-bit-rate=1M', '--video-codec=h264',
  '--max-fps=30',
  '--no-window'
)
$ScrcpyProc = Start-Process -FilePath $ScrcpyExe -ArgumentList $ScrcpyArgs -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\scrcpy-out.log" -RedirectStandardError "$env:TEMP\scrcpy-err.log"
Start-Sleep -Seconds 8

# Identify the desktop displayId (non-zero; usually 7-9).
$DesktopDisplayId = (& adb -s $Serial shell dumpsys display | Select-String -Pattern 'mDisplayId=(\d+)' -AllMatches).Matches.Value |
  Where-Object { $_ -ne '0' } | Select-Object -First 1
if (-not $DesktopDisplayId) { throw "No virtual display after scrcpy boot" }
Write-Host "Desktop displayId = $DesktopDisplayId"

# Open NexusLauncher on the desktop displayId.
& adb -s $Serial shell am start --display $DesktopDisplayId -W -n com.google.android.apps.nexuslauncher/.NexusLauncherActivity | Out-Null
Start-Sleep -Seconds 3

# Open the app drawer (swipe up from dock).
& adb -s $Serial shell input swipe 640 700 640 200 250 | Out-Null
Start-Sleep -Seconds 2

# Find Settings bounds via uiautomator dump (works once drawer is open).
& adb -s $Serial shell uiautomator dump --compressed /sdcard/drawer.xml | Out-Null
$DrawerXml = & adb -s $Serial shell cat /sdcard/drawer.xml 2>$null
$SettingsBounds = ($DrawerXml | Select-String -Pattern 'package="com\.android\.settings"[^/>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' -AllMatches).Matches
if (-not $SettingsBounds) { throw "Could not find Settings bounds in drawer" }
$SettingsCenterX = ([int](($SettingsBounds[0].Groups[1].Value + $SettingsBounds[0].Groups[3].Value) / 2))
$SettingsCenterY = ([int](($SettingsBounds[0].Groups[2].Value + $SettingsBounds[0].Groups[4].Value) / 2))
Write-Host "Tapping Settings at ($SettingsCenterX, $SettingsCenterY)"

# 1) Host click marker (Triggers B's polling fallback).
$Headers = @{ 'X-RewriteDEX-Token' = $Token; 'Content-Type' = 'application/json' }
$Body = @{ displayId = [int]$DesktopDisplayId; action = 'down'; x = $SettingsCenterX; y = $SettingsCenterY } | ConvertTo-Json -Compress
Invoke-RestMethod -Uri 'http://localhost:8792/desktop/input' -Method Post -Headers $Headers -Body $Body | Out-Null

# 2) Synchronized tap (Pixel launcher fires targetComponent + concurrent startActivity).
& adb -s $Serial shell input tap $SettingsCenterX $SettingsCenterY | Out-Null
Start-Sleep -Seconds 4

# Verify evidence.
Write-Host "`n=== Agent log markers (Trigger A) ==="
& adb -s $Serial logcat -d | Select-String -Pattern 'Launched.*desktop display ' + $DesktopDisplayId
Write-Host "`n=== Agent log markers (Trigger B cleanup, optional) ==="
& adb -s $Serial logcat -d | Select-String -Pattern 'Desktop mirror '
Write-Host "`n=== Settings activity location (must be on displayId=$DesktopDisplayId, not 0) ==="
& adb -s $Serial shell dumpsys activity activities | Select-String -Pattern 'com\.android\.settings'

# Tear down.
Stop-Process -Id $ScrcpyProc.Id -Force -ErrorAction SilentlyContinue
& adb -s $Serial shell am stopservice com.rewritedex.nativeagent/.DexAgentService | Out-Null
