param([string]$Serial, [switch]$NoReboot)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$adb = Join-Path $root 'third_party\scrcpy\adb.exe'
if (-not (Test-Path -LiteralPath $adb)) { $adb = Join-Path $root 'scrcpy\adb.exe' }
if (-not $Serial) {
    $Serial = (& $adb devices) |
        Select-String -Pattern '^([^\s]+)\s+device$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Select-Object -First 1
}
if (-not $Serial) { throw 'No authorized Android device was found.' }
& $adb -s $Serial shell su -c `
    'touch /data/adb/modules/rewritedex-desktop-wallpaper/disable'
if ($LASTEXITCODE -ne 0) { throw 'Could not disable the wallpaper module.' }
Write-Host 'RewriteDEX desktop wallpaper module disabled.'
if (-not $NoReboot) { & $adb -s $Serial reboot }
