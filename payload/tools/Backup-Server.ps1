<#
  Backs up accounts, characters and bot data to <server folder>\backups\<date>-<label>.zip
  Used by the daily scheduled backup; safe to run any time (even while the server runs).
  -IncludeWorld also saves the world database (a complete "save point"; used before updates).
  Backups labelled before-update / savepoint are never pruned automatically (delete them in the app).
  If BackupCopyDir is set in server-settings.json, a copy of every backup is kept there too (other drive, OneDrive...).
#>
param([string]$Label = 'daily', [switch]$IncludeWorld)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$S = Get-Content (Join-Path $PSScriptRoot 'server-settings.json') -Raw | ConvertFrom-Json
$dump = Join-Path $S.MySqlDir 'bin\mysqldump.exe'
$mysql = Join-Path $S.MySqlDir 'bin\mysql.exe'
$backups = Join-Path $Root 'backups'
$stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$work = Join-Path $backups "$stamp-$Label"
New-Item -ItemType Directory -Force $work | Out-Null
$log = Join-Path $Root 'server\logs\backup.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
$Protected = 'before-update', 'savepoint'

function Log($m) { Add-Content $log ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m); Write-Output $m }

# With "stop database with server" the database may be off: start it for the backup, stop it again after.
$startedDb = $false
$svc = Get-Service $S.MySqlService -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') {
    Start-Service $S.MySqlService
    for ($i = 0; $i -lt 60 -and -not (Get-NetTCPConnection -LocalPort $S.DbPort -State Listen -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    $startedDb = $true
}

$ErrorActionPreference = 'Continue'   # mysql tools print a password warning on stderr
$dbs = @('acore_auth', 'acore_characters')
$pb = & $mysql '-uacore' '-pacore' '--host=127.0.0.1' "--port=$($S.DbPort)" '-N' '-e' "SHOW DATABASES LIKE 'acore_playerbots'" 2>$null
if ($pb) { $dbs += 'acore_playerbots' }
if ($IncludeWorld) { $dbs += 'acore_world' }
foreach ($db in $dbs) {
    & $dump '-uacore' '-pacore' '--host=127.0.0.1' "--port=$($S.DbPort)" '--single-transaction' '--routines' '--triggers' '--add-drop-table' '--hex-blob' "--result-file=$(Join-Path $work "$db.sql")" $db 2>$null
    if ($LASTEXITCODE -ne 0) {
        Log "Backup of $db FAILED (is MySQL running?)"; Remove-Item $work -Recurse -Force
        if ($startedDb) { Stop-Service $S.MySqlService -ErrorAction SilentlyContinue }
        exit 1
    }
}
if ($startedDb) { Stop-Service $S.MySqlService -ErrorAction SilentlyContinue }
$ErrorActionPreference = 'Stop'
Copy-Item (Join-Path $PSScriptRoot 'server-settings.json') $work
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($work, "$work.zip", [IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item $work -Recurse -Force

$keep = if ($S.BackupKeep) { [int]$S.BackupKeep } else { 10 }
$isProtected = { param($f) foreach ($p in $Protected) { if ($f.BaseName.EndsWith("-$p")) { return $true } }; $false }
Get-ChildItem $backups -Filter *.zip | Where-Object { -not (& $isProtected $_) } | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep | Remove-Item -Force

# Optional second copy somewhere else (another drive, a cloud-synced folder...).
if ($S.BackupCopyDir) {
    try {
        $dest = Join-Path $S.BackupCopyDir (($S.RealmName -replace '[\\/:*?"<>|]', '').Trim())
        New-Item -ItemType Directory -Force $dest | Out-Null
        Copy-Item "$work.zip" $dest -Force
        Get-ChildItem $dest -Filter *.zip | Where-Object { -not (& $isProtected $_) } | Sort-Object LastWriteTime -Descending | Select-Object -Skip $keep | Remove-Item -Force
        Log "Copy saved in $dest"
    } catch { Log "Could not copy the backup to $($S.BackupCopyDir): $($_.Exception.Message)" }
}
Log "Backup created: $work.zip"
