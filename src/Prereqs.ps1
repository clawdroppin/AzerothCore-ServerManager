# Prerequisites catalog: one place that knows how to detect, download (verified) and install
# every tool the servers need. Used by the install engine (Steps.ps1) and the Prerequisites page.
# Requires Common.ps1. Uses $V (versions.json) and Get-DownloadDir (Steps.ps1 or below).

if (-not (Get-Command Get-DownloadDir -ErrorAction SilentlyContinue)) {
    function Get-DownloadDir {
        $base = if (Get-Command Get-AppPrefs -ErrorAction SilentlyContinue) { Join-Path (Get-AppPrefs).ServersFolder '_shared\downloads' } else { Join-Path $env:TEMP 'AzerothCoreDownloads' }
        New-Item -ItemType Directory -Force $base | Out-Null
        $base
    }
}

function Get-RegistryVersion([string]$Path, [string]$Name = 'Version') {
    $k = Get-ItemProperty $Path -ErrorAction SilentlyContinue
    if ($k) { "$($k.$Name)" } else { $null }
}

function Get-UninstallVersion([string]$NameLike) {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    (Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $NameLike } | Select-Object -First 1).DisplayVersion
}

function Get-ExeVersion([string]$Exe) {
    if ($Exe -and (Test-Path $Exe)) { $vi = (Get-Item $Exe).VersionInfo; if ($vi.ProductVersion) { $vi.ProductVersion.Trim() } else { "$($vi.FileVersion)".Trim() } } else { $null }
}

$PrereqCatalog = @(
    @{
        Id = 'vcredist'; Name = 'Microsoft Visual C++ runtime (2015-2022, x64)'; Group = 'Core'; Need = 'run'
        Purpose = 'Needed by the server programs and MySQL.'
        Detect = {
            $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
            @{ Installed = [bool]($k -and $k.Installed -eq 1 -and $k.Major -ge 14 -and $k.Minor -ge 40); Version = if ($k) { "$($k.Version)".TrimStart('v') } }
        }
        Get = {
            $f = Get-RemoteFile -Url $V.prereqs.vcRedist -Destination (Join-Path (Get-DownloadDir) 'vc_redist.x64.exe') -Label 'Visual C++ runtime'
            Assert-Signed $f 'Microsoft'
            @{ File = $f; Silent = '/install /quiet /norestart'; Guided = '/install'; Ok = @(0, 1638, 3010) }
        }
        Guide = @('Tick "I agree to the license terms".', 'Click Install, then Close.')
    },
    @{
        Id = 'git'; Name = 'Git'; Group = 'Build tools'; Need = 'build'
        Purpose = 'Downloads the AzerothCore source code and modules, and their updates.'
        Detect = { $g = Find-Git; @{ Installed = [bool]$g; Version = if ($g) { ((& $g --version) -replace 'git version ', '') } } }
        Get = {
            $a = Get-GitHubLatestAsset 'git-for-windows/git' '64-bit\.exe$' 'Portable|arm64|MinGit|busybox'
            $f = Get-RemoteFile -Url $a.Url -Destination (Join-Path (Get-DownloadDir) $a.Name) -Sha256 $a.Sha256 -Label "Git $($a.Tag)"
            Assert-Signed $f
            @{ File = $f; Silent = '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES'; Guided = ''; Ok = @(0) }
        }
        Guide = @('Keep every default option.', 'Click Next on each page, then Install, then Finish.')
    },
    @{
        Id = 'cmake'; Name = 'CMake'; Group = 'Build tools'; Need = 'build'
        Purpose = 'Prepares the C++ project for compiling.'
        Detect = {
            $c = Find-CMake; $ver = $null
            if ($c) { $ver = ((& $c --version) | Select-Object -First 1) -replace '[^\d.]', '' }
            @{ Installed = [bool]($ver -and [version]$ver -ge [version]'3.16'); Version = $ver }
        }
        Get = {
            $a = Get-GitHubLatestAsset 'Kitware/CMake' 'windows-x86_64\.msi$'
            $f = Get-RemoteFile -Url $a.Url -Destination (Join-Path (Get-DownloadDir) $a.Name) -Sha256 $a.Sha256 -Label "CMake $($a.Tag)"
            @{ File = 'msiexec.exe'; Silent = "/i `"$f`" /qn /norestart ADD_CMAKE_TO_PATH=System"; Guided = "/i `"$f`""; Ok = @(0, 3010) }
        }
        Guide = @('On the "Install Options" page choose "Add CMake to the system PATH for all users".', 'Keep the other defaults and click Install.')
    },
    @{
        Id = 'msvc'; Name = 'Visual Studio 2022 Build Tools (C++ compiler)'; Group = 'Build tools'; Need = 'build'
        Purpose = 'The compiler that builds the server. Big download (several GB).'
        Detect = { $cl = Find-ClExe; @{ Installed = [bool]$cl; Version = if ($cl) { ($cl -split '\\MSVC\\')[1].Split('\')[0] } } }
        Get = {
            $f = Get-RemoteFile -Url $V.prereqs.vsBuildTools -Destination (Join-Path (Get-DownloadDir) 'vs_BuildTools.exe') -Label 'Visual Studio Build Tools installer'
            Assert-Signed $f 'Microsoft'
            $add = '--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.CMake.Project --includeRecommended'
            @{ File = $f; Silent = "--quiet --wait --norestart --nocache $add"; Guided = "--wait $add"; Ok = @(0, 3010) }
        }
        Guide = @('The installer opens with "Desktop development with C++" already ticked.', 'Make sure "MSVC v143" and "Windows 11 SDK" are ticked on the right.', 'Click Install. This downloads several GB; wait until it says it is done.')
    },
    @{
        Id = 'boost'; Name = 'Boost C++ libraries 1.81'; Group = 'Build tools'; Need = 'build'
        Purpose = 'C++ libraries the server is built with.'
        Detect = {
            $dir = $V.prereqs.boost.dir
            @{ Installed = Test-Path (Join-Path $dir 'lib64-msvc-14.3'); Version = if (Test-Path $dir) { $V.prereqs.boost.version } }
        }
        Get = {
            $f = Get-RemoteFile -Url $V.prereqs.boost.url -Destination (Join-Path (Get-DownloadDir) (Split-Path $V.prereqs.boost.url -Leaf)) -Label "Boost $($V.prereqs.boost.version)"
            @{ File = $f; Silent = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=`"$($V.prereqs.boost.dir)`""; Guided = "/DIR=`"$($V.prereqs.boost.dir)`""; Ok = @(0) }
        }
        After = {
            [Environment]::SetEnvironmentVariable('BOOST_ROOT', $V.prereqs.boost.dir, 'Machine')
            $env:BOOST_ROOT = $V.prereqs.boost.dir
        }
        Guide = @('Keep the suggested install folder (C:\local\boost_1_81_0) exactly as it is.', 'Click Next and Install. Unpacking takes a few minutes.')
    },
    @{
        Id = 'openssl'; Name = 'OpenSSL 3'; Group = 'Build tools'; Need = 'build'
        Purpose = 'Encryption library used for logins.'
        Detect = {
            $hdr = Join-Path "$env:ProgramFiles\OpenSSL-Win64" 'include\openssl\opensslv.h'
            $ok = (Test-Path $hdr) -and (Select-String $hdr -Pattern '#\s*define OPENSSL_VERSION_MAJOR\s+3\b' -Quiet)
            $ver = $null
            if (Test-Path $hdr) { $m = Select-String $hdr -Pattern 'OPENSSL_FULL_VERSION_STR\s+"([^"]+)"' | Select-Object -First 1; if ($m) { $ver = $m.Matches[0].Groups[1].Value } }
            @{ Installed = [bool]$ok; Version = $ver; Note = if ((Test-Path $hdr) -and -not $ok) { 'A version other than 3.x is installed' } }
        }
        Get = {
            $j = Invoke-RestMethod $V.prereqs.opensslHashes
            $best = $j.files.PSObject.Properties | ForEach-Object { $_.Value } |
                Where-Object { $_.basever -like '3.*' -and $_.bits -eq 64 -and $_.arch -eq 'INTEL' -and -not $_.light -and $_.installer -eq 'msi' -and -not $_.subver } |
                Sort-Object { [version]$_.basever } -Descending | Select-Object -First 1
            if (-not $best) { throw 'Could not find an OpenSSL 3 installer.' }
            $f = Get-RemoteFile -Url $best.url -Destination (Join-Path (Get-DownloadDir) (Split-Path $best.url -Leaf)) -Sha256 $best.sha256 -Label "OpenSSL $($best.basever)"
            @{ File = 'msiexec.exe'; Silent = "/i `"$f`" /qn /norestart"; Guided = "/i `"$f`""; Ok = @(0, 3010) }
        }
        Guide = @('Accept the license and keep the default folder (C:\Program Files\OpenSSL-Win64).', 'When asked where to copy the DLLs, choose "The OpenSSL binaries (/bin) directory".', 'Skip the donation page and click Finish.')
    },
    @{
        Id = 'mysql'; Name = 'MySQL 8.4 LTS'; Group = 'Database'; Need = 'run'
        Purpose = 'Each server gets its own private copy automatically. This only pre-downloads it so new servers install faster.'
        Detect = {
            $zip = Join-Path (Get-DownloadDir) (Split-Path $V.prereqs.mysql.url -Leaf)
            @{ Installed = Test-Path $zip; Version = if (Test-Path $zip) { "$($V.prereqs.mysql.version) (cached)" }; Note = 'No system-wide install needed' }
        }
        Get = {
            Get-RemoteFile -Url $V.prereqs.mysql.url -Destination (Join-Path (Get-DownloadDir) (Split-Path $V.prereqs.mysql.url -Leaf)) -Label "MySQL $($V.prereqs.mysql.version)" | Out-Null
            $null   # nothing to run: the zip is unpacked per server
        }
        Guide = @('Nothing to click: the files are downloaded to the shared cache.')
    },
    @{
        Id = 'python'; Name = 'Python 3'; Group = 'AI chatter'; Need = 'ai'
        Purpose = 'Runs the AI chatter bridge between the server and the AI model.'
        Detect = { $p = Find-Python; @{ Installed = [bool]$p; Version = if ($p) { (& $p --version 2>&1) -replace 'Python ', '' } } }
        Get = {
            $series = $V.prereqs.pythonSeries
            $links = (Invoke-WebRequest 'https://www.python.org/ftp/python/' -UseBasicParsing).Links.href |
                Where-Object { $_ -match "^$([regex]::Escape($series))\.\d+/$" } | ForEach-Object { $_.TrimEnd('/') } |
                Sort-Object { [version]$_ } -Descending
            $url = $null
            foreach ($ver in $links) {
                $u = "https://www.python.org/ftp/python/$ver/python-$ver-amd64.exe"
                try { Invoke-WebRequest $u -Method Head -UseBasicParsing -TimeoutSec 20 | Out-Null; $url = $u; break } catch {}
            }
            if (-not $url) { throw "No Python $series installer found." }
            $f = Get-RemoteFile -Url $url -Destination (Join-Path (Get-DownloadDir) (Split-Path $url -Leaf)) -Label 'Python'
            Assert-Signed $f 'Python Software Foundation'
            @{ File = $f; Silent = '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=0'; Guided = 'PrependPath=1'; Ok = @(0) }
        }
        Guide = @('Tick "Add python.exe to PATH" at the bottom of the first page.', 'Click "Install Now", then Close.')
    },
    @{
        Id = 'ollama'; Name = 'Ollama'; Group = 'AI chatter'; Need = 'ai'
        Purpose = 'Runs the AI model locally on your graphics card.'
        Detect = {
            $o = Find-Ollama; $ver = $null
            if ($o) { $ErrorActionPreference = 'Continue'; $out = "$(& $o --version 2>&1)"; if ($out -match '(\d+\.\d+\.\d+)') { $ver = $Matches[1] } }
            @{ Installed = [bool]$o; Version = $ver }
        }
        Get = {
            $f = Get-RemoteFile -Url $V.prereqs.ollama -Destination (Join-Path (Get-DownloadDir) 'OllamaSetup.exe') -Label 'Ollama'
            Assert-Signed $f
            @{ File = $f; Silent = '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP-'; Guided = ''; Ok = @(0) }
        }
        Guide = @('Click Install. Ollama starts in the system tray when it is done.')
    },
    @{
        Id = 'heidisql'; Name = 'HeidiSQL (optional)'; Group = 'Extras'; Need = 'extra'
        Purpose = 'A friendly window for browsing and editing the game databases.'
        Detect = { $h = "$env:ProgramFiles\HeidiSQL\heidisql.exe"; @{ Installed = Test-Path $h; Version = Get-UninstallVersion 'HeidiSQL*' } }
        Get = {
            $a = Get-GitHubLatestAsset 'HeidiSQL/HeidiSQL' '_Setup\.exe$'
            $f = Get-RemoteFile -Url $a.Url -Destination (Join-Path (Get-DownloadDir) $a.Name) -Sha256 $a.Sha256 -Label "HeidiSQL $($a.Tag)"
            @{ File = $f; Silent = '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP-'; Guided = ''; Ok = @(0) }
        }
        Guide = @('Keep the defaults and click Next until Install.', 'To connect: host 127.0.0.1, user acore, password acore, and the port of your server (shown in World settings).')
    },
    @{
        Id = 'tailscale'; Name = 'Tailscale (optional)'; Group = 'Extras'; Need = 'extra'
        Purpose = 'A free private network so friends can join over the internet without router setup.'
        Detect = { $t = "$env:ProgramFiles\Tailscale\tailscale-ipn.exe"; @{ Installed = Test-Path $t; Version = Get-UninstallVersion 'Tailscale*' } }
        Get = {
            $f = Get-RemoteFile -Url $V.prereqs.tailscale -Destination (Join-Path (Get-DownloadDir) 'tailscale-setup.exe') -Label 'Tailscale'
            Assert-Signed $f 'Tailscale'
            @{ File = $f; Silent = '/quiet'; Guided = ''; Ok = @(0, 3010) }
        }
        Guide = @('Click Install.', 'Afterwards click the Tailscale icon in the system tray and sign in (Google, Microsoft or GitHub account).', 'Your friend installs Tailscale too and signs in to the same network (or you share your PC with them from the Tailscale admin page).')
    }
)

function Get-PrereqItem([string]$Id) {
    $p = $PrereqCatalog | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $p) { throw "Unknown prerequisite '$Id'." }
    $p
}

function Get-PrereqStatus {
    foreach ($p in $PrereqCatalog) {
        $d = $null
        try { $d = & $p.Detect } catch { $d = @{ Installed = $false; Note = $_.Exception.Message } }
        [pscustomobject]@{
            Id = $p.Id; Name = $p.Name; Group = $p.Group; Need = $p.Need; Purpose = $p.Purpose
            Installed = [bool]$d.Installed; Version = "$($d.Version)"; Note = "$($d.Note)"
        }
    }
}

function Install-Prereq {
    <# Downloads (verified) and installs one prerequisite. -Guided shows the normal installer instead of a silent one. #>
    param([string]$Id, [switch]$Guided, [switch]$Force)
    $p = Get-PrereqItem $Id
    if (-not $Force) {
        $d = & $p.Detect
        if ($d.Installed) { Write-ToolLog "$($p.Name): already installed$(if ($d.Version) { " ($($d.Version))" })." 'OK'; return }
    }
    Write-ToolLog "Installing $($p.Name)..."
    $inst = & $p.Get
    if ($inst) {
        if ($Guided) {
            Set-Detail ("A $($p.Name) installer window opens - follow these steps:`n  • " + ($p.Guide -join "`n  • ") + "`nThis screen continues when the installer closes.")
            Write-ToolLog ("Guided install - " + ($p.Guide -join ' / '))
            $proc = Start-Process $inst.File -ArgumentList $inst.Guided -PassThru -Wait
            if ($inst.Ok -notcontains $proc.ExitCode) { throw "$($p.Name) installer ended with code $($proc.ExitCode)." }
        } else {
            Set-Detail "Installing $($p.Name)..."
            Invoke-Native $inst.File $inst.Silent -OkExitCodes $inst.Ok | Out-Null
        }
    }
    if ($p.After) { & $p.After }
    Update-SessionPath
    $d = & $p.Detect
    if (-not $d.Installed) { throw "$($p.Name) did not install correctly. Try again, or use guided mode to see the installer." }
    Write-ToolLog "$($p.Name) installed$(if ($d.Version) { " ($($d.Version))" })." 'OK'
}

function Test-DownloadLinks {
    <# Maintenance check: confirms every download source still answers (no downloads). #>
    $checks = [ordered]@{
        'Visual C++ runtime' = $V.prereqs.vcRedist
        'Visual Studio Build Tools' = $V.prereqs.vsBuildTools
        "Boost $($V.prereqs.boost.version)" = $V.prereqs.boost.url
        "MySQL $($V.prereqs.mysql.version)" = $V.prereqs.mysql.url
        'Ollama' = $V.prereqs.ollama
        'Tailscale' = $V.prereqs.tailscale
        'OpenSSL checksum list' = $V.prereqs.opensslHashes
        'Python downloads' = 'https://www.python.org/ftp/python/'
        "Map data $($V.prereqs.clientDataFallbackVersion)" = "https://github.com/wowgaming/client-data/releases/download/$($V.prereqs.clientDataFallbackVersion)/Data.zip"
    }
    foreach ($k in $checks.Keys) {
        $ok = $false; $msg = ''
        try {
            $r = Invoke-WebRequest $checks[$k] -Method Head -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 30 -UserAgent 'Wget/1.21'
            $ok = $r.StatusCode -lt 400
            $len = $r.Headers['Content-Length']
            $msg = if ([double]$len -ge 1MB) { '{0:N0} MB' -f ([double]$len / 1MB) } else { 'reachable' }
        } catch { $msg = $_.Exception.Message }
        [pscustomobject]@{ Source = $k; Ok = $ok; Detail = $msg }
    }
    foreach ($repo in 'git-for-windows/git', 'Kitware/CMake', 'HeidiSQL/HeidiSQL') {
        try { $a = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'AzerothCoreCreationTool' } -TimeoutSec 30
              [pscustomobject]@{ Source = "$repo (latest release)"; Ok = $true; Detail = $a.tag_name } }
        catch { [pscustomobject]@{ Source = "$repo (latest release)"; Ok = $false; Detail = $_.Exception.Message } }
    }
}
