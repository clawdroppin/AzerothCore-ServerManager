<#
  Creates or updates an AzerothCore game account (3.3.5a SRP6 login).

  Usage:  New-GameAccount.ps1 -Username NAME -Password PASS [-GmLevel 0-3]
  GmLevel: 0 = player, 1 = moderator, 2 = gamemaster, 3 = administrator.
#>
param(
    [Parameter(Mandatory)][string]$Username,
    [Parameter(Mandatory)][string]$Password,
    [ValidateRange(0, 3)][int]$GmLevel = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Numerics

$Root = Split-Path -Parent $PSScriptRoot
$Settings = Get-Content (Join-Path $PSScriptRoot 'server-settings.json') -Raw | ConvertFrom-Json
$MySql = Join-Path $Settings.MySqlDir 'bin\mysql.exe'

$user = $Username.ToUpperInvariant()
$pass = $Password.ToUpperInvariant()
if ($user -notmatch '^[A-Z0-9]{3,17}$') { throw 'Username must be 3-17 letters/numbers.' }
if ($pass.Length -lt 4 -or $pass.Length -gt 16) { throw 'Password must be 4-16 characters.' }

function Get-UnsignedBigInt([byte[]]$LittleEndian) {
    [System.Numerics.BigInteger]::new([byte[]]($LittleEndian + [byte]0))
}

$sha1 = [Security.Cryptography.SHA1]::Create()
$N = [System.Numerics.BigInteger]::Parse('0894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7', 'AllowHexSpecifier')
$g = [System.Numerics.BigInteger]::new(7)

$salt = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
$inner = $sha1.ComputeHash([Text.Encoding]::UTF8.GetBytes("${user}:${pass}"))
$x = Get-UnsignedBigInt $sha1.ComputeHash([byte[]]($salt + $inner))
$v = [System.Numerics.BigInteger]::ModPow($g, $x, $N).ToByteArray()
$verifier = New-Object byte[] 32
[Array]::Copy($v, $verifier, [Math]::Min(32, $v.Length))

$saltHex = ($salt | ForEach-Object { $_.ToString('X2') }) -join ''
$verHex = ($verifier | ForEach-Object { $_.ToString('X2') }) -join ''

$sql = @"
INSERT INTO account (username, salt, verifier, expansion, joindate)
  VALUES ('$user', 0x$saltHex, 0x$verHex, $($Settings.Expansion), NOW())
  ON DUPLICATE KEY UPDATE salt = VALUES(salt), verifier = VALUES(verifier), expansion = VALUES(expansion);
SET @id = (SELECT id FROM account WHERE username = '$user');
DELETE FROM account_access WHERE id = @id;
$(if ($GmLevel -gt 0) { "INSERT INTO account_access (id, gmlevel, RealmID) VALUES (@id, $GmLevel, -1);" })
SELECT @id;
"@
$ErrorActionPreference = 'Continue'   # mysql prints a password warning on stderr
# Quote host/port: PowerShell 5.1 splits bare args like -h127.0.0.1 at the first dot.
$id = $sql | & $MySql '-uacore' '-pacore' '--host=127.0.0.1' "--port=$($Settings.DbPort)" '-N' 'acore_auth' 2>$null
if ($LASTEXITCODE -ne 0) { throw "Could not write account $user to the database." }
Write-Output "Account $user (id $($id | Select-Object -Last 1)) ready, GM level $GmLevel."

