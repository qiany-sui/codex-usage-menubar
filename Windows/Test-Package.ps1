param([Parameter(Mandatory)][string]$Executable)

$ErrorActionPreference = 'Stop'
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("codex-usage-" + [Guid]::NewGuid().ToString('N'))
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexUsageSmokeWindow
{
    private delegate bool WindowCallback(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(WindowCallback callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr window, StringBuilder title, int capacity);

    public static bool HasTitle(uint processId, string title)
    {
        // 焦点丢失时用量面板会隐藏，仍需检查测试进程创建的窗口。
        var text = new StringBuilder(title.Length + 2);
        bool found = false;
        EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out uint owner);
            found = owner == processId &&
                GetWindowText(window, text, text.Capacity) == title.Length &&
                text.ToString() == title;
            return !found;
        }, IntPtr.Zero);
        return found;
    }
}
'@

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
        $windowReady = [CodexUsageSmokeWindow]::HasTitle($process.Id, 'Codex Usage')
        $databaseReady = Test-Path -LiteralPath $database
        if ($windowReady -and $databaseReady) {
            Write-Output 'The Windows app created its window and initialized local storage.'
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "Codex Usage startup timed out after 45 seconds (window created: $windowReady, database initialized: $databaseReady)."
} finally {
    if ($process -and !$process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
