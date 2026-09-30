# Starts the Actual sync server and keeps it running (restarts it if it crashes).
# Normally launched hidden by the "ActualServer" scheduled task at logon.
# Output goes to logs\server.log, rotated at logMaxMB (settings.json), keeping logKeep old files.
. "$PSScriptRoot\common.ps1"

# Only one supervisor at a time.
$mutex = New-Object Threading.Mutex($false, 'Local\ActualServerSupervisor')
if (-not $mutex.WaitOne(0)) { Write-Host 'ActualServer is already running.'; exit 0 }

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Diagnostics;
public class ActualLogPump : IDisposable {
    private readonly string path; private readonly long maxBytes; private readonly int keep;
    private readonly object sync = new object(); private StreamWriter writer;
    public ActualLogPump(string path, long maxBytes, int keep) {
        this.path = path; this.maxBytes = maxBytes; this.keep = keep; Open();
    }
    private void Open() {
        var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        writer = new StreamWriter(fs); writer.AutoFlush = true;
    }
    private void Rotate() {
        writer.Dispose();
        string oldest = path + "." + keep;
        if (File.Exists(oldest)) File.Delete(oldest);
        for (int i = keep - 1; i >= 1; i--) {
            string src = path + "." + i;
            if (File.Exists(src)) File.Move(src, path + "." + (i + 1));
        }
        File.Move(path, path + ".1");
        Open();
    }
    public void Write(string line) {
        if (line == null) return;
        lock (sync) {
            writer.WriteLine(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + line);
            if (writer.BaseStream.Length > maxBytes) { try { Rotate(); } catch { if (writer == null) Open(); } }
        }
    }
    public void Attach(Process p) {
        p.OutputDataReceived += (s, e) => Write(e.Data);
        p.ErrorDataReceived  += (s, e) => Write(e.Data);
    }
    public void Dispose() { lock (sync) { writer.Dispose(); } }
}
'@

$settings = Get-ActualSettings
$log = New-Object ActualLogPump((Join-Path $LogDir 'server.log'), ([long]$settings.logMaxMB * 1MB), [int]$settings.logKeep)
function Say([string]$m) { $log.Write("[launcher] $m") }

try {
    if (Test-Path $StopFlag) { Remove-Item $StopFlag -Force }
    Say "Supervisor starting (pid $PID)."

    $node = Get-NodeExe
    if (-not $node) { Say 'ERROR: node.exe not found. Install Node.js LTS.'; exit 1 }
    if (-not (Test-Path $ServerEntry)) { Say "ERROR: $ServerEntry missing. Run: npm install in $Root"; exit 1 }

    # Clean up a server left behind by a supervisor that died.
    Get-ActualProcesses | Where-Object Name -eq 'node.exe' | ForEach-Object {
        Say "Stopping leftover server process $($_.ProcessId)."
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $foreign = @(Get-ForeignListeners)
    if ($foreign.Count -gt 0) { Say "WARNING: port already used by: $($foreign -join ', '). Requests may reach that program instead." }

    # Backup once at start, while the server is not running (fully consistent copy).
    try {
        & "$PSScriptRoot\backup.ps1" -Reason startup *>&1 | ForEach-Object { Say "[backup] $_" }
    } catch { Say "Startup backup failed: $($_.Exception.Message)" }

    $delay = 5
    while ($true) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $node
        $psi.Arguments = "`"$ServerEntry`" --config `"$ConfigPath`""
        $psi.WorkingDirectory = $Root
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['ACTUAL_CONFIG_PATH'] = $ConfigPath
        $psi.EnvironmentVariables['NODE_ENV'] = 'production'

        $p = New-Object Diagnostics.Process
        $p.StartInfo = $psi
        $log.Attach($p)
        $started = Get-Date
        [void]$p.Start()
        $p.BeginOutputReadLine(); $p.BeginErrorReadLine()
        Say "Server started (node pid $($p.Id)) -> $(Get-ServerUrl)"
        $p.WaitForExit()
        $p.WaitForExit()   # second call flushes async output
        $code = $p.ExitCode; $p.Dispose()

        if (Test-Path $StopFlag) { Say 'Stop requested; supervisor exiting.'; break }

        # Back off if it keeps crashing right after start; reset once it has run a while.
        if (((Get-Date) - $started).TotalSeconds -gt 120) { $delay = 5 } else { $delay = [Math]::Min($delay * 2, 300) }
        Say "Server exited with code $code. Restarting in $delay s."
        Start-Sleep -Seconds $delay
        if (Test-Path $StopFlag) { Say 'Stop requested; supervisor exiting.'; break }
    }
}
finally {
    $log.Dispose()
    $mutex.ReleaseMutex()
}
