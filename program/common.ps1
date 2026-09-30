# Shared helpers, dot-sourced by the other scripts. Not meant to be run directly.
$ErrorActionPreference = 'Stop'
$Root         = 'C:\actual-server'
$ConfigPath   = Join-Path $Root 'config.json'
$SettingsPath = Join-Path $Root 'settings.json'
$LogDir       = Join-Path $Root 'logs'
$RunDir       = Join-Path $Root 'run'
$StopFlag     = Join-Path $RunDir 'stop.flag'
$ServerEntry  = Join-Path $Root 'node_modules\@actual-app\sync-server\build\bin\actual-server.js'
$ServerTask   = 'ActualServer'
$BackupTask   = 'ActualBackup'

foreach ($d in $LogDir, $RunDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }

function Get-ActualConfig   { Get-Content $ConfigPath -Raw | ConvertFrom-Json }
function Get-ActualSettings { Get-Content $SettingsPath -Raw | ConvertFrom-Json }

function Get-DataDir {
    [IO.Path]::GetFullPath((Get-ActualConfig).dataDir)
}

function Get-ServerUrl {
    $c = Get-ActualConfig
    "http://127.0.0.1:$($c.port)"
}

function Get-NodeExe {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in "$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe") {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-NpmCmd {
    $node = Get-NodeExe
    if (-not $node) { return $null }
    Join-Path (Split-Path $node) 'npm.cmd'
}

# Runs a native program and returns its output (stdout and stderr) as strings.
# Needed because in Windows PowerShell 5.1 any stderr line (even a harmless warning) becomes a
# terminating error while $ErrorActionPreference is 'Stop'. Check $LASTEXITCODE afterwards.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
}

function Write-Log([string]$File, [string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path (Join-Path $LogDir $File) -Value $line -Encoding UTF8
    Write-Host $line
}

# Node processes running our server, and PowerShell supervisors running start-server.ps1.
function Get-ActualProcesses {
    $entry = $ServerEntry.ToLower()
    $script = (Join-Path $Root 'start-server.ps1').ToLower()
    Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object {
            $_.ProcessId -ne $PID -and $_.CommandLine -and (
                ($_.Name -eq 'node.exe' -and $_.CommandLine.ToLower().Contains($entry)) -or
                ($_.Name -ne 'node.exe' -and $_.CommandLine.ToLower().Contains($script)))
        }
}

function Test-ServerUp([string]$BaseUrl = (Get-ServerUrl), [int]$TimeoutSec = 3) {
    foreach ($path in '/health', '/') {
        try {
            $r = Invoke-WebRequest -Uri ($BaseUrl + $path) -UseBasicParsing -TimeoutSec $TimeoutSec
            if ($r.StatusCode -eq 200) { return $true }
        } catch { }
    }
    return $false
}

function Wait-ServerUp([string]$BaseUrl = (Get-ServerUrl), [int]$Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-ServerUp $BaseUrl) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# Command line used by the scheduled task: conhost --headless means no window ever appears.
$HiddenLauncher = "$env:WINDIR\System32\conhost.exe"
function Get-HiddenArgs([string]$Script) {
    "--headless powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""
}

function Start-ActualServer {
    if (Test-Path $StopFlag) { Remove-Item $StopFlag -Force }
    if (Get-ScheduledTask -TaskName $ServerTask -ErrorAction SilentlyContinue) {
        Start-ScheduledTask -TaskName $ServerTask
    } else {
        Start-Process $HiddenLauncher -ArgumentList (Get-HiddenArgs (Join-Path $Root 'start-server.ps1')) -WorkingDirectory $Root
    }
}

# Other programs (e.g. a Docker container) already listening on our port.
function Get-ForeignListeners {
    $port = (Get-ActualConfig).port
    $ours = @(Get-ActualProcesses | ForEach-Object { [int]$_.ProcessId })
    Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $ours -notcontains $_.OwningProcess } |
        ForEach-Object { '{0} ({1}:{2})' -f (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName, $_.LocalAddress, $port } |
        Select-Object -Unique
}

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TailscaleExe {
    $cmd = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = "$env:ProgramFiles\Tailscale\tailscale.exe"
    if (Test-Path $p) { return $p }
    return $null
}
