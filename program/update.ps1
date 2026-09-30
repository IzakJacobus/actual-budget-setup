# Updates the sync server: stop -> backup (while stopped) -> npm update -> start -> health check.
#   powershell -ExecutionPolicy Bypass -File C:\actual-server\update.ps1              # latest
#   powershell -ExecutionPolicy Bypass -File C:\actual-server\update.ps1 -Version 26.9.0
param([string]$Version = 'latest')
. "$PSScriptRoot\common.ps1"

$pkgJson = Join-Path $Root 'node_modules\@actual-app\sync-server\package.json'
$old = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version
Write-Host "Current version: $old"

& "$PSScriptRoot\stop-server.ps1"
& "$PSScriptRoot\backup.ps1" -Reason pre-update
if ($LASTEXITCODE -ne 0) { Start-ActualServer; throw 'Backup failed; update cancelled and server restarted.' }
$backup = Get-ChildItem ([Environment]::ExpandEnvironmentVariables((Get-ActualSettings).backupDir)) -Filter 'actual-data_*_pre-update.zip' |
    Sort-Object Name -Descending | Select-Object -First 1

Push-Location $Root
try {
    & (Get-NpmCmd) install --no-fund --no-audit --save-exact "@actual-app/sync-server@$Version"
    $npmExit = $LASTEXITCODE
} finally { Pop-Location }
$new = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version

Start-ActualServer
if ($npmExit -eq 0 -and (Wait-ServerUp -Seconds 90)) {
    Write-Log 'server.log' "[update] $old -> $new OK"
    Write-Host "Updated $old -> $new; server is up at $(Get-ServerUrl)" -ForegroundColor Green
} else {
    Write-Warning "Update to $new did not come up cleanly (npm exit $npmExit). See logs\server.log."
    Write-Host "Roll back with:"
    Write-Host "  .\stop-server.ps1"
    Write-Host "  npm install --save-exact @actual-app/sync-server@$old"
    Write-Host "  .\restore.ps1 -BackupZip `"$($backup.FullName)`""
    exit 1
}
