param([Parameter(Mandatory)][string]$Executable)

$ErrorActionPreference = 'Stop'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("codex-usage-" + [Guid]::NewGuid().ToString('N'))
$process = $null
try {
    $logs = Join-Path $sandbox 'codex'
    New-Item -ItemType Directory -Path (Join-Path $logs 'sessions') -Force | Out-Null
    $start = [Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $Executable).Path)
    $start.UseShellExecute = $false
    $start.Environment['CODEX_HOME'] = $logs
    $start.Environment['CODEX_CLI_PATH'] = ''
    $process = [Diagnostics.Process]::Start($start)

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $database = Join-Path $localAppData 'Codex Usage/usage.sqlite'
    $deadline = (Get-Date).AddSeconds(45)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Codex Usage exited early with code $($process.ExitCode)." }
        if ($process.MainWindowTitle -eq 'Codex Usage' -and (Test-Path -LiteralPath $database)) {
            Write-Output 'The Windows app opened its window and initialized local storage.'
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Codex Usage did not open and initialize storage within 45 seconds.'
} finally {
    if ($process -and !$process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
