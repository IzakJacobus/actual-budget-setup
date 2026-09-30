# Backs up the Actual data folder to a zip in backupDir (settings.json), keeping the newest keepBackups.
# Safe while the server is running: SQLite files are copied with SQLite's online backup API
# (a consistent snapshot) and integrity-checked; other files are copied and verified unchanged.
#   .\backup.ps1                       manual backup
#   .\backup.ps1 -Destination D:\x     one-off different destination
param(
    [string]$Reason = 'manual',
    [string]$Destination
)
. "$PSScriptRoot\common.ps1"

$settings = Get-ActualSettings
$dataDir  = Get-DataDir
$dest     = if ($Destination) { $Destination } else { [Environment]::ExpandEnvironmentVariables($settings.backupDir) }
$keep     = [int]$settings.keepBackups
$stamp    = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$name     = "actual-data_${stamp}_$Reason.zip"
$stage    = Join-Path $env:TEMP "actual-backup-$stamp-$PID"

function BLog([string]$m) { Write-Log 'backup.log' $m }

try {
    if (-not (Test-Path $dataDir)) { throw "Data folder not found: $dataDir" }
    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $cfg = Get-ActualConfig
    foreach ($d in $cfg.serverFiles, $cfg.userFiles) {
        if (-not [IO.Path]::GetFullPath($d).StartsWith($dataDir, [StringComparison]::OrdinalIgnoreCase)) {
            BLog "WARNING: $d is outside the data folder and is NOT included in backups."
        }
    }

    New-Item -ItemType Directory -Path $stage | Out-Null
    $files = @(Get-ChildItem $dataDir -Recurse -File -Force |
        Where-Object { $_.Name -notmatch '-(wal|shm|journal)$' })   # WAL content is captured by the SQLite backup
    $sqlite = @($files | Where-Object { $_.Extension -eq '.sqlite' -or $_.Extension -eq '.db' })
    $other  = @($files | Where-Object { $sqlite -notcontains $_ })

    function RelPath($f) { $f.FullName.Substring($dataDir.Length).TrimStart('\', '/') }

    if ($sqlite.Count -gt 0) {
        $node = Get-NodeExe
        if (-not $node) { throw 'node.exe not found; needed for safe SQLite backup.' }
        $pairs = @($sqlite | ForEach-Object { @{ src = $_.FullName; dst = (Join-Path $stage (RelPath $_)) } })
        $pairsFile = Join-Path $stage '_pairs.json'
        [IO.File]::WriteAllText($pairsFile, (ConvertTo-Json -InputObject $pairs -Depth 3))
        $out = & $node (Join-Path $Root 'sqlite-backup.cjs') $pairsFile 2>&1
        $nodeExit = $LASTEXITCODE
        Remove-Item $pairsFile -Force
        if ($nodeExit -ne 0) { throw "SQLite backup failed: $out" }
    }

    foreach ($f in $other) {
        $target = Join-Path $stage (RelPath $f)
        New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
        for ($try = 1; ; $try++) {
            $before = Get-Item -LiteralPath $f.FullName -Force
            Copy-Item -LiteralPath $f.FullName -Destination $target -Force
            $after = Get-Item -LiteralPath $f.FullName -Force
            if ($before.Length -eq $after.Length -and $before.LastWriteTimeUtc -eq $after.LastWriteTimeUtc) { break }
            if ($try -ge 5) { throw "File kept changing during backup: $($f.FullName)" }
            Start-Sleep -Seconds 2
        }
    }

    $manifest = [ordered]@{
        created   = (Get-Date).ToString('o')
        reason    = $Reason
        computer  = $env:COMPUTERNAME
        dataDir   = $dataDir
        serverVersion = $(try { (Get-Content (Join-Path $Root 'node_modules\@actual-app\sync-server\package.json') -Raw | ConvertFrom-Json).version } catch { 'unknown' })
        files     = @($files | ForEach-Object { RelPath $_ })
    }
    $manifest | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $stage '_backup-manifest.json') -Encoding UTF8
    Copy-Item $ConfigPath (Join-Path $stage '_config.json')

    # Write under a temp name, then rename, so a half-written zip never looks like a backup.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmp = Join-Path $dest ".partial-$name"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $tmp, [IO.Compression.CompressionLevel]::Optimal, $false)
    Move-Item $tmp (Join-Path $dest $name)

    $old = @(Get-ChildItem $dest -Filter 'actual-data_*.zip' -File | Sort-Object Name -Descending | Select-Object -Skip $keep)
    $old | Remove-Item -Force
    BLog "OK $Reason backup: $(Join-Path $dest $name) ($($files.Count) files; pruned $($old.Count) old)"
    exit 0
}
catch {
    BLog "FAILED $Reason backup: $($_.Exception.Message)"
    exit 1
}
finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
