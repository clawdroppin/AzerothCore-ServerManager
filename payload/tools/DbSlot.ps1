<#
  Database port sharing. Servers made by this app can share one database port: only one of their databases runs
  at a time, and starting a server swaps its own database in (the database that held the port is stopped first,
  unless its server is running). Every connection is also checked to reach the RIGHT server's data, so a shared
  port can never make the app read or change another server's characters.
  Dot-sourced by ServerControl.ps1, Backup-Server.ps1 and the app (src\Manage.ps1).
#>

function Get-DbPortService([int]$Port) {
    # The Windows service whose process listens on this port (or $null).
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    # MySQL 8.4 on Windows listens from a child of the service process: look at the process and its parent.
    $ids = @($c.OwningProcess)
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.OwningProcess)" -ErrorAction SilentlyContinue
    if ($proc -and $proc.ParentProcessId) { $ids += $proc.ParentProcessId }
    foreach ($id in $ids) {
        $svc = Get-CimInstance Win32_Service -Filter "ProcessId=$id" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($svc) { return $svc }
    }
    $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    [pscustomobject]@{ Name = ''; DisplayName = $(if ($p) { $p.Name } else { "process $($c.OwningProcess)" }); PathName = '' }
}

function Get-DbServiceRoot($Service) {
    # The server folder a database service of this app belongs to (from its my.ini path).
    if ("$($Service.PathName)" -match '--defaults-file="?([^"]+?)\\database\\my\.ini') { return $Matches[1] }
    $null
}

function Enter-DatabaseSlot([string]$Root, $Settings) {
    <# Frees the server's database port for its own database: stops another database of this app that holds it.
       Throws (and changes nothing) if that other server is running, or if a different program owns the port. #>
    $port = [int]$Settings.DbPort
    $holder = Get-DbPortService $port
    if (-not $holder -or $holder.Name -eq $Settings.MySqlService) { return }
    if ("$($holder.Name)" -notlike 'AzerothCoreMySQL*') {
        throw "Database port $port is used by another program ($($holder.DisplayName)). Stop it, or give this server its own port."
    }
    $other = Get-DbServiceRoot $holder
    if ($other) {
        $otherServer = Join-Path $other 'server'
        $running = Get-Process worldserver -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($otherServer, [StringComparison]::OrdinalIgnoreCase) }
        if ($running) { throw "The server in $other is running and is using the shared database port $port. Stop that server first - only one server can use the shared port at a time." }
    }
    Stop-Service $holder.Name -Force -ErrorAction Stop
    for ($i = 0; $i -lt 60 -and (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
    if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { throw "The other server's database did not release port $port." }
}

function Test-DatabaseIdentity([string]$Root, $Settings) {
    <# $true when the database answering on the server's port is this server's own (compares MySQL's data folder).
       Databases not made by this app (for example an existing MySQL service) are not checked. #>
    if ("$($Settings.MySqlService)" -notlike 'AzerothCoreMySQL*') { return $true }
    $mysql = Join-Path $Settings.MySqlDir 'bin\mysql.exe'
    if (-not (Test-Path $mysql)) { return $true }
    $ErrorActionPreference = 'Continue'
    $d = & $mysql '-uacore' '-pacore' '--host=127.0.0.1' "--port=$([int]$Settings.DbPort)" '-N' '-B' '-r' '-e' 'SELECT @@datadir' 2>$null | Select-Object -Last 1
    if (-not $d) { return $true }   # cannot tell (login problem etc.) - other checks report that
    $norm = { param($p) "$p".Replace('/', '\').TrimEnd('\') }
    (& $norm $d) -eq (& $norm (Join-Path $Root 'database\data'))
}
