# Restores a backup zip made by backup.ps1.
#
# Test a backup without touching live data (extracts to a temp folder and boots a throwaway server on port 5007):
#   .\restore.ps1 -BackupZip .\backups\actual-data_....zip -TargetDir C:\Temp\actual-restore-test -Verify
#
# Restore over the live data (stops the server, keeps the current data as data.before-restore-<time>, restarts):
#   .\restore.ps1 -BackupZip .\backups\actual-data_....zip
param(
    [Parameter(Mandatory = $true)][string]$BackupZip,
    [string]$TargetDir,
    [switch]$Verify,
    [int]$VerifyPort = 5007
)
. "$PSScriptRoot\common.ps1"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$BackupZip = (Resolve-Path $BackupZip).Path
$dataDir   = Get-DataDir
$live      = (-not $TargetDir) -or ([IO.Path]::GetFullPath($TargetDir).TrimEnd('\') -ieq $dataDir.TrimEnd('\'))
$target    = if ($live) { $dataDir } else { [IO.Path]::GetFullPath($TargetDir) }

function Expand-Backup([string]$zip, [string]$to) {
    New-Item -ItemType Directory -Path $to -Force | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $to)
    foreach ($f in '_backup-manifest.json', '_config.json') {
        $p = Join-Path $to $f; if (Test-Path $p) { Remove-Item $p -Force }
    }
}

if ($live) {
    Write-Host "Restoring $BackupZip over LIVE data in $dataDir"
    & "$PSScriptRoot\stop-server.ps1"
    & "$PSScriptRoot\backup.ps1" -Reason pre-restore
    if ($LASTEXITCODE -ne 0) { throw 'Safety backup of current data failed; nothing was changed.' }
    $keepAs = "$dataDir.before-restore-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
    Rename-Item $dataDir $keepAs
    Expand-Backup $BackupZip $dataDir
    Write-Host "Restored. Previous data kept at $keepAs"
    if (Get-ScheduledTask -TaskName $ServerTask -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $ServerTask
        if (Wait-ServerUp) { Write-Host "Server is up at $(Get-ServerUrl)" } else { Write-Warning 'Server did not come up; see logs\server.log' }
    } else {
        Write-Host 'Start the server with start-server.ps1.'
    }
    exit 0
}

if ((Test-Path $target) -and (Get-ChildItem $target -Force | Select-Object -First 1)) {
    throw "Target folder $target is not empty. Choose an empty or new folder."
}
Expand-Backup $BackupZip $target
Write-Host "Extracted to $target"
Get-ChildItem $target -Recurse -File | ForEach-Object { '  {0,10:N0}  {1}' -f $_.Length, $_.FullName.Substring($target.Length) }

if ($Verify) {
    $node = Get-NodeExe
    $cfgFile = Join-Path $env:TEMP "actual-verify-config-$PID.json"
    $outLog = Join-Path $env:TEMP "actual-verify-$PID.log"
    # No BOM: the server's config loader rejects it.
    [IO.File]::WriteAllText($cfgFile, ([ordered]@{
        dataDir     = $target
        serverFiles = (Join-Path $target 'server-files')
        userFiles   = (Join-Path $target 'user-files')
        hostname    = '127.0.0.1'
        port        = $VerifyPort
    } | ConvertTo-Json))
    $p = Start-Process $node -ArgumentList "`"$ServerEntry`" --config `"$cfgFile`"" -WorkingDirectory $Root `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError "$outLog.err"
    try {
        $url = "http://127.0.0.1:$VerifyPort"
        if (-not (Wait-ServerUp $url 90)) {
            Get-Content $outLog, "$outLog.err" -ErrorAction SilentlyContinue | Select-Object -Last 20 | Write-Host
            throw "Test server from restored data did not start on $url"
        }
        $boot = Invoke-RestMethod "$url/account/needs-bootstrap" -TimeoutSec 5
        Write-Host "VERIFY OK: server started from restored data on $url; password already set = $($boot.data.bootstrapped)"
    } finally {
        if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
        Remove-Item $cfgFile, $outLog, "$outLog.err" -Force -ErrorAction SilentlyContinue
    }
}
