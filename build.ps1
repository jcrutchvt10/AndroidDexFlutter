$ErrorActionPreference = 'Stop'

# Build the active Flutter/Dart Windows host. A checkout-local SDK is useful
# for the original development environment, while FLUTTER_ROOT or PATH keeps
# a fresh clone reproducible without committing that multi-gigabyte SDK cache.
$localFlutter = Join-Path $PSScriptRoot 'tools\flutter\bin\flutter.bat'
$envFlutter = if ($env:FLUTTER_ROOT) {
    Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'
} else {
    $null
}
$flutter = if (Test-Path -LiteralPath $localFlutter) {
    $localFlutter
} elseif ($envFlutter -and (Test-Path -LiteralPath $envFlutter)) {
    $envFlutter
} else {
    'flutter'
}

& $flutter pub get
if ($LASTEXITCODE -ne 0) { throw "Flutter dependency resolution failed (exit $LASTEXITCODE)." }

& $flutter build windows
if ($LASTEXITCODE -ne 0) { throw "Flutter Windows build failed (exit $LASTEXITCODE)." }

Write-Host 'Built AndroidDexFlutter: build\windows\x64\runner\Release\androiddex_host.exe'
