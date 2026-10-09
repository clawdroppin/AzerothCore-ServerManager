# Shared helpers for the AzerothCore Creation Tool install engine.
# Loaded into the background runspace (and the UI for detection helpers).

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# $Sync is injected by the UI: a synchronized hashtable shared with the window.
if (-not $Sync) {
    $Sync = [hashtable]::Synchronized(@{
        Log = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Steps = [hashtable]::Synchronized(@{}); Detail = ''; Cancel = $false
    })
}

function Write-ToolLog {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'CMD')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $Sync.Log.Enqueue($line)
    if ($Global:ToolLogFile) {
        try { [IO.File]::AppendAllText($Global:ToolLogFile, $line + [Environment]::NewLine) } catch {}
    }
}

function Set-Detail([string]$Text) { $Sync.Detail = $Text }

function Assert-NotCancelled {
    if ($Sync.Cancel) { throw [OperationCanceledException]::new('Installation was cancelled.') }
}

# ------------------------------------------------------------------ downloads

function Get-RemoteFile {
    <# Downloads with progress, retries and optional SHA-256 verification. #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Sha256,
        [string]$Label = (Split-Path $Destination -Leaf)
    )
    if ((Test-Path $Destination) -and $Sha256) {
        if ((Get-FileHash $Destination -Algorithm SHA256).Hash -ieq $Sha256) {
            Write-ToolLog "$Label already downloaded (hash verified)." 'OK'
            return $Destination
        }
    }
    New-Item -ItemType Directory -Force (Split-Path $Destination -Parent) | Out-Null
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(3)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Wget/1.21 AzerothCoreCreationTool/1.0')

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Assert-NotCancelled
        $tmp = "$Destination.part"
        try {
            Write-ToolLog "Downloading $Label (attempt $attempt)..."
            $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $resp.EnsureSuccessStatusCode() | Out-Null
            $total = $resp.Content.Headers.ContentLength
            $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $out = [IO.File]::Create($tmp)
            try {
                $buf = New-Object byte[] (1MB)
                $done = 0L; $sw = [Diagnostics.Stopwatch]::StartNew(); $lastReport = 0
                while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                    $out.Write($buf, 0, $n); $done += $n
                    if ($sw.ElapsedMilliseconds - $lastReport -gt 500) {
                        $lastReport = $sw.ElapsedMilliseconds
                        $mb = [math]::Round($done / 1MB)
                        $speed = [math]::Round(($done / 1MB) / [math]::Max(1, $sw.Elapsed.TotalSeconds), 1)
                        if ($total) { Set-Detail ("Downloading {0}: {1} / {2} MB ({3} MB/s)" -f $Label, $mb, [math]::Round($total / 1MB), $speed) }
                        else { Set-Detail ("Downloading {0}: {1} MB ({2} MB/s)" -f $Label, $mb, $speed) }
                        if ($Sync.Cancel) { throw [OperationCanceledException]::new('Installation was cancelled.') }
                    }
                }
            } finally { $out.Dispose(); $in.Dispose() }

            $head = [IO.File]::ReadAllBytes($tmp) | Select-Object -First 15
            if ([Text.Encoding]::ASCII.GetString([byte[]]$head) -match '<!DOCTYPE|<html') {
                throw "Server returned a web page instead of the file."
            }
            if ($Sha256) {
                $h = (Get-FileHash $tmp -Algorithm SHA256).Hash
                if ($h -ine $Sha256) { throw "Checksum mismatch for $Label (expected $Sha256, got $h)." }
                Write-ToolLog "$Label checksum verified." 'OK'
            }
            Move-Item $tmp $Destination -Force
            Set-Detail ''
            return $Destination
        } catch [OperationCanceledException] {
            throw
        } catch {
            Write-ToolLog "Download failed: $($_.Exception.Message)" 'WARN'
            Remove-Item $tmp -ErrorAction SilentlyContinue
            if ($attempt -eq 3) { throw "Could not download $Label from $Url. Check your internet connection and try again." }
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Assert-Signed {
    <# Verifies a Windows Authenticode signature and (optionally) the publisher name. #>
    param([string]$Path, [string]$PublisherLike)
    $sig = Get-AuthenticodeSignature $Path
    if ($sig.Status -ne 'Valid') { throw "$(Split-Path $Path -Leaf) is not validly signed ($($sig.Status)); refusing to run it." }
    if ($PublisherLike -and $sig.SignerCertificate.Subject -notlike "*$PublisherLike*") {
        throw "$(Split-Path $Path -Leaf) is signed by an unexpected publisher: $($sig.SignerCertificate.Subject)"
    }
    Write-ToolLog "Signature OK: $($sig.SignerCertificate.Subject -replace ',.*$', '')" 'OK'
}

function Get-GitHubLatestAsset {
    param([string]$Repo, [string]$NamePattern, [string]$ExcludePattern = '^$')
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'AzerothCoreCreationTool' }
    $asset = $rel.assets | Where-Object { $_.name -match $NamePattern -and $_.name -notmatch $ExcludePattern } | Select-Object -First 1
    if (-not $asset) { throw "No release asset matching '$NamePattern' in $Repo." }
    [pscustomobject]@{
        Tag = $rel.tag_name; Name = $asset.name; Url = $asset.browser_download_url
        Sha256 = if ($asset.digest -match '^sha256:(.+)$') { $Matches[1] } else { $null }
    }
}

# ------------------------------------------------------------------ processes

function Invoke-Native {
    <# Runs a program, streams merged stdout/stderr into the log, returns exit code. #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [string]$WorkingDirectory = (Get-Location).Path,
        [int[]]$OkExitCodes = @(0),
        [scriptblock]$OnLine,
        [switch]$Quiet,
        [hashtable]$Environment,
        [string]$InputFile          # fed to the program's stdin (e.g. a .sql dump for mysql.exe)
    )
    Assert-NotCancelled
    Write-ToolLog ("`"$FilePath`" $Arguments" -replace '(?<=\s)-p[^\s"]+', '-p****') 'CMD'
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    # stdin comes from NUL (or the given file) so no program can ever sit waiting for a keypress.
    $stdin = if ($InputFile) { "<`"$InputFile`"" } else { '<NUL' }
    $psi.Arguments = "/d /s /c `"`"$FilePath`" $Arguments 2>&1 $stdin`""
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    # AzerothCore tools ask "Do you want to create it?" for missing databases unless this is set.
    $psi.EnvironmentVariables['AC_DISABLE_INTERACTIVE'] = '1'
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    if ($Environment) { foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = $Environment[$k] } }
    $p = [Diagnostics.Process]::Start($psi)
    while (-not $p.StandardOutput.EndOfStream) {
        $line = $p.StandardOutput.ReadLine()
        if ($null -eq $line) { continue }
        $line = $line -replace '\x1b\[[0-9;?]*[A-Za-z]', ''
        if ($OnLine) { & $OnLine $line }
        if (-not $Quiet -and $line.Trim()) { Write-ToolLog $line.TrimEnd() }
        if ($Sync.Cancel) { try { $p.Kill() } catch {}; throw [OperationCanceledException]::new('Installation was cancelled.') }
    }
    $p.WaitForExit()
    if ($OkExitCodes -notcontains $p.ExitCode) {
        throw "$(Split-Path $FilePath -Leaf) failed with exit code $($p.ExitCode)."
    }
    return $p.ExitCode
}

function Update-SessionPath {
    # Picks up programs installed since the app started. Reads the raw registry values: a user PATH that contains
    # "%PATH%" (some installers add that) would otherwise expand to the current PATH and double it on every call,
    # until Windows refuses it ("Environment variable name or value is too long") and every background job fails.
    $raw = @(
        (Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames'),
        (Get-Item 'HKCU:\Environment' -ErrorAction SilentlyContinue).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    ) -join ';'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $parts = foreach ($p in $raw -split ';') {
        if (-not $p.Trim() -or $p -match '%PATH%') { continue }
        $e = [Environment]::ExpandEnvironmentVariables($p.Trim())
        if ($seen.Add($e.TrimEnd('\'))) { $e }
    }
    $new = $parts -join ';'
    # The process environment is shared by all background workers: only write when it actually changes.
    if ($new -and $env:Path -ne $new) { try { $env:Path = $new } catch {} }
}

function Test-PortListening([int]$Port) {
    [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function New-RandomSecret([int]$Length = 16) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# ------------------------------------------------------------------ machine profile

function Get-MachineProfile {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cs = Get-CimInstance Win32_ComputerSystem
    $os = Get-CimInstance Win32_OperatingSystem
    $gpuName = $null; $vramGB = 0
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        try {
            $q = & $smi.Source --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($q) { $parts = $q -split ','; $gpuName = $parts[0].Trim(); $vramGB = [math]::Round([double]$parts[1] / 1024) }
        } catch {}
    }
    if (-not $gpuName) {
        $gpuName = (Get-CimInstance Win32_VideoController | Sort-Object AdapterRAM -Descending | Select-Object -First 1).Name
    }
    [pscustomobject]@{
        CpuName  = $cpu.Name.Trim()
        Cores    = [int]$cpu.NumberOfCores
        Threads  = [int]$cpu.NumberOfLogicalProcessors
        RamGB    = [math]::Round($cs.TotalPhysicalMemory / 1GB)
        FreeRamGB = [math]::Round($os.FreePhysicalMemory / 1MB)
        OsName   = $os.Caption
        OsBuild  = [int]$os.BuildNumber
        Is64Bit  = [Environment]::Is64BitOperatingSystem
        GpuName  = $gpuName
        VramGB   = $vramGB
        IsAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

function Get-RecommendedBotCount([int]$RamGB) {
    if ($RamGB -ge 48) { 800 } elseif ($RamGB -ge 32) { 500 } elseif ($RamGB -ge 16) { 250 } else { 100 }
}

function Get-FreeSpaceGB([string]$Path) {
    $root = [IO.Path]::GetPathRoot($Path)
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($root.TrimEnd('\'))'"
    if ($d) { [math]::Round($d.FreeSpace / 1GB) } else { 0 }
}

function Test-WowClient([string]$WowExe) {
    <# Returns $null if OK, otherwise a plain-language problem description. #>
    if (-not $WowExe -or -not (Test-Path $WowExe)) { return 'Please choose your Wow.exe file.' }
    $v = (Get-Item $WowExe).VersionInfo
    $build = '{0}.{1}.{2}.{3}' -f $v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart
    if ($build -ne '3.3.5.12340') {
        return "This Wow.exe is version $build. You need the Wrath of the Lich King 3.3.5a client (version 3.3.5.12340)."
    }
    $data = Join-Path (Split-Path $WowExe -Parent) 'Data'
    if (-not (Test-Path $data)) { return 'The game folder has no Data folder. Please choose the Wow.exe inside a complete game folder.' }
    return $null
}

# ------------------------------------------------------------------ tool discovery

function Find-ClExe {
    foreach ($base in "${env:ProgramFiles}\Microsoft Visual Studio\2022", "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022") {
        if (-not (Test-Path $base)) { continue }
        $cl = Get-ChildItem $base -Recurse -Filter cl.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\VC\\Tools\\MSVC\\[^\\]+\\bin\\Hostx64\\x64\\cl\.exe$' } |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($cl) { return $cl.FullName }
    }
    return $null
}

function Find-Exe([string]$Name, [string[]]$Candidates) {
    foreach ($c in $Candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-Git { Find-Exe 'git.exe' @("$env:ProgramFiles\Git\cmd\git.exe") }
function Find-CMake { Find-Exe 'cmake.exe' @("$env:ProgramFiles\CMake\bin\cmake.exe") }
function Find-Python {
    $c = @(Get-ChildItem "$env:ProgramFiles\Python3*\python.exe", "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | ForEach-Object FullName)
    $ErrorActionPreference = 'Continue'
    foreach ($p in $c) {
        $ver = & $p -c "import sys;print(sys.version_info[1])" 2>$null
        if ([int]$ver -ge 10) { return $p }
    }
    return $null
}
function Find-Ollama { Find-Exe 'ollama.exe' @("$env:LOCALAPPDATA\Programs\Ollama\ollama.exe") }

