param([string]$Serial, [switch]$NoReboot)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$adb = Join-Path $root 'third_party\scrcpy\adb.exe'
if (-not (Test-Path -LiteralPath $adb)) { $adb = Join-Path $root 'scrcpy\adb.exe' }
$module = Get-ChildItem -Path $root -Filter 'RewriteDEX-Desktop-Wallpaper-*.zip' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $module) {
    $module = Get-ChildItem -Path (Join-Path $root 'rewritedex-native') `
        -Filter 'RewriteDEX-Desktop-Wallpaper-*.zip' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}
if (-not $module) { throw 'The RewriteDEX desktop wallpaper module was not found.' }
if (-not $Serial) {
    $Serial = (& $adb devices) |
        Select-String -Pattern '^([^\s]+)\s+device$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value } |
        Select-Object -First 1
}
if (-not $Serial) { throw 'No authorized Android device was found.' }

$remote = '/data/local/tmp/rewritedex-desktop-wallpaper.zip'
& $adb -s $Serial push $module.FullName $remote
if ($LASTEXITCODE -ne 0) { throw 'Could not copy the wallpaper module to the device.' }
& $adb -s $Serial shell su -c "magisk --install-module $remote"
if ($LASTEXITCODE -ne 0) { throw 'Magisk rejected the wallpaper module.' }
Write-Host 'RewriteDEX desktop wallpaper module installed.'
if (-not $NoReboot) { & $adb -s $Serial reboot }
