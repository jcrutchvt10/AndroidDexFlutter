param(
    [string]$Serial,
    [switch]$SkipDevice,
    [switch]$ExerciseAgentApi
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$controller = Join-Path $root 'rewritedex-native\build\rewritedex-native.exe'
$agent = Join-Path $root 'rewritedex-native\android-agent\app\build\outputs\apk\debug\app-debug.apk'
$runtime = Join-Path $root 'third_party\scrcpy'
$scrcpy = Join-Path $runtime 'scrcpy-fork.exe'
$server = Join-Path $runtime 'scrcpy-server'
$adb = Join-Path $runtime 'adb.exe'

foreach ($path in @($controller, $agent, $scrcpy, $server, $adb)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing runtime artifact: $path"
    }
}

$help = (& $scrcpy --help 2>&1 | Out-String)
foreach ($option in @('--desktop-transport', '--display-ime-policy', '--new-display')) {
    if ($help -notmatch [regex]::Escape($option)) {
        throw "The deployed scrcpy client does not expose $option."
    }
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

$expectedSettings = @(
    @('secure', 'show_ime_with_hard_keyboard'),
    @('global', 'enable_freeform_support'),
    @('global', 'force_resizable_activities'),
    @('global', 'force_desktop_mode_on_external_displays')
)
foreach ($setting in $expectedSettings) {
    $value = (& $adb -s $Serial shell settings get $setting[0] $setting[1]).Trim()
    if ($value -ne '1') {
        throw "Android setting $($setting[0])/$($setting[1]) is '$value', expected '1'."
    }
}

$displayState = & $adb -s $Serial shell dumpsys display | Out-String
foreach ($flag in @(
    'FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS',
    'FLAG_TRUSTED',
    'FLAG_OWN_DISPLAY_GROUP',
    'FLAG_OWN_FOCUS'
)) {
    if ($displayState -notmatch $flag) { throw "The active desktop display is missing $flag." }
}
if ($displayState -notmatch 'uniqueId="virtual:com\.android\.shell,2000,scrcpy') {
    throw 'No active scrcpy virtual desktop display was found.'
}

& $adb -s $Serial forward tcp:8792 tcp:8792 | Out-Null
if ($ExerciseAgentApi) {
    $tokenBytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($tokenBytes)
    $token = [Convert]::ToHexString($tokenBytes).ToLowerInvariant()
    & $adb -s $Serial shell am start-foreground-service `
        -n com.rewritedex.nativeagent/.DexAgentService --es token $token | Out-Null
    Start-Sleep -Milliseconds 500
}
$unauthorized = Invoke-WebRequest -Uri 'http://127.0.0.1:8792/status' -SkipHttpErrorCheck
if ($unauthorized.StatusCode -ne 401) {
    throw "Agent bridge returned $($unauthorized.StatusCode) without a token, expected 401."
}

if ($ExerciseAgentApi) {
    $headers = @{ 'X-RewriteDEX-Token' = $token }
    $status = Invoke-WebRequest -Uri 'http://127.0.0.1:8792/status' -Headers $headers -SkipHttpErrorCheck
    if ($status.StatusCode -ne 200 -or $status.Content -notmatch '"ok":true') {
        throw 'Authenticated agent status request failed.'
    }
    $missing = Invoke-WebRequest -Uri 'http://127.0.0.1:8792/missing' -Headers $headers -SkipHttpErrorCheck
    if ($missing.StatusCode -ne 404) { throw 'Agent unknown routes must return HTTP 404.' }
    $largeBody = 'x' * (64 * 1024 + 1)
    $oversized = Invoke-WebRequest -Method Post -Uri 'http://127.0.0.1:8792/system' `
        -Headers $headers -ContentType 'application/json' -Body $largeBody -SkipHttpErrorCheck
    if ($oversized.StatusCode -ne 413) { throw 'Agent oversized requests must return HTTP 413.' }
    Write-Warning 'The API exercise rotated the agent token; refresh or relaunch RewriteDEX afterward.'
}

Write-Host "Pixel desktop display, IME policy prerequisites, and agent authentication: OK ($Serial)"
