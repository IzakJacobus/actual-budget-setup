# Stops the server and removes the ActualServer / ActualBackup scheduled tasks.
# It NEVER deletes the data folder, the backups, logs, config or the installed package.
#   powershell -ExecutionPolicy Bypass -File C:\actual-server\uninstall.ps1 [-RemoveTailscaleServe]
param([switch]$RemoveTailscaleServe)
. "$PSScriptRoot\common.ps1"

& "$PSScriptRoot\stop-server.ps1"
foreach ($t in $ServerTask, $BackupTask) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        Write-Host "Removed task $t"
    }
}
if ($RemoveTailscaleServe) {
    $ts = Get-TailscaleExe
    if ($ts) { & $ts serve --https=443 off; Write-Host 'Tailscale serve turned off.' }
}
Write-Host "Kept: data folder $(Get-DataDir), backups in $((Get-ActualSettings).backupDir), config and logs."
