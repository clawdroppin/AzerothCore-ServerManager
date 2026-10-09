<#
  AzerothCore server control: Start / Stop / Restart / Status / Monitor.
  Called by START_SERVER.bat and STOP_SERVER.bat in the root folder, by the Control Center app,
  and by the optional daily-restart scheduled task (-Action Restart -WarnMinutes 5 -OnlyIfRunning).
#>
param(
    [ValidateSet('Start', 'Stop', 'Restart', 'Status', 'Monitor')]
    [string]$Action = 'Status',
    [switch]$NoMonitor,
    [switch]$NoBridge,
    [int]$WarnMinutes = 0,
    [switch]$OnlyIfRunning
)

$ErrorActionPreference = 'Stop'
$Root      = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $Root 'server'
$LogDir    = Join-Path $ServerDir 'logs'
$CtlLog    = Join-Path $LogDir 'server-control.log'
$StopFlag  = Join-Path $ServerDir 'stop.requested'
$SecretsFile = Join-Path $Root 'secrets\soap.txt'
$Settings  = Get-Content (Join-Path $PSScriptRoot 'server-settings.json') -Raw | ConvertFrom-Json
$MySqlService = $Settings.MySqlService
if (-not $Settings.Llm.Enabled) { $NoBridge = $true }
# The bridge runs from its own copy (server\llm-bridge); older installs run it from the module source.
$BridgeDir    = Join-Path $ServerDir 'llm-bridge'
if (-not (Test-Path (Join-Path $BridgeDir 'llm_chatter_bridge.py'))) { $BridgeDir = Join-Path $Root 'azerothcore-wotlk\modules\mod-llm-chatter\tools' }
$BridgePython = Join-Path $ServerDir 'llm-bridge-venv\Scripts\python.exe'
$BridgeConf   = Join-Path $ServerDir 'configs\modules\mod_llm_chatter.conf'
$Ports = @{ MySQL = [int]$Settings.DbPort; Auth = 3724; World = 8085; Soap = [int]$Settings.SoapPort; Ollama = 11434 }
. (Join-Path $PSScriptRoot 'DbSlot.ps1')   # shared database port: swap databases, check identity

New-Item -ItemType Directory -Force $LogDir | Out-Null
# Inherited by authserver/worldserver: create missing databases (e.g. acore_playerbots) without prompting.
$env:AC_DISABLE_INTERACTIVE = '1'

function Write-Log([string]$msg, [string]$level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $msg
    Add-Content -Path $CtlLog -Value $line
    $color = switch ($level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
    Write-Host $line -ForegroundColor $color
}

function Test-Port([int]$port) {
    [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

function Wait-Port([int]$port, [int]$timeoutSec, [string]$name, [System.Diagnostics.Process]$proc) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        if (Test-Port $port) { return $true }
        if ($proc -and $proc.HasExited) {
            Write-Log "$name exited during startup (exit code $($proc.ExitCode))." 'ERROR'
            return $false
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "$name did not open port $port within $timeoutSec s." 'ERROR'
    return $false
}

function Get-ServerProc([string]$name) {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($ServerDir, [StringComparison]::OrdinalIgnoreCase) }
}

function Get-BridgeProc {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*llm_chatter_bridge.py*' -and $_.CommandLine -like "*$ServerDir*" }
}

function Get-PortOwner([int]$port) {
    # Describes which program holds a port, e.g. another WoW server from a different folder.
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return $null }
    $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if (-not $p) { return "process $($conn.OwningProcess)" }
    if ($p.Path -and $p.Name -in 'worldserver', 'authserver') { return "another WoW server ($(Split-Path (Split-Path $p.Path -Parent) -Parent))" }
    "$($p.Name) ($($p.Path))"
}

# Optional Discord notices: secrets\discord-webhook.txt holds the webhook URL (set on the app's Play with friends page).
$WebhookFile = Join-Path $Root 'secrets\discord-webhook.txt'
function Send-Notice([string]$text, [string]$kind) {
    if (-not (Test-Path $WebhookFile)) { return }
    if ($Settings.Notify -and $Settings.Notify.$kind -eq $false) { return }
    try {
        $url = (Get-Content $WebhookFile -Raw).Trim()
        $body = @{ content = $text; username = 'AzerothCore Control Center' } | ConvertTo-Json
        Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null
    } catch { Write-Log "Discord notice failed: $($_.Exception.Message)" 'WARN' }
}

function Get-OnlinePlayers {
    # Names of real players online (not bots, not the auction house bot).
    $mysql = Join-Path $Settings.MySqlDir 'bin\mysql.exe'
    $sql = "SELECT c.name FROM acore_characters.characters c JOIN acore_auth.account a ON a.id = c.account WHERE c.online = 1 AND a.username NOT LIKE 'RNDBOT%' AND a.username <> 'AHBOT'"
    $ErrorActionPreference = 'Continue'
    @(& $mysql '-uacore' '-pacore' '--host=127.0.0.1' "--port=$($Ports.MySQL)" '-N' '-B' '-e' $sql 2>$null | Where-Object { $_ -and "$_" -notmatch 'Using a password' } | ForEach-Object { "$_".Trim() })
}

function Stop-MySqlIfOwned {
    if (-not $Settings.MySqlStopWithServer) { return }
    $svc = Get-Service $MySqlService -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return }
    try { Stop-Service $MySqlService -ErrorAction Stop; Write-Log "Database ($MySqlService) stopped to free memory." 'OK' }
    catch { Write-Log "Could not stop $MySqlService ($($_.Exception.Message)); it keeps running." 'WARN' }
}

function Invoke-Soap([string]$command) {
    if (-not (Test-Path $SecretsFile)) { throw "SOAP credentials file missing: $SecretsFile" }
    $creds = Get-Content $SecretsFile | ConvertFrom-StringData
    $pair  = '{0}:{1}' -f $creds.User, $creds.Password
    $auth  = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
    $body = @"
<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:AC">
  <SOAP-ENV:Body><ns1:executeCommand><command>$([Security.SecurityElement]::Escape($command))</command></ns1:executeCommand></SOAP-ENV:Body>
</SOAP-ENV:Envelope>
"@
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$($Ports.Soap)/" -Method Post -Body $body `
        -ContentType 'text/xml; charset=utf-8' -Headers @{ Authorization = $auth } -UseBasicParsing -TimeoutSec 30
    if ($resp.Content -match '<result>([\s\S]*?)</result>') { return $Matches[1].Trim() }
    return $resp.Content
}

function Start-MySql {
    $svc = Get-Service $MySqlService -ErrorAction SilentlyContinue
    if (-not $svc) { throw "MySQL service '$MySqlService' not found." }
    if ($svc.Status -ne 'Running') {
        # Shared database port: another server's database may be holding it - swap it out first.
        $holder = Get-DbPortService $Ports.MySQL
        if ($holder -and $holder.Name -and $holder.Name -ne $MySqlService) { Write-Log "Database port $($Ports.MySQL) is held by $($holder.Name); swapping in this server's database." }
        Enter-DatabaseSlot $Root $Settings
        Write-Log "Starting $MySqlService (admin prompt may appear)..."
        try { Start-Service $MySqlService }
        catch { Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -Command Start-Service $MySqlService" }
    }
    if (-not (Wait-Port $Ports.MySQL 60 'MySQL' $null)) { throw 'MySQL failed to start.' }
    if (-not (Test-DatabaseIdentity $Root $Settings)) { throw "The database on port $($Ports.MySQL) belongs to another server. Stop that server first (or run Check & repair in the app)." }
    Write-Log "MySQL is running on port $($Ports.MySQL)." 'OK'
}

function Start-Ollama {
    if (Test-Port $Ports.Ollama) { Write-Log 'Ollama already running.' 'OK'; return }
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (-not (Test-Path $exe)) { Write-Log 'Ollama not installed; LLM chatter will be silent.' 'WARN'; return }
    Write-Log 'Starting Ollama...'
    Start-Process $exe -ArgumentList 'serve' -WindowStyle Hidden
    if (Wait-Port $Ports.Ollama 30 'Ollama' $null) { Write-Log 'Ollama is running.' 'OK' }
}

function Start-Bridge {
    if ($NoBridge) { return }
    if (Get-BridgeProc) { Write-Log 'LLM chatter bridge already running.' 'OK'; return }
    if (-not (Test-Path $BridgeConf)) { Write-Log "Bridge config missing ($BridgeConf); skipping." 'WARN'; return }
    Write-Log 'Starting LLM chatter bridge...'
    $bridgeLog = Join-Path $LogDir 'llm-bridge.log'
    $env:PYTHONUNBUFFERED = '1'
    Start-Process $BridgePython -ArgumentList "llm_chatter_bridge.py --config `"$BridgeConf`"" `
        -WorkingDirectory $BridgeDir -WindowStyle Hidden `
        -RedirectStandardOutput $bridgeLog -RedirectStandardError (Join-Path $LogDir 'llm-bridge-error.log')
    Start-Sleep -Seconds 5
    if (Get-BridgeProc) { Write-Log 'LLM chatter bridge started.' 'OK' } else { Write-Log "Bridge failed to start; see $bridgeLog" 'WARN' }
}

function Start-WorldProcess {
    $p = Start-Process (Join-Path $ServerDir 'worldserver.exe') -WorkingDirectory $ServerDir -PassThru
    Write-Log "worldserver launched (PID $($p.Id)). First start imports databases and creates bot accounts; this can take several minutes."
    return $p
}

function Show-Status {
    $auth  = Get-ServerProc 'authserver'
    $world = Get-ServerProc 'worldserver'
    $mysql = Get-Service $MySqlService -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host ('  MySQL       : {0}' -f $(if ($mysql) { $mysql.Status } else { 'missing' }))
    Write-Host ('  authserver  : {0}' -f $(if ($auth) { "running (PID $($auth.Id))" } else { 'stopped' }))
    if ($world) {
        $mem = [math]::Round($world.WorkingSet64 / 1GB, 2)
        $up  = (Get-Date) - $world.StartTime
        Write-Host ('  worldserver : running (PID {0}, {1} GB RAM, up {2:dd\.hh\:mm\:ss})' -f $world.Id, $mem, $up)
        if (Test-Port $Ports.Soap) {
            try { Write-Host ('  server info : ' + ((Invoke-Soap 'server info') -replace '\s+', ' ')) } catch {}
        }
    } else { Write-Host '  worldserver : stopped' }
    Write-Host ('  LLM bridge  : {0}' -f $(if (Get-BridgeProc) { 'running' } else { 'stopped' }))
    if ($Settings.Llm.Enabled) { Write-Host ('  Ollama      : {0}' -f $(if (Test-Port $Ports.Ollama) { 'running' } else { 'stopped' })) }
    Write-Host ''
}

function Start-Monitor {
    Write-Log 'Health monitor active. Closing this window does NOT stop the server; use STOP_SERVER.bat.'
    $crashes = 0
    $watchLogins = (Test-Path $WebhookFile) -and -not ($Settings.Notify -and $Settings.Notify.OnLogin -eq $false)
    $online = if ($watchLogins) { Get-OnlinePlayers } else { @() }
    while ($true) {
        Start-Sleep -Seconds 30
        if (Test-Path $StopFlag) { Write-Log 'Stop requested; monitor exiting.'; return }
        if ($watchLogins -and (Get-ServerProc 'worldserver')) {
            $now = Get-OnlinePlayers
            foreach ($n in $now | Where-Object { $online -notcontains $_ }) { Send-Notice "👋 **$n** just logged in to $($Settings.RealmName)." 'OnLogin' }
            $online = $now
        }
        if (-not (Get-ServerProc 'worldserver')) {
            $crashes++
            Write-Log "worldserver is not running (unexpected exit #$crashes)." 'ERROR'
            Send-Notice "⚠️ $($Settings.RealmName) crashed$(if ($crashes -le 3) { ' - restarting it automatically' } else { ' again; automatic restarts are off until someone checks it' })." 'OnCrash'
            if ($crashes -gt 3) { Write-Log 'Too many crashes; auto-restart disabled. Check server\logs.' 'ERROR'; return }
            Write-Log 'Auto-restarting worldserver in 10 s...' 'WARN'
            Start-Sleep -Seconds 10
            $p = Start-WorldProcess
            if (Wait-Port $Ports.World 900 'worldserver' $p) { Write-Log 'worldserver restarted.' 'OK' }
        }
        if (-not (Get-ServerProc 'authserver')) {
            Write-Log 'authserver is not running; restarting.' 'WARN'
            Start-Process (Join-Path $ServerDir 'authserver.exe') -WorkingDirectory $ServerDir | Out-Null
        }
        if (-not $NoBridge -and -not (Get-BridgeProc) -and (Test-Path $BridgeConf)) {
            Write-Log 'LLM bridge is not running; restarting.' 'WARN'
            Start-Bridge
        }
        $world = Get-ServerProc 'worldserver'
        if ($world) {
            Write-Host ('{0}  healthy  worldserver {1} GB RAM' -f (Get-Date -Format 'HH:mm:ss'), [math]::Round($world.WorkingSet64 / 1GB, 2)) -ForegroundColor DarkGray
        }
    }
}

function Stop-AllServers([switch]$KeepDatabase) {
    Write-Log '===== STOP requested ====='
    Set-Content $StopFlag (Get-Date -Format o)

    $world = Get-ServerProc 'worldserver'
    if ($world) {
        $graceful = $false
        if (Test-Port $Ports.Soap) {
            try {
                Write-Log ('saveall: ' + (Invoke-Soap 'saveall'))
                Start-Sleep -Seconds 5
                Write-Log ('shutdown: ' + (Invoke-Soap 'server shutdown 15'))
                $graceful = $true
            } catch { Write-Log "SOAP command failed: $($_.Exception.Message)" 'WARN' }
        } else { Write-Log 'SOAP port not open.' 'WARN' }

        if ($graceful) {
            Write-Log 'Waiting for worldserver to save all characters and exit (up to 10 min)...'
            if (-not $world.WaitForExit(600000)) {
                Write-Log 'worldserver still running after 10 minutes. Leaving it running to avoid data loss; check its console window.' 'ERROR'
                return $false
            }
            Write-Log 'worldserver stopped cleanly.' 'OK'
        } else {
            Write-Log 'Could not shut down worldserver gracefully. Type "server shutdown 10" in its console window.' 'ERROR'
            return $false
        }
    } else { Write-Log 'worldserver not running.' }

    Get-BridgeProc | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Log 'LLM chatter bridge stopped.' 'OK'

    # authserver holds no unsaved state; terminating it is safe.
    Get-ServerProc 'authserver' | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Log 'authserver stopped.' 'OK'

    if ($KeepDatabase -or -not $Settings.MySqlStopWithServer) { Write-Log "Database left running (Windows service '$MySqlService')." }
    else { Stop-MySqlIfOwned }
    Write-Log '===== Server is OFFLINE =====' 'OK'
    if ($world -and -not $KeepDatabase) { Send-Notice "🔴 **$($Settings.RealmName)** is offline for now." 'OnStartStop' }
    return $true
}

switch ($Action) {
    'Start' {
        Remove-Item $StopFlag -ErrorAction SilentlyContinue
        Write-Log '===== START requested ====='
        # Only one WoW server can use the login/game ports at a time.
        foreach ($name in 'Auth', 'World', 'Soap') {
            $procName = if ($name -eq 'Auth') { 'authserver' } else { 'worldserver' }
            if ((Test-Port $Ports[$name]) -and -not (Get-ServerProc $procName)) {
                throw "Port $($Ports[$name]) is in use by $(Get-PortOwner $Ports[$name]). Stop that first (its STOP_SERVER.bat or the Control Center), then start this one."
            }
        }
        Start-MySql

        if (Get-ServerProc 'authserver') { Write-Log 'authserver already running.' 'OK' }
        else {
            $a = Start-Process (Join-Path $ServerDir 'authserver.exe') -WorkingDirectory $ServerDir -PassThru
            if (-not (Wait-Port $Ports.Auth 60 'authserver' $a)) { throw 'authserver failed to start; see server\logs\Auth.log' }
            Write-Log "authserver is up on port $($Ports.Auth)." 'OK'
        }

        if (-not $NoBridge) { Start-Ollama }

        if (Get-ServerProc 'worldserver') { Write-Log 'worldserver already running.' 'OK' }
        else {
            $w = Start-WorldProcess
            if (-not (Wait-Port $Ports.World 1800 'worldserver' $w)) { throw 'worldserver failed to start; see server\logs\Server.log' }
            Write-Log "worldserver is up on port $($Ports.World)." 'OK'
        }

        Start-Bridge
        Write-Log '===== Server is ONLINE. Connect with realmlist 127.0.0.1 =====' 'OK'
        Send-Notice "🟢 **$($Settings.RealmName)** is online - come and play!" 'OnStartStop'
        Show-Status
        if (-not $NoMonitor) { Start-Monitor }
    }

    'Stop' { if (-not (Stop-AllServers)) { exit 1 } }

    'Restart' {
        if ($OnlyIfRunning -and -not (Get-ServerProc 'worldserver')) { Write-Log 'Scheduled restart skipped: server is not running.'; return }
        if ($WarnMinutes -gt 0 -and (Test-Port $Ports.Soap)) {
            try {
                Write-Log "Restart announced to players ($WarnMinutes min warning)."
                Invoke-Soap "announce The server will restart in $WarnMinutes minute(s). Please find a safe spot." | Out-Null
                if ($WarnMinutes -gt 1) {
                    Start-Sleep -Seconds (($WarnMinutes - 1) * 60)
                    Invoke-Soap 'announce The server restarts in 1 minute.' | Out-Null
                }
                Start-Sleep -Seconds 60
            } catch { Write-Log "Could not announce the restart: $($_.Exception.Message)" 'WARN' }
        }
        if (-not (Stop-AllServers -KeepDatabase)) { exit 1 }
        Start-Sleep -Seconds 3
        # Through Explorer so the new server is independent of whatever launched this script.
        Start-Process explorer.exe -ArgumentList "`"$(Join-Path $Root 'START_SERVER.bat')`""
        Write-Log 'Restart: START_SERVER launched.' 'OK'
    }
    'Status'  { Show-Status }
    'Monitor' { Start-Monitor }
}

