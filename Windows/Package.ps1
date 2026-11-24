param([ValidateSet('x64', 'arm64')][string]$Architecture)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (!$Architecture) {
    $Architecture = switch ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
        X64 { 'x64' }
        Arm64 { 'arm64' }
        default { throw 'A 64-bit Windows Rust toolchain is required.' }
    }
}
$target = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }

Push-Location $root
try {
    npm run tauri -- build --ci --target $target --bundles nsis -- --locked
    if ($LASTEXITCODE -ne 0) { throw 'Tauri could not build the Windows installer.' }
    $installer = Get-ChildItem -File "target/$target/release/bundle/nsis/*-setup.exe" |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (!$installer) { throw 'The built Windows installer was not found.' }
    Write-Output $installer.FullName
} finally {
    Pop-Location
}
