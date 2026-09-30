#Requires -RunAsAdministrator
# One-time setup. Easiest: double-click Install.cmd. Or, from an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File C:\actual-server\install.ps1
#
# What it changes (and nothing else):
#   0. If run from somewhere else (e.g. Downloads), copies these files to C:\actual-server first.
#   1. Installs Node.js LTS with winget, only if Node 22+ is missing and you answer y.
#   2. Installs @actual-app/sync-server into C:\actual-server\node_modules (not global).
#   3. Registers scheduled task "ActualServer" (at your logon, hidden, restarts on failure, runs on battery).
#   4. Registers scheduled task "ActualBackup" (daily at backupTime from settings.json, catches up if missed).
#   5. Starts the server (on 127.0.0.1 only).
#   6. Installs Tailscale with winget if missing and you answer y, then:
#      tailscale serve --bg --https=443 http://127.0.0.1:5006
#      (tailnet-only HTTPS; NOT Funnel, no router ports, no firewall rules).
param(
    [string]$User = (Get-CimInstance Win32_ComputerSystem).UserName,
    [switch]$SkipTailscale
)
$ErrorActionPreference = 'Stop'
$Home_ = 'C:\actual-server'

# 0. Make sure we run from C:\actual-server (the scripts expect that folder).
#    The package never contains data, so copying it can't overwrite a budget. On a re-run over an
#    existing install, your config/settings and the installed server version (package*.json) are kept.
if ($PSScriptRoot.TrimEnd('\') -ine $Home_) {
    $existing = Test-Path "$Home_\install.ps1"
    Write-Host $(if ($existing) { "Updating scripts in $Home_ (your data and settings are kept) ..." } else { "Copying files to $Home_ ..." }) -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $Home_ -Force | Out-Null
    $keepIfPresent = 'config.json', 'settings.json', 'package.json', 'package-lock.json'
    foreach ($f in Get-ChildItem $PSScriptRoot -File) {
        if ($existing -and $keepIfPresent -contains $f.Name -and (Test-Path "$Home_\$($f.Name)")) { continue }
        Copy-Item $f.FullName $Home_ -Force
    }
    $guide = Join-Path (Split-Path $PSScriptRoot) 'READ ME FIRST.txt'
    if (Test-Path $guide) { Copy-Item $guide $Home_ -Force }
    & "$Home_\install.ps1" @PSBoundParameters
    exit $LASTEXITCODE
}
Get-ChildItem $PSScriptRoot -File | Unblock-File   # files from a downloaded zip are marked "from the internet"

. "$PSScriptRoot\common.ps1"
$settings = Get-ActualSettings
if (-not $User) { throw 'Could not determine the logged-on user; pass -User COMPUTER\name' }
Write-Host "Setting up Actual server for user $User" -ForegroundColor Cyan
foreach ($d in (Get-DataDir), [Environment]::ExpandEnvironmentVariables($settings.backupDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# 1. Node.js
$node = Get-NodeExe
$nodeMajor = if ($node) { [int]((& $node --version).TrimStart('v').Split('.')[0]) } else { 0 }
if ($nodeMajor -lt 22) {
    $ans = Read-Host "Node.js 22+ not found (found: $nodeMajor). Install Node.js LTS with winget now? (y/n)"
    if ($ans -ne 'y') { throw 'Node.js 22+ is required.' }
    winget install --id OpenJS.NodeJS.LTS -e --accept-source-agreements --accept-package-agreements
    Refresh-Path
    $node = Get-NodeExe
    if (-not $node) { throw 'Node.js install did not complete.' }
}
Write-Host "Node: $(& $node --version)"

# 2. Sync server package (local, pinned version)
$npm = Get-NpmCmd
Push-Location $Root
try {
    $pkg = Get-Content (Join-Path $Root 'package.json') -Raw | ConvertFrom-Json
    if ($pkg.dependencies.'@actual-app/sync-server') { & $npm install --no-fund --no-audit }
    else { & $npm install --no-fund --no-audit --save-exact '@actual-app/sync-server' }
    if ($LASTEXITCODE -ne 0) { throw 'npm install failed.' }
} finally { Pop-Location }
if (-not (Test-Path $ServerEntry)) { throw "Server entry not found: $ServerEntry" }

# 3 + 4. Scheduled tasks (run as you, only while you're logged on, no admin rights needed at run time)
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited

$serverAction = New-ScheduledTaskAction -Execute $HiddenLauncher -Argument (Get-HiddenArgs "$Root\start-server.ps1") -WorkingDirectory $Root
$serverSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -DontStopOnIdleEnd -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $ServerTask -Force -Principal $principal -Action $serverAction `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $User) -Settings $serverSettings `
    -Description 'Actual Budget sync server (C:\actual-server). Hidden; restarts on failure.' | Out-Null
Write-Host "Registered task $ServerTask"

$backupAction = New-ScheduledTaskAction -Execute $HiddenLauncher -Argument ((Get-HiddenArgs "$Root\backup.ps1") + ' -Reason daily') -WorkingDirectory $Root
$backupSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $BackupTask -Force -Principal $principal -Action $backupAction `
    -Trigger (New-ScheduledTaskTrigger -Daily -At $settings.backupTime) -Settings $backupSettings `
    -Description 'Daily backup of C:\actual-server data (keeps last N, see settings.json).' | Out-Null
Write-Host "Registered task $BackupTask (daily at $($settings.backupTime))"

# 5. Start
$foreign = @(Get-ForeignListeners)
if ($foreign.Count -gt 0) {
    throw "Port $((Get-ActualConfig).port) is already used by: $($foreign -join ', '). Stop that program (e.g. an old Docker container) or change 'port' in config.json, then re-run."
}
if (@(Get-ActualProcesses).Count -eq 0) { Start-ActualServer }
if (Wait-ServerUp -Seconds 90) { Write-Host "Server is up at $(Get-ServerUrl)" -ForegroundColor Green }
else { Write-Warning 'Server did not respond yet; check C:\actual-server\logs\server.log' }

# 6. Tailscale: HTTPS access from your phone, only for your own devices.
function Get-TsStatus($ts) {
    $ErrorActionPreference = 'Continue'   # tailscale may write to stderr; see Invoke-Native in common.ps1
    try { ((& $ts status --json 2>$null) -join "`n") | ConvertFrom-Json } catch { $null }
}
$phoneUrl = $null
$ts = Get-TailscaleExe
if (-not $SkipTailscale -and -not $ts) {
    $ans = Read-Host 'Tailscale (needed for phone access) is not installed. Install it with winget now? (y/n)'
    if ($ans -eq 'y') {
        winget install --id Tailscale.Tailscale -e --accept-source-agreements --accept-package-agreements
        Refresh-Path
        $ts = Get-TailscaleExe
    }
}
if ($SkipTailscale) { }
elseif (-not $ts) { Write-Host 'Skipping phone access: Tailscale not installed. Run Install.cmd again later.' -ForegroundColor Yellow }
else {
    $st = Get-TsStatus $ts
    while (-not $st -or $st.BackendState -ne 'Running') {
        Write-Host ''
        Write-Host 'Sign in to Tailscale: click the Tailscale icon near the clock (you may need the ^ arrow),' -ForegroundColor Yellow
        Write-Host 'choose "Log in", and sign in in the browser. Use a free personal account.' -ForegroundColor Yellow
        if ((Read-Host 'Press Enter when signed in (or type s to skip)') -eq 's') { break }
        $st = Get-TsStatus $ts
    }
    while ($st -and $st.BackendState -eq 'Running' -and -not $st.CertDomains) {
        Write-Host ''
        Write-Host 'Turn on HTTPS for your Tailscale network (one time):' -ForegroundColor Yellow
        Write-Host '  1. Open https://login.tailscale.com/admin/dns' -ForegroundColor Yellow
        Write-Host '  2. Make sure MagicDNS is enabled.' -ForegroundColor Yellow
        Write-Host '  3. Under "HTTPS Certificates" click "Enable HTTPS".' -ForegroundColor Yellow
        if ((Read-Host 'Press Enter when done (or type s to skip)') -eq 's') { break }
        Start-Sleep -Seconds 3
        $st = Get-TsStatus $ts
    }
    if ($st -and $st.CertDomains) {
        $port = (Get-ActualConfig).port
        & $ts serve --bg --https=443 "http://127.0.0.1:$port"
        $phoneUrl = "https://$($st.Self.DNSName.TrimEnd('.'))"
        Set-Content (Join-Path $Root 'PHONE-URL.txt') "Open this on your phone (with the Tailscale app on):`r`n$phoneUrl" -Encoding UTF8
        Write-Host "Phone URL: $phoneUrl  (also saved in C:\actual-server\PHONE-URL.txt)" -ForegroundColor Green
    } else {
        Write-Host 'Phone access not set up yet. Finish the Tailscale steps and run Install.cmd again.' -ForegroundColor Yellow
    }
}

Write-Host ''
$boot = try { (Invoke-RestMethod "$(Get-ServerUrl)/account/needs-bootstrap" -TimeoutSec 5).data.bootstrapped } catch { $null }
if ($boot -eq $false) { Write-Host 'Done. Next: open http://localhost:5006 and create your server password (see READ ME FIRST.txt).' -ForegroundColor Green }
else { Write-Host 'Done. Open http://localhost:5006 and log in (see READ ME FIRST.txt).' -ForegroundColor Green }
