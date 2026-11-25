param([ValidateSet('x64')][string]$Architecture = 'x64')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$target = 'x86_64-pc-windows-msvc'

Push-Location $root
try {
    npm run tauri -- build --ci --target $target --bundles nsis -- --locked
    if ($LASTEXITCODE -ne 0) { throw "Tauri could not build the Windows $Architecture installer." }
    $installer = Get-ChildItem -File "target/$target/release/bundle/nsis/*-setup.exe" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (!$installer) { throw 'The built Windows installer was not found.' }
    Write-Output $installer.FullName
} finally {
    Pop-Location
}
