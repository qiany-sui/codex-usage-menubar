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
$watcher = $null
$duplicate = $null
$stop = $null
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
            break
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (!$windowReady -or !$databaseReady) {
        throw "Codex Usage startup timed out after 45 seconds (window created: $windowReady, database initialized: $databaseReady)."
    }

    $control = [Diagnostics.ProcessStartInfo]::new($start.FileName)
    $control.UseShellExecute = $false
    $control.CreateNoWindow = $true
    $control.Arguments = '--watch-codex'
    $watcher = [Diagnostics.Process]::Start($control)
    if ($watcher.WaitForExit(1500)) { throw 'The companion watcher exited early.' }
    $duplicate = [Diagnostics.Process]::Start($control)
    if (!$duplicate.WaitForExit(5000) -or $duplicate.ExitCode -ne 0) {
        throw 'A second companion watcher did not exit cleanly.'
    }

    $control.Arguments = '--stop-companion'
    $stop = [Diagnostics.Process]::Start($control)
    if (!$stop.WaitForExit(35000) -or $stop.ExitCode -ne 0) {
        throw 'The app and companion watcher did not shut down gracefully.'
    }
    if (!$process.WaitForExit(5000) -or !$watcher.WaitForExit(5000)) {
        throw 'A Codex Usage process remained after the shutdown request.'
    }
    Write-Output 'The Windows app initialized its window and storage; the companion stayed single-instance and both processes exited gracefully.'
} finally {
    foreach ($child in @($duplicate, $stop, $watcher, $process)) {
        if ($child -and !$child.HasExited) {
            Stop-Process -Id $child.Id -Force
            $child.WaitForExit()
        }
    }
    if (Test-Path -LiteralPath $sandbox) {
        $cleanupPath = [IO.Path]::GetFullPath($sandbox)
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if ([IO.Path]::GetDirectoryName($cleanupPath) -ne $tempParent -or
            ![IO.Path]::GetFileName($cleanupPath).StartsWith('codex-usage-')) {
            throw 'Refusing to remove an unexpected test directory.'
        }
        Remove-Item -LiteralPath $cleanupPath -Recurse -Force
    }
}
