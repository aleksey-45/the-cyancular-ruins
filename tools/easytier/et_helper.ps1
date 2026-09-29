# CyR EasyTier elevated helper (ASCII only - see AGENTS.md encoding rules).
# Started by et_elevate.ps1 through UAC. Reads session.json in the session dir:
#   core_path : absolute path to easytier-core.exe
#   core_args : array of command line arguments for the core
#   game_pid  : game process id; when it exits, the core is stopped too
#   host_mode : 1 = also add game server firewall rules (UDP 7777 + 7800-8299)
# What it does: kill stale core -> add firewall rules (idempotent) -> start the
# core hidden with logs redirected -> supervise until stop.flag appears or the
# game exits -> kill the core. The game never needs to run elevated itself.
param(
    [string]$SessionDir = ""
)
$ErrorActionPreference = "Continue"
if ($SessionDir -eq "") { $SessionDir = $PSScriptRoot }

$cfgPath = Join-Path $SessionDir "session.json"
if (-not (Test-Path $cfgPath)) { exit 2 }
$cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
# Game writes forward-slash paths; firewall rules match reliably on backslashes.
$corePath = [string]$cfg.core_path -replace '/', '\'

# Kill a stale core from a previous session (helper died before cleanup).
$pidFile = Join-Path $SessionDir "core.pid"
if (Test-Path $pidFile) {
    $oldPid = (Get-Content $pidFile -Raw).Trim()
    if ($oldPid -match '^[0-9]+$') {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}

# Firewall rules. Delete-then-add keeps them idempotent across runs.
$FW = "C:\Windows\System32\netsh.exe"
& $FW advfirewall firewall delete rule name="CyR EasyTier Core" | Out-Null
& $FW advfirewall firewall add rule name="CyR EasyTier Core" dir=in action=allow program="$corePath" enable=yes profile=any | Out-Null
if ([int]$cfg.host_mode -eq 1) {
    & $FW advfirewall firewall delete rule name="CyR Lobby UDP 7777" | Out-Null
    & $FW advfirewall firewall add rule name="CyR Lobby UDP 7777" dir=in action=allow protocol=UDP localport=7777 | Out-Null
    & $FW advfirewall firewall delete rule name="CyR Workers UDP 7800-8299" | Out-Null
    & $FW advfirewall firewall add rule name="CyR Workers UDP 7800-8299" dir=in action=allow protocol=UDP localport=7800-8299 | Out-Null
}

$outLog = Join-Path $SessionDir "core.log"
$errLog = Join-Path $SessionDir "core.err.log"
$stopFlag = Join-Path $SessionDir "stop.flag"
if (Test-Path $stopFlag) { Remove-Item $stopFlag -ErrorAction SilentlyContinue }

$p = Start-Process -FilePath $corePath -ArgumentList $cfg.core_args `
    -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru
if ($null -eq $p) { exit 3 }
$p.Id | Out-File -FilePath $pidFile -Encoding ascii

# Supervise: stop on stop.flag, game exit, or core death.
while ($true) {
    Start-Sleep -Milliseconds 1500
    if (Test-Path $stopFlag) { break }
    if ($p.HasExited) { break }
    $g = Get-Process -Id ([int]$cfg.game_pid) -ErrorAction SilentlyContinue
    if (-not $g) { break }
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Remove-Item $stopFlag -ErrorAction SilentlyContinue
