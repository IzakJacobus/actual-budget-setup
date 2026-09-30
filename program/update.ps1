# Updates the sync server: stop -> backup (while stopped) -> npm update -> start -> health check.
#   powershell -ExecutionPolicy Bypass -File C:\actual-server\update.ps1              # latest
#   powershell -ExecutionPolicy Bypass -File C:\actual-server\update.ps1 -Version 26.9.0
#   add -Yes to skip the confirmation question.
# New versions may upgrade your data in a way older versions can't read. That's why a backup is made
# first and the exact old->new versions are shown before anything changes.
param([string]$Version = 'latest', [switch]$Yes)
. "$PSScriptRoot\common.ps1"

$pkgJson = Join-Path $Root 'node_modules\@actual-app\sync-server\package.json'
$old = (Get-Content $pkgJson -Raw | ConvertFrom-Json).version
$target = @(Invoke-Native (Get-NpmCmd) @('view', "@actual-app/sync-server@$Version", 'version') |
    Where-Object { $_ -match '^\s*[''"]?\d+\.\d+\.\d+' }) | Select-Object -Last 1
if ($LASTEXITCODE -ne 0 -or -not $target) { throw "Could not find version '$Version' of @actual-app/sync-server on npm." }
$target = ($target -replace "^.*?(\d+\.\d+\.\d+[^'`"\s]*).*$", '$1')
Write-Host "Installed version: $old"
Write-Host "Update to:         $target"
if ($target -eq $old) { Write-Host 'Already on that version. Nothing to do.' -ForegroundColor Green; exit 0 }
if (-not $Yes) {
    Write-Host 'Release notes: https://actualbudget.org/blog'
    if ((Read-Host 'A backup is made first. Continue? (y/n)') -ne 'y') { Write-Host 'Cancelled.'; exit 0 }
}
$Version = $target

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
