# Canonical RewriteDEX launcher.
# Starts rewritedex-native\build\rewritedex-native.exe and stops any other
# controller binary so legacy/archive builds cannot run alongside it.
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
$Exe = [System.IO.Path]::GetFullPath(
    (Join-Path $Root 'rewritedex-native\build\rewritedex-native.exe'))

# Keep local credentials in the existing ignored .env file and pass them only
# to the host controller process. Never package them into the Android agent.
$EnvFile = Join-Path $Root '.env'
if (Test-Path -LiteralPath $EnvFile) {
    foreach ($line in Get-Content -LiteralPath $EnvFile) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
            $name = $Matches[1]
            $value = $Matches[2].Trim()
            if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        }
    }
}

if (-not (Test-Path -LiteralPath $Exe)) {
    throw "RewriteDEX has not been built. Run .\build.ps1 first.`nExpected: $Exe"
}

function Get-RewriteDexControllers {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('rewritedex-native.exe', 'rewritedex.exe') -or
            ($_.ExecutablePath -and (
                $_.ExecutablePath -like '*rewritedex-native.exe' -or
                $_.ExecutablePath -like '*\rewritedex.exe'
            ))
        }
}

$running = @(Get-RewriteDexControllers)
$samePath = @($running | Where-Object {
    $_.ExecutablePath -and (
        [System.IO.Path]::GetFullPath($_.ExecutablePath) -ieq $Exe
    )
})
$others = @($running | Where-Object {
    -not $_.ExecutablePath -or (
        [System.IO.Path]::GetFullPath($_.ExecutablePath) -ine $Exe
    )
})

foreach ($proc in $others) {
    $path = if ($proc.ExecutablePath) { $proc.ExecutablePath } else { '(unknown path)' }
    Write-Warning "Stopping other RewriteDEX instance PID $($proc.ProcessId): $path"
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}

if ($samePath.Count -gt 0) {
    Write-Host "RewriteDEX already running (PID $($samePath.ProcessId -join ', ')); sending --start."
} else {
    Write-Host "Starting: $Exe --start"
}

Start-Process -FilePath $Exe -ArgumentList '--start' -WorkingDirectory (Split-Path -Parent $Exe)
