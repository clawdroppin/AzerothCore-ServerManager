# Install engine: the ordered list of steps that build a server from scratch.
# Every step is safe to re-run: it checks whether its work is already done first.
# Expects Common.ps1 to be loaded and these globals set by Invoke-Install:
#   $S (settings), $V (versions.json), $ToolDir, $Root

. (Join-Path $PSScriptRoot 'Prereqs.ps1')

function Get-StatePath { Join-Path $Root '.creationtool\state.json' }

function Read-State {
    $p = Get-StatePath
    if (Test-Path $p) { return (Get-Content $p -Raw | ConvertFrom-Json) }
    [pscustomobject]@{ Completed = @(); Tools = [pscustomobject]@{} }
}

function Save-State($State) {
    New-Item -ItemType Directory -Force (Split-Path (Get-StatePath)) | Out-Null
    $State | ConvertTo-Json -Depth 6 | Set-Content (Get-StatePath) -Encoding utf8
}

function Get-DownloadDir {
    # One download cache shared by all servers (installers, MySQL, map data), when the app's preferences exist.
    $d = if (Get-Command Get-AppPrefs -ErrorAction SilentlyContinue) { Join-Path (Get-AppPrefs).ServersFolder '_shared\downloads' } else { Join-Path $Root '.creationtool\downloads' }
    New-Item -ItemType Directory -Force $d | Out-Null
    $d
}

function Invoke-MySql([string]$Sql, [string]$Database = '', [string]$User = 'acore', [string]$Password = 'acore') {
    $ErrorActionPreference = 'Continue'   # mysql writes warnings to stderr; rely on exit code
    # With a shared database port, make sure this really is this server's database.
    if (Get-Command Assert-ServerDatabase -ErrorAction SilentlyContinue) { Assert-ServerDatabase $Root $S }
    $mysql = Join-Path $S.MySqlDir 'bin\mysql.exe'
    $cli = @("-u$User", '--host=127.0.0.1', "--port=$($S.DbPort)", '-N', '-B')
    if ($Password) { $cli += "-p$Password" }
    if ($Database) { $cli += $Database }
    $out = $Sql | & $mysql @cli 2>&1
    if ($LASTEXITCODE -ne 0) { throw "MySQL error: $(($out | Where-Object { $_ -notmatch 'Using a password' }) -join ' ')" }
    $out | Where-Object { $_ -notmatch 'Using a password' }
}

function Initialize-InstallDatabase {
    # Steps after "mysql" need this server's database running (also after a reboot or a resumed install).
    # With a shared database port another server's database may hold the port: swap it out first.
    $svc = Get-Service $S.MySqlService -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -eq 'Running') { return }
    if (Get-Command Enter-DatabaseSlot -ErrorAction SilentlyContinue) { Enter-DatabaseSlot $Root $S }
    Start-Service $S.MySqlService
    for ($i = 0; $i -lt 60 -and -not (Test-PortListening $S.DbPort); $i++) { Start-Sleep 1 }
}

function Save-SettingsFile {
    $copy = $S | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $copy.PSObject.Properties.Remove('PlayerPass')
    New-Item -ItemType Directory -Force (Join-Path $Root 'tools') | Out-Null
    $copy | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Root 'tools\server-settings.json') -Encoding utf8
}

function Invoke-ApplyConfig {
    $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\apply-config.ps1') 2>&1
    $out | ForEach-Object { Write-ToolLog "$_" }
    if ($LASTEXITCODE -ne 0) { throw 'Writing the server settings failed.' }
}

function Get-SelectedModules {
    $V.modules | Where-Object { $_.required -or ($S.Modules -contains $_.name) }
}

# Build mode compiles from source; import mode unpacks a server package made by Export.
function Test-BuildMode { $S.InstallMode -ne 'import' }

function Get-DataDir { if ($S.DataDir) { $S.DataDir } else { Join-Path $Root 'server\data' } }

function Restore-PackageDatabases([string]$PackageDir, [string[]]$Databases) {
    $mysql = Join-Path $S.MySqlDir 'bin\mysql.exe'
    foreach ($db in $Databases) {
        $file = Join-Path $PackageDir "db\$db.sql"
        if (-not (Test-Path $file)) { continue }
        Set-Detail "Loading $db ($([math]::Round((Get-Item $file).Length / 1MB)) MB)..."
        Invoke-MySql "CREATE DATABASE IF NOT EXISTS ``$db`` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | Out-Null
        Invoke-Native $mysql "-uacore -pacore --host=127.0.0.1 --port=$($S.DbPort) --max_allowed_packet=256M $db" -InputFile $file -Quiet | Out-Null
        Write-ToolLog "Loaded $db." 'OK'
    }
}

function Expand-ServerPackage([string]$Package) {
    # Unpacks once per install into .creationtool\package (reused if the install is resumed).
    $dir = Join-Path $Root '.creationtool\package'
    $marker = Join-Path $Root '.creationtool\package.source'
    # Reuse an earlier unpack only if it came from this same package file (resumed install).
    if ((Test-Path (Join-Path $dir 'manifest.json')) -and (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $Package)) { return $dir }
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    Set-Detail 'Unpacking the server package...'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Package, $dir)
    if (-not (Test-Path (Join-Path $dir 'manifest.json'))) { throw 'This file is not a server package made by AzerothCore Control Center.' }
    Set-Content $marker $Package
    $dir
}

function Test-BuildCacheStale([string]$Src) {
    # True when the build folder was configured for another location (the server folder was moved or renamed):
    # CMake then refuses to configure until its cache is removed.
    $cache = Join-Path $Src 'build\CMakeCache.txt'
    if (-not (Test-Path $cache)) { return $false }
    $m = Select-String $cache -Pattern '^CMAKE_HOME_DIRECTORY:INTERNAL=(.+)$' | Select-Object -First 1
    if (-not $m) { return $false }
    $m.Matches[0].Groups[1].Value.Trim().Replace('/', '\').TrimEnd('\') -ne $Src.TrimEnd('\')
}

function Clear-BuildCache([string]$Src) {
    Remove-Item (Join-Path $Src 'build\CMakeCache.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $Src 'build\CMakeFiles') -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-ServerBuild {
    <# Configures and compiles the server (build dir only - the running server is not touched).
       Compiler error lines are collected in $Global:BuildErrors so a failed update can name the culprit. #>
    $Global:BuildErrors = New-Object System.Collections.ArrayList
    $cmake = Find-CMake
    $src = Join-Path $Root 'azerothcore-wotlk'
    $build = Join-Path $src 'build'
    $fwd = { param($p) $p -replace '\\', '/' }
    if (Test-BuildCacheStale $src) {
        Write-ToolLog 'The build folder was set up for another location (moved server folder); configuring it fresh.' 'WARN'
        Clear-BuildCache $src
    }

    Set-Detail 'Configuring the build...'
    Invoke-Native $cmake ("-S `"$src`" -B `"$build`" -G `"Visual Studio 17 2022`" -A x64 " +
        "-DCMAKE_INSTALL_PREFIX=`"$(& $fwd (Join-Path $Root 'server'))`" " +
        '-DSCRIPTS=static -DMODULES=static -DAPPS_BUILD=all -DTOOLS_BUILD=db-only ' +
        '-DUSE_COREPCH=1 -DUSE_SCRIPTPCH=1 -DWITH_WARNINGS=0 -DBUILD_TESTING=0 ' +
        "-DBOOST_ROOT=`"$(& $fwd $V.prereqs.boost.dir)`" " +
        "-DOPENSSL_ROOT_DIR=`"$(& $fwd "$env:ProgramFiles\OpenSSL-Win64")`" " +
        "-DMYSQL_ROOT_DIR=`"$(& $fwd $S.MySqlDir)`"") -Quiet | Out-Null

    # Each cl.exe with precompiled headers needs ~1.5 GB; size parallelism to free RAM.
    $m = Get-MachineProfile
    $total = [math]::Max(2, [math]::Min($m.Threads, [math]::Floor($m.FreeRamGB / 1.5)))
    $projects = if ($total -ge 8) { 2 } else { 1 }
    $perProject = [math]::Max(1, [math]::Floor($total / $projects))

    $totalFiles = (Get-ChildItem (Join-Path $src 'src'), (Join-Path $src 'modules') -Recurse -Filter *.cpp -ErrorAction SilentlyContinue | Measure-Object).Count
    $script:compiled = 0
    $onLine = {
        param($l)
        if ($l -match '^\s+[\w.\-]+\.(cpp|cc|c)\s*$') {
            $script:compiled++
            if ($script:compiled % 5 -eq 0) {
                $pct = [math]::Min(99, [math]::Round(100 * $script:compiled / [math]::Max(1, $totalFiles)))
                Set-Detail "Compiling: $script:compiled of about $totalFiles files ($pct%)"
            }
        }
        if ($l -match 'error (C|LNK)\d+') { Write-ToolLog $l 'ERROR'; [void]$Global:BuildErrors.Add($l) }
    }
    $attempts = @(@($projects, $perProject), @(1, [math]::Max(1, [math]::Floor($perProject / 2))))
    $ok = $false
    foreach ($a in $attempts) {
        Write-ToolLog "Compiling with $($a[0]) project(s) x $($a[1]) compiler(s) (free RAM $($m.FreeRamGB) GB)."
        try {
            Invoke-Native $cmake "--build `"$build`" --config Release -- /m:$($a[0]) /p:CL_MPCount=$($a[1]) /nologo /v:minimal" -Quiet -OnLine $onLine | Out-Null
            $ok = $true; break
        } catch {
            if ($_.Exception -is [OperationCanceledException]) { throw }
            Write-ToolLog 'Compile failed; retrying with fewer parallel compilers (uses less memory).' 'WARN'
            $script:compiled = 0
        }
    }
    if (-not $ok) { throw 'The server failed to compile. Close other programs (to free memory) and click Retry.' }
    Write-ToolLog 'Server compiled successfully.' 'OK'
}

function Update-LlmBridge {
    # The bridge runs from its own copy (server\llm-bridge) so a moved server needs no source code.
    $bridge = Join-Path $Root 'server\llm-bridge'
    $srcTools = Join-Path $Root 'azerothcore-wotlk\modules\mod-llm-chatter\tools'
    if (Test-Path $srcTools) {
        New-Item -ItemType Directory -Force $bridge | Out-Null
        Copy-Item (Join-Path $srcTools '*') $bridge -Recurse -Force -Exclude '__pycache__', 'tests'
    }
    if (-not (Test-Path (Join-Path $bridge 'llm_chatter_bridge.py'))) { throw 'The AI chatter bridge files are missing.' }
    $venv = Join-Path $Root 'server\llm-bridge-venv'
    $py = Find-Python
    if (-not (Test-Path (Join-Path $venv 'Scripts\python.exe'))) { Invoke-Native $py "-m venv `"$venv`"" | Out-Null }
    $vpy = Join-Path $venv 'Scripts\python.exe'
    Invoke-Native $vpy '-m pip install --upgrade pip --quiet' -Quiet | Out-Null
    Invoke-Native $vpy "-m pip install -r `"$(Join-Path $bridge 'requirements.txt')`"" | Out-Null
    Write-ToolLog 'AI chatter bridge ready.' 'OK'
}

# ==================================================================== steps

$InstallSteps = @(

@{ Id = 'prepare'; Title = 'Preparing the install folder'; Run = {
    foreach ($d in 'secrets', 'tools', 'server\logs', 'database', '.creationtool') {
        New-Item -ItemType Directory -Force (Join-Path $Root $d) | Out-Null
    }
    $free = Get-FreeSpaceGB $Root
    $need = if (Test-BuildMode) { 30 } else { 10 }
    if ($free -lt $need) { throw "Only $free GB free on this drive. This server needs about $need GB. Free up space or choose another folder." }
    Save-SettingsFile
    Write-ToolLog "Install folder: $Root ($free GB free)" 'OK'
}},

@{ Id = 'vcredist'; Title = 'Installing Microsoft Visual C++ runtime'; Run = { Install-Prereq 'vcredist' } },
@{ Id = 'git'; Title = 'Installing Git'; When = { Test-BuildMode }; Run = { Install-Prereq 'git' } },
@{ Id = 'cmake'; Title = 'Installing CMake'; When = { Test-BuildMode }; Run = { Install-Prereq 'cmake' } },
@{ Id = 'msvc'; Title = 'Installing the C++ compiler (Visual Studio Build Tools) - this is a big download'; When = { Test-BuildMode }; Run = {
    Set-Detail 'Installing the C++ compiler. This downloads several GB and can take 10-40 minutes...'
    Install-Prereq 'msvc'
}},
@{ Id = 'boost'; Title = 'Installing Boost libraries'; When = { Test-BuildMode }; Run = { Install-Prereq 'boost'; & (Get-PrereqItem 'boost').After } },
@{ Id = 'openssl'; Title = 'Installing OpenSSL 3'; When = { Test-BuildMode }; Run = { Install-Prereq 'openssl' } },
@{ Id = 'mysql'; Title = 'Setting up the MySQL database server'; Run = {
    $my = $S.MySqlDir
    if (-not (Test-Path (Join-Path $my 'bin\mysqld.exe'))) {
        $zip = Get-RemoteFile -Url $V.prereqs.mysql.url -Destination (Join-Path (Get-DownloadDir) (Split-Path $V.prereqs.mysql.url -Leaf)) -Label "MySQL $($V.prereqs.mysql.version)"
        Set-Detail 'Unpacking MySQL...'
        $tmp = Join-Path $Root '.creationtool\mysql-extract'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
        Move-Item $inner.FullName $my
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Assert-Signed (Join-Path $my 'bin\mysqld.exe') 'Oracle'

    $data = Join-Path $Root 'database\data'
    $ini = Join-Path $Root 'database\my.ini'
    $fwd = { param($p) $p -replace '\\', '/' }
    @"
# MySQL for AzerothCore - generated by AzerothCore Creation Tool for this PC
[client]
port = $($S.DbPort)
default-character-set = utf8mb4

[mysqld]
basedir = "$(& $fwd $my)"
datadir = "$(& $fwd $data)"
port = $($S.DbPort)
bind-address = 127.0.0.1
mysqlx = OFF
log-error = "$(& $fwd (Join-Path $Root 'database\mysql-error.log'))"
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
default-storage-engine = InnoDB
skip-log-bin
max_connections = 500
thread_cache_size = 128
back_log = 512
table_open_cache = 8000
table_definition_cache = 4000
max_allowed_packet = 256M
sort_buffer_size = 4M
join_buffer_size = 4M
tmp_table_size = 256M
max_heap_table_size = 256M
innodb_buffer_pool_size = $($S.BufferPoolGB)G
innodb_buffer_pool_instances = $([math]::Max(1, [math]::Min(8, [int]$S.BufferPoolGB)))
innodb_redo_log_capacity = 1G
innodb_log_buffer_size = 64M
innodb_file_per_table = ON
# Bot saves are write-heavy: flush the redo log once per second (OS crash may lose ~1 s).
innodb_flush_log_at_trx_commit = 2
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000
innodb_flush_neighbors = 0
# READ-COMMITTED avoids gap-lock deadlocks when hundreds of bots save at once.
transaction_isolation = READ-COMMITTED
innodb_lock_wait_timeout = 120
"@ | Set-Content $ini -Encoding ascii

    if (-not (Test-Path (Join-Path $data 'mysql'))) {
        if (Test-Path $data) { Remove-Item $data -Recurse -Force }
        Set-Detail 'Creating the database storage...'
        Invoke-Native (Join-Path $my 'bin\mysqld.exe') "--defaults-file=`"$ini`" --initialize-insecure --console" | Out-Null
    }

    $svc = Get-Service $S.MySqlService -ErrorAction SilentlyContinue
    if (-not $svc) {
        Invoke-Native (Join-Path $my 'bin\mysqld.exe') "--install $($S.MySqlService) --defaults-file=`"$ini`"" | Out-Null
    }
    # With "stop with server" the database only runs while its game server runs (saves RAM with many servers).
    Set-Service $S.MySqlService -StartupType $(if ($S.MySqlStopWithServer) { 'Manual' } else { 'Automatic' })
    # Let the normal (non-admin) signed-in user start/stop this one service, so START/STOP never need a UAC prompt.
    # Same as Windows' default service permissions, plus start (RP), stop (WP) and pause (DT) for interactive users (IU).
    $sddl = 'D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPDTLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)'
    Invoke-Native "$env:SystemRoot\System32\sc.exe" "sdset $($S.MySqlService) $sddl" -Quiet | Out-Null
    if ((Get-Service $S.MySqlService).Status -eq 'Running') { Restart-Service $S.MySqlService -Force }
    else {
        if (Get-Command Enter-DatabaseSlot -ErrorAction SilentlyContinue) { Enter-DatabaseSlot $Root $S }   # shared database port
        Start-Service $S.MySqlService
    }
    for ($i = 0; $i -lt 60 -and -not (Test-PortListening $S.DbPort); $i++) { Start-Sleep 1 }
    if (-not (Test-PortListening $S.DbPort)) { throw "MySQL did not start. See $Root\database\mysql-error.log" }

    $rootFile = Join-Path $Root 'secrets\mysql-root.txt'
    $rootPw = if (Test-Path $rootFile) { ((Get-Content $rootFile -Raw) -split ':\s*')[-1].Trim() } else { $null }
    if (-not $rootPw) {
        $rootPw = New-RandomSecret 24
        Invoke-MySql "ALTER USER 'root'@'localhost' IDENTIFIED BY '$rootPw';" -User root -Password '' | Out-Null
        "MySQL root password (localhost only): $rootPw" | Set-Content $rootFile -Encoding ascii
    }
    Invoke-MySql @"
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED BY 'acore';
CREATE USER IF NOT EXISTS 'acore'@'127.0.0.1' IDENTIFIED BY 'acore';
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
"@ -User root -Password $rootPw | Out-Null
    Write-ToolLog "MySQL running as service '$($S.MySqlService)' on port $($S.DbPort)." 'OK'
}},

@{ Id = 'python'; Title = 'Installing Python (for AI chatter)'; When = { $S.Llm.Enabled }; Run = { Install-Prereq 'python' } },

@{ Id = 'ollama'; Title = 'Installing Ollama and the AI model'; When = { $S.Llm.Enabled }; Run = {
    Install-Prereq 'ollama'
    $o = Find-Ollama
    [Environment]::SetEnvironmentVariable('OLLAMA_CONTEXT_LENGTH', '8192', 'User')
    [Environment]::SetEnvironmentVariable('OLLAMA_NUM_PARALLEL', '3', 'User')
    $env:OLLAMA_CONTEXT_LENGTH = '8192'; $env:OLLAMA_NUM_PARALLEL = '3'
    if (-not (Test-PortListening 11434)) {
        Start-Process $o -ArgumentList 'serve' -WindowStyle Hidden
        for ($i = 0; $i -lt 30 -and -not (Test-PortListening 11434); $i++) { Start-Sleep 1 }
    }
    $model = $S.Llm.Model
    $ErrorActionPreference = 'Continue'
    $have = (& $o list 2>$null) -match "^$([regex]::Escape($model))\s"
    if ($have) { Write-ToolLog "AI model $model already downloaded." 'OK'; return }
    Invoke-Native $o "pull $model" -Quiet -OnLine {
        param($l)
        if ($l -match '(\d+)%.*?([\d.]+ [KMG]B)/([\d.]+ [KMG]B)') { Set-Detail "Downloading AI model ${model}: $($Matches[1])% ($($Matches[2]) of $($Matches[3]))" }
    } | Out-Null
    Write-ToolLog "AI model $model downloaded." 'OK'
}},

@{ Id = 'source'; Title = 'Downloading the AzerothCore source code and modules'; When = { Test-BuildMode }; Run = {
    $git = Find-Git
    $src = Join-Path $Root 'azerothcore-wotlk'
    if (-not (Test-Path (Join-Path $src '.git'))) {
        Invoke-Native $git "clone --depth 1 --branch $($V.core.branch) $($V.core.repo) `"$src`"" -Quiet | Out-Null
    } else {
        Invoke-Native $git 'pull --ff-only' -WorkingDirectory $src | Out-Null
    }
    foreach ($m in Get-SelectedModules) {
        $dst = Join-Path $src "modules\$($m.name)"
        Set-Detail "Downloading module $($m.name)..."
        if (-not (Test-Path (Join-Path $dst '.git'))) {
            Invoke-Native $git "clone --depth 1 --branch $($m.branch) $($m.repo) `"$dst`"" -Quiet | Out-Null
        } else {
            Invoke-Native $git 'pull --ff-only' -WorkingDirectory $dst | Out-Null
        }
        Write-ToolLog "Module $($m.name) ready." 'OK'
    }
    # "Make updatable" for a moved server: check out exactly the versions the server was built from.
    if ($S.PinCommits) {
        foreach ($pin in $S.PinCommits.PSObject.Properties) {
            $dir = if ($pin.Name -eq 'core') { $src } else { Join-Path $src "modules\$($pin.Name)" }
            if (-not (Test-Path (Join-Path $dir '.git'))) { continue }
            $have = (& $git -C $dir rev-parse HEAD 2>$null)
            if ($have -eq $pin.Value) { continue }
            Set-Detail "Getting the exact version of $($pin.Name) this server was built from..."
            Invoke-Native $git "fetch --depth 1 origin $($pin.Value)" -WorkingDirectory $dir -Quiet | Out-Null
            Invoke-Native $git "reset --hard $($pin.Value)" -WorkingDirectory $dir -Quiet | Out-Null
            Write-ToolLog "$($pin.Name) set to $($pin.Value.Substring(0, 9))." 'OK'
        }
    }
    $rev = (& $git -C $src rev-parse --short HEAD)
    Write-ToolLog "AzerothCore source ready (revision $rev)." 'OK'
}},

@{ Id = 'build'; Title = 'Compiling the server (the longest step: 30-90 minutes)'; When = { Test-BuildMode }; Run = { Invoke-ServerBuild } },

@{ Id = 'installbin'; Title = 'Installing the server files'; When = { Test-BuildMode }; Run = {
    $src = Join-Path $Root 'azerothcore-wotlk'
    Invoke-Native (Find-CMake) "--install `"$(Join-Path $src 'build')`" --config Release" -Quiet | Out-Null
    $srv = Join-Path $Root 'server'
    $ssl = "$env:ProgramFiles\OpenSSL-Win64\bin"
    foreach ($dll in 'libssl-3-x64.dll', 'libcrypto-3-x64.dll', 'legacy.dll') {
        $f = Get-ChildItem "$env:ProgramFiles\OpenSSL-Win64" -Recurse -Filter $dll | Select-Object -First 1
        if (-not $f) { throw "OpenSSL file $dll not found." }
        Copy-Item $f.FullName $srv -Force
    }
    Copy-Item (Join-Path $S.MySqlDir 'lib\libmysql.dll') $srv -Force
    foreach ($exe in 'worldserver.exe', 'authserver.exe', 'dbimport.exe') {
        if (-not (Test-Path (Join-Path $srv $exe))) { throw "$exe is missing after install." }
    }
    # Record exactly which versions these programs were built from (used by safe updates and moves).
    if (Get-Command Save-ServerVersionLock -ErrorAction SilentlyContinue) { Save-ServerVersionLock $Root }
    Write-ToolLog 'Server files installed.' 'OK'
}},

@{ Id = 'unpack'; Title = 'Unpacking the server package'; When = { -not (Test-BuildMode) }; Run = {
    $pkg = Expand-ServerPackage $S.ImportPackage
    foreach ($d in 'server', 'tools', 'secrets') {
        $from = Join-Path $pkg $d
        if (Test-Path $from) { Copy-Item (Join-Path $from '*') (Join-Path $Root $d) -Recurse -Force }
    }
    Get-ChildItem $pkg -Filter *.bat | Copy-Item -Destination $Root -Force
    # Map data travels in the package when it was included at export time.
    $pkgData = Join-Path $pkg 'data'
    if (Test-Path (Join-Path $pkgData 'dbc')) {
        $dataDir = Get-DataDir
        New-Item -ItemType Directory -Force $dataDir | Out-Null
        Set-Detail 'Copying map data...'
        Copy-Item (Join-Path $pkgData '*') $dataDir -Recurse -Force
    }
    foreach ($exe in 'worldserver.exe', 'authserver.exe') {
        if (-not (Test-Path (Join-Path $Root "server\$exe"))) { throw "The package does not contain $exe." }
    }
    Write-ToolLog 'Server files unpacked (no compiling needed).' 'OK'
}},

@{ Id = 'clientdata'; Title = 'Downloading world map data (about 1.2 GB)'; Run = {
    $dataDir = Get-DataDir
    $fn = Join-Path $Root 'azerothcore-wotlk\apps\installer\includes\functions.sh'
    $ver = if ($S.ClientDataVersion) { $S.ClientDataVersion } else { $V.prereqs.clientDataFallbackVersion }
    if (Test-Path $fn) {
        $m = Select-String $fn -Pattern 'local VERSION=(v[\d.]+)' | Select-Object -First 1
        if ($m) { $ver = $m.Matches[0].Groups[1].Value }
    }
    $S | Add-Member -NotePropertyName ClientDataVersion -NotePropertyValue $ver -Force
    Save-SettingsFile
    $marker = Join-Path $dataDir 'data-version'
    if ((Test-Path $marker) -and ((Get-Content $marker -Raw) -match [regex]::Escape($ver))) {
        Write-ToolLog "Map data $ver already present in $dataDir (shared between servers)." 'OK'; return
    }
    $zip = Get-RemoteFile -Url "https://github.com/wowgaming/client-data/releases/download/$ver/Data.zip" `
        -Destination (Join-Path (Get-DownloadDir) "client-data-$ver.zip") -Label "map data $ver"
    Set-Detail 'Unpacking map data (several minutes)...'
    if (Test-Path $dataDir) { Remove-Item $dataDir -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dataDir)
    foreach ($d in 'dbc', 'maps', 'vmaps', 'mmaps') {
        if (-not (Test-Path (Join-Path $dataDir $d))) { throw "Map data is incomplete ($d missing)." }
    }
    "INSTALLED_VERSION=$ver" | Set-Content $marker -Encoding ascii
    Write-ToolLog "Map data $ver installed." 'OK'
}},

@{ Id = 'config'; Title = 'Writing server settings'; Run = {
    $payload = Join-Path $ToolDir 'payload'
    Copy-Item (Join-Path $payload 'tools\*') (Join-Path $Root 'tools') -Force
    Get-ChildItem $payload -Filter *.bat | Copy-Item -Destination $Root -Force
    Save-SettingsFile
    Invoke-ApplyConfig
}},

@{ Id = 'databases'; Title = 'Creating the game databases (several minutes)'; When = { Test-BuildMode }; Run = {
    $srv = Join-Path $Root 'server'
    Set-Detail 'Importing the world database (about 1.5 GB of data)...'
    Invoke-Native (Join-Path $srv 'dbimport.exe') '' -WorkingDirectory $srv -Quiet -OnLine {
        param($l) if ($l -match 'Database (\w+) is empty|Updating (\w+) database|Applying update') { Set-Detail "Databases: $l" }
    } | Out-Null
    $tables = Invoke-MySql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='acore_world';"
    if ([int]($tables | Select-Object -Last 1) -lt 100) { throw 'The world database was not created correctly.' }
    Write-ToolLog 'Databases created.' 'OK'
}},

@{ Id = 'restore'; Title = 'Loading accounts, characters and bots from the package'; When = { (-not (Test-BuildMode)) -or $S.RestorePackage }; Run = {
    $package = if (Test-BuildMode) { $S.RestorePackage } else { $S.ImportPackage }
    $pkg = Expand-ServerPackage $package
    $manifest = Get-Content (Join-Path $pkg 'manifest.json') -Raw | ConvertFrom-Json
    $dbs = @('acore_auth', 'acore_characters', 'acore_playerbots')
    if (-not (Test-BuildMode)) { $dbs = @('acore_world') + $dbs }   # a moved server has no source to rebuild the world from
    Restore-PackageDatabases $pkg $dbs
    # The realm entry came from the other PC: point it back at this PC until friends are set up again.
    Invoke-MySql "UPDATE realmlist SET address='127.0.0.1', localAddress='127.0.0.1' WHERE id=1;" 'acore_auth' | Out-Null
    Invoke-MySql "UPDATE characters SET online=0;" 'acore_characters' | Out-Null
    $chars = Invoke-MySql "SELECT COUNT(*) FROM characters;" 'acore_characters' | Select-Object -Last 1
    Write-ToolLog "Restored $($manifest.ServerName): $chars characters." 'OK'
}},

@{ Id = 'accounts'; Title = 'Creating your game account'; Run = {
    $tool = Join-Path $Root 'tools\New-GameAccount.ps1'
    $run = { param($u, $p, $gm)
        $ErrorActionPreference = 'Continue'
        $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $tool -Username $u -Password $p -GmLevel $gm 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Account creation failed for ${u}: $o" }
        Write-ToolLog "$o" 'OK'
    }
    # Admin account used by STOP_SERVER.bat to save and shut down cleanly (SOAP, localhost only).
    $soapFile = Join-Path $Root 'secrets\soap.txt'
    if (-not (Test-Path $soapFile)) { "User=SERVERADMIN`r`nPassword=$(New-RandomSecret 16)" | Set-Content $soapFile -Encoding ascii }
    $soap = Get-Content $soapFile | ConvertFrom-StringData
    & $run $soap.User $soap.Password 3

    if ($S.PlayerPass) {
        & $run $S.PlayerUser $S.PlayerPass $(if ($S.PlayerIsGm) { 3 } else { 0 })
        "Username: $($S.PlayerUser.ToUpper())`r`nPassword: $($S.PlayerPass)" | Set-Content (Join-Path $Root 'secrets\my-game-login.txt') -Encoding ascii
    }

    if ($S.Modules -contains 'mod-ah-bot-plus') {
        $ahFile = Join-Path $Root 'secrets\ahbot-account.txt'
        if (-not (Test-Path $ahFile)) { "User=AHBOT`r`nPassword=$(New-RandomSecret 16)" | Set-Content $ahFile -Encoding ascii }
        $ahAcc = Get-Content $ahFile | ConvertFrom-StringData
        & $run $ahAcc.User $ahAcc.Password 0
        $accId = [int](Invoke-MySql "SELECT id FROM account WHERE username='AHBOT';" 'acore_auth' | Select-Object -Last 1)
        $existing = @(Invoke-MySql "SELECT guid FROM characters WHERE account=$accId ORDER BY guid;" 'acore_characters')
        if ($existing.Count -lt 3) {
            $next = [int](Invoke-MySql 'SELECT COALESCE(MAX(guid),0)+1 FROM characters;' 'acore_characters' | Select-Object -Last 1)
            $sellers = @(
                @{ Name = 'Tradewind';   Race = 1; Gender = 0; X = -8833.38; Y = 628.62;   Z = 94.0;  Map = 0; O = 1.06; Zone = 1519 },
                @{ Name = 'Goldvein';    Race = 2; Gender = 0; X = 1629.36;  Y = -4373.39; Z = 31.25; Map = 1; O = 3.55; Zone = 1637 },
                @{ Name = 'Silverpurse'; Race = 1; Gender = 1; X = -8833.38; Y = 628.62;   Z = 94.0;  Map = 0; O = 1.06; Zone = 1519 })
            $rows = for ($i = 0; $i -lt 3; $i++) {
                $c = $sellers[$i]
                "($($next + $i), $accId, '$($c.Name)', $($c.Race), 1, $($c.Gender), 1, 0, 0, $($c.X), $($c.Y), $($c.Z), $($c.Map), $($c.O), '0 0 0 0 0 0 0 0 0 0 0 0 0 0 ', 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, $($c.Zone), 0, '', 0, 0, 0, 0, 0, 0, 0, 0, 0, 4294967295, 0, 100, 0, 0, 0, 100, 0, 0, 0, 0, 1, 0, '', '', 0, '', 0, 0, NOW(), NULL, NULL, NULL, 0, 0)"
            }
            Invoke-MySql @"
INSERT IGNORE INTO characters (guid, account, name, race, class, gender, level, xp, money, position_x, position_y, position_z, map, orientation, taximask, online, cinematic, totaltime, leveltime, logout_time, is_logout_resting, rest_bonus, resettalents_cost, resettalents_time, trans_x, trans_y, trans_z, trans_o, transguid, extra_flags, stable_slots, at_login, zone, death_expire_time, taxi_path, arenaPoints, totalHonorPoints, todayHonorPoints, yesterdayHonorPoints, totalKills, todayKills, yesterdayKills, chosenTitle, knownCurrencies, watchedFaction, drunk, health, power1, power2, power3, power4, power5, power6, power7, latency, talentGroupsCount, activeTalentGroup, exploredZones, equipmentCache, ammoId, knownTitles, actionBars, grantableLevels, creation_date, deleteInfos_Account, deleteInfos_Name, deleteDate, innTriggerId, extraBonusTalentCount)
VALUES $($rows -join ",`n");
"@ 'acore_characters' | Out-Null
            $existing = @(Invoke-MySql "SELECT guid FROM characters WHERE account=$accId ORDER BY guid;" 'acore_characters')
        }
        $S.AhBotGuids = ($existing | Select-Object -First 3) -join ','
        Save-SettingsFile
        Invoke-ApplyConfig
        Write-ToolLog "Auction House sellers ready (character IDs $($S.AhBotGuids))." 'OK'
    }
}},

@{ Id = 'bridge'; Title = 'Setting up the AI chatter bridge'; When = { $S.Llm.Enabled -and ($S.Modules -contains 'mod-llm-chatter') }; Run = { Update-LlmBridge } },

@{ Id = 'client'; Title = 'Connecting your game client and creating shortcuts'; Run = {
  if (-not $S.WowExe -or -not (Test-Path $S.WowExe)) {
    Write-ToolLog 'No game folder chosen yet - skipping the realmlist (set it later with "Launch WoW").' 'WARN'
  } else {
    $game = Split-Path $S.WowExe -Parent
    $backup = Join-Path $Root '.creationtool\client-backup'
    New-Item -ItemType Directory -Force $backup | Out-Null
    foreach ($rl in Get-ChildItem (Join-Path $game 'Data') -Recurse -Filter realmlist.wtf -Depth 1 -ErrorAction SilentlyContinue) {
        $dst = Join-Path $backup ("realmlist-" + $rl.Directory.Name + ".wtf")
        if (-not (Test-Path $dst)) { Copy-Item $rl.FullName $dst }
        'set realmlist 127.0.0.1' | Set-Content $rl.FullName -Encoding ascii
    }
    $cfg = Join-Path $game 'WTF\Config.wtf'
    if (Test-Path $cfg) {
        if (-not (Test-Path (Join-Path $backup 'Config.wtf'))) { Copy-Item $cfg $backup }
        $lines = Get-Content $cfg | Where-Object { $_ -notmatch '^SET (realmlist|realmName|accountName) ' }
        $lines += 'SET realmlist "127.0.0.1"', "SET realmName `"$($S.RealmName)`""
        Set-Content $cfg $lines -Encoding ascii
    } else {
        New-Item -ItemType Directory -Force (Split-Path $cfg) | Out-Null
        @('SET realmlist "127.0.0.1"', "SET realmName `"$($S.RealmName)`"") | Set-Content $cfg -Encoding ascii
    }
  }

    $realmType = if ([int]$S.GameType -eq 1) { 1 } else { 0 }
    Invoke-MySql "UPDATE realmlist SET name='$($S.RealmName -replace "'", "''")', icon=$realmType WHERE id=1;" 'acore_auth' | Out-Null

    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    # One pair of shortcuts per server, named after it, so several servers never overwrite each other's.
    $label = ($S.RealmName -replace '[\\/:*?"<>|]', '').Trim()
    foreach ($sc in @(
        @{ Name = "Start $label"; Target = 'START_SERVER.bat' },
        @{ Name = "Stop $label"; Target = 'STOP_SERVER.bat' })) {
        $lnk = $shell.CreateShortcut((Join-Path $desktop "$($sc.Name).lnk"))
        $lnk.TargetPath = Join-Path $Root $sc.Target
        $lnk.WorkingDirectory = $Root
        $lnk.Save()
    }
    Write-ToolLog 'Game client now points to your server; desktop shortcuts created.' 'OK'
}}
)

# ==================================================================== runner

function Invoke-Install {
    <# -StepIds runs exactly those steps (ignoring what was completed before) - used by updates and module changes. #>
    param($Settings, [string]$ToolDirectory, [string[]]$StepIds)
    $Global:S = $Settings
    $Global:ToolDir = $ToolDirectory
    $Global:Root = $Settings.RootDir
    $Global:V = Get-Content (Join-Path $ToolDirectory 'config\versions.json') -Raw | ConvertFrom-Json
    New-Item -ItemType Directory -Force (Join-Path $Root '.creationtool') | Out-Null
    $Global:ToolLogFile = Join-Path $Root ".creationtool\install-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Update-SessionPath
    if ($env:BOOST_ROOT -eq $null) { $env:BOOST_ROOT = [Environment]::GetEnvironmentVariable('BOOST_ROOT', 'Machine') }

    $state = Read-State
    $completed = [Collections.Generic.List[string]]::new()
    foreach ($c in @($state.Completed)) { if ($c) { $completed.Add($c) } }

    foreach ($step in $InstallSteps) {
        if ($StepIds -and $StepIds -notcontains $step.Id) { continue }
        if ($step.When -and -not (& $step.When)) { $Sync.Steps[$step.Id] = 'skipped'; continue }
        if (-not $StepIds -and $completed.Contains($step.Id)) { $Sync.Steps[$step.Id] = 'done'; continue }
        Assert-NotCancelled
        $Sync.Steps[$step.Id] = 'running'
        $Sync.Current = $step.Title
        Set-Detail ''
        Write-ToolLog "=== $($step.Title) ==="
        try {
            if ($step.Id -ne 'mysql' -and $completed.Contains('mysql')) { Initialize-InstallDatabase }
            & $step.Run
            $Sync.Steps[$step.Id] = 'done'
            if (-not $completed.Contains($step.Id)) { $completed.Add($step.Id) }
            $state.Completed = $completed.ToArray()
            Save-State $state
        } catch {
            $Sync.Steps[$step.Id] = 'failed'
            $msg = if ($_.Exception -is [OperationCanceledException]) { 'Cancelled.' } else { $_.Exception.Message }
            Write-ToolLog "$($step.Title) failed: $msg" 'ERROR'
            Write-ToolLog "Full log: $ToolLogFile" 'INFO'
            throw
        }
    }
    Set-Detail ''
    # The unpacked package (databases, map data) is only needed during the install.
    $pkgDir = Join-Path $Root '.creationtool\package'
    if (Test-Path $pkgDir) { Remove-Item $pkgDir -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path $Root '.creationtool\package.source') -Force -ErrorAction SilentlyContinue
    if (Get-Command Register-Server -ErrorAction SilentlyContinue) {
        # Add it to the app's server list and make sure it really landed there.
        try {
            Register-Server $Root $S.RealmName
            if (Get-ServerRegistry | Where-Object { $_.RootDir.TrimEnd('\') -eq $Root.TrimEnd('\') }) { Write-ToolLog "Added '$($S.RealmName)' to the app's server list." 'OK' }
            else { Write-ToolLog "Could not add the server to the app's server list - use My servers > Add existing folder." 'WARN' }
        } catch { Write-ToolLog "Could not add the server to the app's server list ($($_.Exception.Message)) - use My servers > Add existing folder." 'WARN' }
    }
    $Sync.Current = 'Finished'
    Write-ToolLog $(if ($StepIds) { '=== Done ===' } else { '=== Your server is ready! ===' }) 'OK'
}


