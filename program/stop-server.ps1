# Stops the Actual sync server and its supervisor. Data is not touched.
# It starts again at next logon, or now with:  Start-ScheduledTask ActualServer
. "$PSScriptRoot\common.ps1"

New-Item -ItemType File -Path $StopFlag -Force | Out-Null
if (Get-ScheduledTask -TaskName $ServerTask -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $ServerTask -ErrorAction SilentlyContinue
}
# Supervisor first so it cannot restart node, then node itself.
$procs = @(Get-ActualProcesses)
$procs | Where-Object Name -ne 'node.exe' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$procs | Where-Object Name -eq 'node.exe' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

for ($i = 0; $i -lt 15 -and @(Get-ActualProcesses).Count -gt 0; $i++) { Start-Sleep -Seconds 1 }
if (@(Get-ActualProcesses).Count -gt 0) { Write-Warning 'Server processes still running.'; exit 1 }
Write-Log 'server.log' '[stop-server] Actual server stopped.'
