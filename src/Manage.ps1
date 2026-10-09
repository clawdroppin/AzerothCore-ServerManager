# Management backend for installed servers (no UI code here).
# Every function takes the server root folder; settings come from <root>\tools\server-settings.json.
# Requires Common.ps1.

$RegistryFile = Join-Path $env:LOCALAPPDATA 'AzerothCoreCreationTool\servers.json'
$GamePorts = @{ Auth = 3724; World = 8085 }

# ================================================================== server registry

function Get-ServerRegistry {
    # Another app window (or a scheduled task) may be writing the file right now: retry, then fall back to the
    # backup copy. Never return an empty list for a damaged file - a later save would then forget every server.
    $data = $null
    foreach ($f in $RegistryFile, "$RegistryFile.bak") {
        if (-not (Test-Path $f)) { continue }
        for ($i = 0; $i -lt 5 -and $null -eq $data; $i++) {
            try { $data = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 150 }
        }
        if ($null -ne $data) { break }
    }
    if ($null -eq $data) {
        if (Test-Path $RegistryFile) { throw "The app's server list ($RegistryFile) could not be read." }
        return @()
    }
    # PowerShell 5.1 returns a JSON array as ONE pipeline object; foreach unrolls it (and any older nested copies).
    $out = New-Object System.Collections.ArrayList
    $walk = { param($x) foreach ($i in @($x)) { if ($i -is [array]) { & $walk $i } elseif ($i -and $i.RootDir) { [void]$out.Add($i) } } }
    & $walk $data
    # One entry per folder.
    $seen = @{}
    foreach ($e in $out) { if (-not $seen.ContainsKey($e.RootDir.ToLower())) { $seen[$e.RootDir.ToLower()] = $true; $e } }
}

function Save-ServerRegistry($list) {
    New-Item -ItemType Directory -Force (Split-Path $RegistryFile) | Out-Null
    $flat = @(foreach ($i in @($list)) { if ($i -and $i.RootDir) { [pscustomobject]@{ Name = "$($i.Name)"; RootDir = "$($i.RootDir)"; Added = "$($i.Added)" } } })
    # Atomic replace (write a temp file, then swap it in) and keep the previous list as .bak.
    $tmp = "$RegistryFile.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $flat -Depth 3), (New-Object Text.UTF8Encoding($true)))
    if (Test-Path $RegistryFile) { [IO.File]::Replace($tmp, $RegistryFile, "$RegistryFile.bak") } else { Move-Item $tmp $RegistryFile }
}

function Register-Server([string]$Root, [string]$Name) {
    $list = @(Get-ServerRegistry | Where-Object { $_.RootDir -ne $Root })
    $list += [pscustomobject]@{ Name = $Name; RootDir = $Root; Added = (Get-Date -Format 'yyyy-MM-dd') }
    Save-ServerRegistry $list
}

function Unregister-Server([string]$Root) {
    Save-ServerRegistry @(Get-ServerRegistry | Where-Object { $_.RootDir -ne $Root })
}

function Test-ServerRoot([string]$Root) {
    (Test-Path (Join-Path $Root 'tools\server-settings.json')) -and (Test-Path (Join-Path $Root 'server\worldserver.exe'))
}

# ================================================================== export / import packages
# A package is a .zip (extension .wowserver) with:
#   manifest.json        what is inside + the server's settings
#   db\<database>.sql    database dumps (portable between PCs and MySQL versions)
#   server\ tools\ *.bat compiled server + helper scripts ("full" packages only; no compiling needed)
#   data\                map data (optional)
#   secrets\             admin passwords (optional)

$PackageFormat = 1

function Export-Server {
    param(
        [string]$Root,
        [string]$OutFile,
        [ValidateSet('full', 'data')][string]$Kind = 'full',
        [switch]$IncludeMapData,
        [switch]$IncludeSecrets
    )
    $s = Get-ServerSettings $Root
    $stage = Join-Path $Root '.creationtool\export-staging'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force (Join-Path $stage 'db') | Out-Null
    try {
        # ---- databases (consistent snapshot even while the server runs)
        $ErrorActionPreference = 'Continue'
        $dump = Join-Path $s.MySqlDir 'bin\mysqldump.exe'
        $dbs = @('acore_auth', 'acore_characters')
        if (Invoke-ServerSql $Root "SHOW DATABASES LIKE 'acore_playerbots';") { $dbs += 'acore_playerbots' }
        if ($Kind -eq 'full') { $dbs += 'acore_world' }
        foreach ($db in $dbs) {
            Set-Detail "Exporting database $db..."
            $err = & $dump '-uacore' '-pacore' '--host=127.0.0.1' "--port=$($s.DbPort)" '--single-transaction' '--routines' '--triggers' '--add-drop-table' '--hex-blob' "--result-file=$(Join-Path $stage "db\$db.sql")" $db 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Exporting $db failed: $(($err | Where-Object { "$_" -notmatch 'Using a password' }) -join ' ')" }
        }
        $ErrorActionPreference = 'Stop'

        # ---- program files
        if ($Kind -eq 'full') {
            Set-Detail 'Collecting server files...'
            $srv = Join-Path $Root 'server'
            $dst = Join-Path $stage 'server'
            New-Item -ItemType Directory -Force $dst | Out-Null
            Get-ChildItem $srv -File | Copy-Item -Destination $dst
            Copy-Item (Join-Path $srv 'configs') $dst -Recurse
            $bridge = Join-Path $srv 'llm-bridge'
            if (-not (Test-Path (Join-Path $bridge 'llm_chatter_bridge.py'))) { $bridge = Join-Path $Root 'azerothcore-wotlk\modules\mod-llm-chatter\tools' }
            if (Test-Path (Join-Path $bridge 'llm_chatter_bridge.py')) {
                Copy-Item $bridge (Join-Path $dst 'llm-bridge') -Recurse -Exclude '__pycache__'
            }
            Copy-Item (Join-Path $Root 'tools') (Join-Path $stage 'tools') -Recurse
            Get-ChildItem $Root -Filter *.bat | Copy-Item -Destination $stage
            if ($IncludeMapData) {
                $data = if ($s.DataDir) { $s.DataDir } else { Join-Path $srv 'data' }
                Set-Detail 'Collecting map data (3 GB)...'
                Copy-Item $data (Join-Path $stage 'data') -Recurse
            }
        }
        # Drop run-time leftovers that must not travel (Python caches, the stop marker).
        Get-ChildItem $stage -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
        Remove-Item (Join-Path $stage 'server\stop.requested') -Force -ErrorAction SilentlyContinue
        if ($IncludeSecrets -and (Test-Path (Join-Path $Root 'secrets'))) {
            Copy-Item (Join-Path $Root 'secrets') (Join-Path $stage 'secrets') -Recurse -Exclude 'mysql-root.txt'
        }

        # ---- manifest
        $git = Find-Git
        $rev = if ($git -and (Test-Path (Join-Path $Root 'azerothcore-wotlk\.git'))) { (& $git -C (Join-Path $Root 'azerothcore-wotlk') rev-parse --short HEAD 2>$null) } else { $s.CoreRevision }
        $settingsCopy = $s | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        foreach ($p in 'PlayerPass', 'RootDir', 'MySqlDir', 'MySqlService', 'DbPort', 'DataDir', 'WowExe', 'ImportPackage', 'RestorePackage', 'PublicAddress', 'LocalAddress', 'BackupCopyDir', 'PinCommits') {
            $settingsCopy.PSObject.Properties.Remove($p)
        }
        [pscustomobject]@{
            Format = $PackageFormat; Kind = $Kind; ServerName = $s.RealmName
            Created = (Get-Date -Format 's'); FromComputer = $env:COMPUTERNAME
            CoreRevision = "$rev"; Modules = @($s.Modules); ClientDataVersion = $s.ClientDataVersion
            IncludesMapData = [bool]($IncludeMapData -and $Kind -eq 'full'); IncludesSecrets = [bool]$IncludeSecrets
            Databases = $dbs; Settings = $settingsCopy
        } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $stage 'manifest.json') -Encoding utf8

        # ---- zip
        Set-Detail 'Packing (this can take a few minutes)...'
        New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
        if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $OutFile, [IO.Compression.CompressionLevel]::Fastest, $false)
    } finally {
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    Get-Item $OutFile
}

function Read-ServerPackage([string]$File) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($File)
    try {
        $entry = $zip.GetEntry('manifest.json')
        if (-not $entry) { throw 'This file is not a server package made by AzerothCore Control Center.' }
        $reader = New-Object IO.StreamReader($entry.Open())
        $m = $reader.ReadToEnd() | ConvertFrom-Json
        $reader.Dispose()
        if ([int]$m.Format -gt $PackageFormat) { throw 'This package was made by a newer version of the app. Update the app first.' }
        $m | Add-Member -NotePropertyName SizeMB -NotePropertyValue ([math]::Round((Get-Item $File).Length / 1MB)) -Force
        $m
    } finally { $zip.Dispose() }
}

# ================================================================== app preferences

$PrefsFile = Join-Path $env:LOCALAPPDATA 'AzerothCoreCreationTool\preferences.json'

function Get-AppPrefs {
    $p = $null
    if (Test-Path $PrefsFile) { try { $p = Get-Content $PrefsFile -Raw | ConvertFrom-Json } catch {} }
    if (-not $p) { $p = [pscustomobject]@{} }
    if (-not $p.ServersFolder) {
        $best = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object FreeSpace -Descending | Select-Object -First 1
        $p | Add-Member -NotePropertyName ServersFolder -NotePropertyValue (Join-Path ($best.DeviceID + '\') 'WoWServers') -Force
    }
    if (-not $p.ExportsFolder) { $p | Add-Member -NotePropertyName ExportsFolder -NotePropertyValue (Join-Path $p.ServersFolder '_exports') -Force }
    if ($null -eq $p.ShareMapData) { $p | Add-Member -NotePropertyName ShareMapData -NotePropertyValue $true -Force }
    $p
}

function Save-AppPrefs($Prefs) {
    New-Item -ItemType Directory -Force (Split-Path $PrefsFile) | Out-Null
    $Prefs | ConvertTo-Json -Depth 4 | Set-Content $PrefsFile -Encoding utf8
}

function Get-SharedDataDir { Join-Path (Get-AppPrefs).ServersFolder '_shared\client-data' }

# ================================================================== multi-server helpers

function Get-RunningServerRoot {
    # Root folder of the AzerothCore server whose worldserver/authserver is running (any folder), or $null.
    $p = Get-Process worldserver, authserver -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
    if ($p) { Split-Path (Split-Path $p.Path -Parent) -Parent } else { $null }
}

function Get-FolderSizeGB([string]$Path) {
    if (-not (Test-Path $Path)) { return 0 }
    $sum = (Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [math]::Round($sum / 1GB, 1)
}

function Get-ServerSummary([string]$Root, [switch]$WithSize) {
    $s = Get-ServerSettings $Root
    $running = [bool](Get-ServerProcessInfo $Root 'worldserver')
    [pscustomobject]@{
        Root = $Root; Name = $s.RealmName
        Version = @('Vanilla (60)', 'Burning Crusade (70)', 'Wrath (80)')[[int]$s.Expansion]
        Type = if ([int]$s.GameType -eq 1) { 'PvP' } else { 'PvE' }
        Bots = [int]$s.Bots; Rate = "$($s.Rates.XPKill)x"
        Modules = @($s.Modules | Where-Object { $_ -ne 'mod-playerbots' })
        Ai = [bool]$s.Llm.Enabled
        Running = $running
        CanUpdate = Test-Path (Join-Path $Root 'azerothcore-wotlk\.git')
        HasBuildLeftovers = Test-Path (Join-Path $Root 'azerothcore-wotlk\build')
        SizeGB = if ($WithSize) { Get-FolderSizeGB $Root } else { $null }
    }
}

function Remove-BuildLeftovers([string]$Root) {
    # Deletes compile intermediates (~5 GB). Updates afterwards recompile from scratch (slower, same result).
    $b = Join-Path $Root 'azerothcore-wotlk\build'
    if (Test-Path $b) { Remove-Item $b -Recurse -Force }
}

function Start-ServerDatabase([string]$Root) {
    $s = Get-ServerSettings $Root
    $svc = Get-Service $s.MySqlService -ErrorAction SilentlyContinue
    if (-not $svc) { throw "The database service '$($s.MySqlService)' is missing." }
    if ($svc.Status -eq 'Running') { return }
    Start-Service $s.MySqlService
    for ($i = 0; $i -lt 60 -and -not (Test-PortListening ([int]$s.DbPort)); $i++) { Start-Sleep -Milliseconds 500 }
    # Remember that the app (not the game server) started it, so it can be stopped again when the app closes.
    New-Item -ItemType Directory -Force (Join-Path $Root '.creationtool') | Out-Null
    Set-Content (Join-Path $Root '.creationtool\db-started-by-app') (Get-Date -Format o)
}

function Stop-AppStartedDatabases {
    foreach ($srv in Get-ServerRegistry) {
        $marker = Join-Path $srv.RootDir '.creationtool\db-started-by-app'
        if (-not (Test-Path $marker)) { continue }
        Remove-Item $marker -ErrorAction SilentlyContinue
        try {
            $s = Get-ServerSettings $srv.RootDir
            if ($s.MySqlStopWithServer -and -not (Get-ServerProcessInfo $srv.RootDir 'worldserver')) { Stop-Service $s.MySqlService -ErrorAction SilentlyContinue }
        } catch {}
    }
}

function Remove-ServerInstall {
    <# Deletes a server completely: scheduled tasks, its own database service, shortcuts, the app entry and its folder. #>
    param([string]$Root)
    if (Get-ServerProcessInfo $Root 'worldserver') { throw 'Stop the server first.' }
    $s = Get-ServerSettings $Root
    $names = @((Get-BackupScheduleTaskName $Root), (Get-RestartTaskName $Root), (Get-AutostartTaskName $Root), (Get-EventTaskName $Root))
    if (Get-Command Get-AutoUpdateTaskName -ErrorAction SilentlyContinue) { $names += Get-AutoUpdateTaskName $Root }
    foreach ($n in $names) {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
    }
    # Only remove the database service if it belongs to this folder (never a shared/system MySQL).
    $svc = Get-CimInstance Win32_Service -Filter "Name='$($s.MySqlService)'" -ErrorAction SilentlyContinue
    if ($svc -and $svc.PathName -like "*$Root*") {
        Stop-Service $s.MySqlService -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        & "$env:SystemRoot\System32\sc.exe" delete $s.MySqlService | Out-Null
        Start-Sleep -Seconds 1
    }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($lnk in Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -Filter *.lnk -ErrorAction SilentlyContinue) {
        if ($shell.CreateShortcut($lnk.FullName).TargetPath -like "$Root\*") { Remove-Item $lnk.FullName -Force }
    }
    Unregister-Server $Root
    # Console windows of this server (START_SERVER / monitor) keep the folder in use: close them.
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe' OR Name='powershell.exe' OR Name='conhost.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($Root, [StringComparison]::OrdinalIgnoreCase) -ge 0 } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    Remove-Item -LiteralPath $Root -Recurse -Force
}

# ================================================================== import a server not made by this tool

function Get-ConfValue([string]$File, [string]$Key) {
    if (-not (Test-Path $File)) { return $null }
    $line = Select-String $File -Pattern ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*)$') | Select-Object -Last 1
    if ($line) { $line.Matches[0].Groups[1].Value.Trim().Trim('"') } else { $null }
}

function Import-ExistingServer {
    <# Builds tools\server-settings.json for an AzerothCore server folder that this tool did not create.
       -DryRun returns the detected settings without writing anything. #>
    param([string]$Root, [string]$ToolDirectory, [switch]$DryRun)
    $cfg = Join-Path $Root 'server\configs'
    $ws = Join-Path $cfg 'worldserver.conf'
    if (-not (Test-Path $ws)) { throw "No server\configs\worldserver.conf in $Root." }

    $dbInfo = (Get-ConfValue $ws 'LoginDatabaseInfo') -split ';'
    if ($dbInfo.Count -lt 5) { throw 'Could not read the database connection from worldserver.conf.' }
    if ($dbInfo[2] -ne 'acore' -or $dbInfo[3] -ne 'acore') { throw 'This server uses a database login other than acore/acore, which this app does not support yet.' }
    $port = [int]$dbInfo[1]

    # Find the MySQL Windows service that serves that port.
    $svc = $null; $mysqlDir = $null; $bufferGB = 4
    foreach ($s in Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'mysqld' }) {
        $exe = if ($s.PathName -match '^"([^"]+)"') { $Matches[1] } else { ($s.PathName -split '\s')[0] }
        $ini = if ($s.PathName -match '--defaults-file="?([^"]+?\.ini)"?(\s|$)') { $Matches[1] } else { Join-Path (Split-Path (Split-Path $exe)) 'my.ini' }
        $iniPort = 3306
        if (Test-Path $ini) {
            $m = Select-String $ini -Pattern '^\s*port\s*=\s*(\d+)' | Select-Object -First 1
            if ($m) { $iniPort = [int]$m.Matches[0].Groups[1].Value }
            $b = Select-String $ini -Pattern '^\s*innodb_buffer_pool_size\s*=\s*(\d+)G' | Select-Object -First 1
            if ($b) { $bufferGB = [int]$b.Matches[0].Groups[1].Value }
        }
        if ($iniPort -eq $port) { $svc = $s.Name; $mysqlDir = Split-Path (Split-Path $exe); break }
    }
    if (-not $svc) { throw "No MySQL Windows service found for port $port." }

    $pbConf = Join-Path $cfg 'modules\playerbots.conf'
    $llmConf = Join-Path $cfg 'modules\mod_llm_chatter.conf'
    $ahConf = Join-Path $cfg 'modules\mod_ahbot.conf'
    $num = { param($v, $d) if ($v -match '^[\d.]+$') { [double]$v } else { $d } }
    $modules = @(Get-ChildItem (Join-Path $Root 'azerothcore-wotlk\modules') -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName '.git') } | ForEach-Object Name)

    $realmName = 'AzerothCore'
    $mysql = Join-Path $mysqlDir 'bin\mysql.exe'
    $ErrorActionPreference = 'Continue'
    $r = & $mysql '-uacore' '-pacore' '--host=127.0.0.1' "--port=$port" '-N' '-e' 'SELECT name FROM acore_auth.realmlist WHERE id=1' 2>$null
    if ($LASTEXITCODE -eq 0 -and $r) { $realmName = "$($r | Select-Object -Last 1)".Trim() }
    $ErrorActionPreference = 'Stop'

    $settings = [pscustomobject]@{
        RootDir = $Root; WowExe = ''; RealmName = $realmName
        GameType = [int](& $num (Get-ConfValue $ws 'GameType') 0)
        Expansion = [int](& $num (Get-ConfValue $ws 'Expansion') 2)
        Bots = [int](& $num (Get-ConfValue $pbConf 'AiPlayerbot.MaxRandomBots') 0)
        BotsStartAtLevel1 = (Get-ConfValue $pbConf 'AiPlayerbot.DisableRandomLevels') -eq '1'
        BotsAutoBattlegrounds = (Get-ConfValue $pbConf 'AiPlayerbot.RandomBotAutoJoinBG') -eq '1'
        Rates = [pscustomobject]@{
            XPKill = & $num (Get-ConfValue $ws 'Rate.XP.Kill') 1
            XPQuest = & $num (Get-ConfValue $ws 'Rate.XP.Quest') 1
            XPExplore = & $num (Get-ConfValue $ws 'Rate.XP.Explore') 1
            Money = & $num (Get-ConfValue $ws 'Rate.Drop.Money') 1
            Crafting = & $num (Get-ConfValue $ws 'SkillGain.Crafting') 1
            Gathering = & $num (Get-ConfValue $ws 'SkillGain.Gathering') 1
            Weapon = & $num (Get-ConfValue $ws 'SkillGain.Weapon') 1
            Reputation = & $num (Get-ConfValue $ws 'Rate.Reputation.Gain') 1
            Honor = & $num (Get-ConfValue $ws 'Rate.Honor') 1
        }
        Modules = $modules
        Llm = [pscustomobject]@{
            Enabled = (Get-ConfValue $llmConf 'LLMChatter.Enable') -eq '1'
            Model = "$(Get-ConfValue $llmConf 'LLMChatter.Model')"
            Preset = 'default'
        }
        PlayerUser = ''; PlayerIsGm = $true
        DbPort = $port; SoapPort = [int](& $num (Get-ConfValue $ws 'SOAP.Port') 7878)
        MySqlService = $svc; MySqlDir = $mysqlDir; BufferPoolGB = $bufferGB
        MapThreads = [int](& $num (Get-ConfValue $ws 'MapUpdate.Threads') 4)
        CharDbWorkers = [int](& $num (Get-ConfValue $ws 'CharacterDatabase.WorkerThreads') 2)
        AhBotGuids = "$(Get-ConfValue $ahConf 'AuctionHouseBot.GUIDs')"
        BackupKeep = 10; PublicAddress = ''; LocalAddress = ''
    }
    if ($DryRun) { return $settings }

    # Install this app's helper scripts, keeping the originals.
    $tools = Join-Path $Root 'tools'
    $keep = Join-Path $tools ("pre-import-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force $keep | Out-Null
    Get-ChildItem $tools -File -ErrorAction SilentlyContinue | Copy-Item -Destination $keep
    Get-ChildItem $Root -Filter *.bat -File | Copy-Item -Destination $keep
    Copy-Item (Join-Path $ToolDirectory 'payload\tools\*') $tools -Force
    Get-ChildItem (Join-Path $ToolDirectory 'payload') -Filter *.bat | Copy-Item -Destination $Root -Force
    $settings | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $tools 'server-settings.json') -Encoding utf8
    if (-not (Test-Path (Join-Path $Root 'secrets\soap.txt'))) {
        Write-Warning 'secrets\soap.txt is missing: Stop/Console need an admin account. Create one and save it as User=/Password= in that file.'
    }
    $settings
}

# ================================================================== settings

function Get-ServerSettings([string]$Root) {
    $s = Get-Content (Join-Path $Root 'tools\server-settings.json') -Raw | ConvertFrom-Json
    # Fill fields added in later versions of the tool.
    $defaults = @{
        SoapPort = 7878; CharDbWorkers = 2; MapThreads = 4; AhBotGuids = ''; BotsAutoBattlegrounds = $true
        BotsStartAtLevel1 = $true; PublicAddress = ''; LocalAddress = ''; BackupKeep = 10
        MySqlStopWithServer = $false; DataDir = ''; InstallMode = 'build'; ClientDataVersion = ''
        ConfOverrides = [pscustomobject]@{}; Events = @(); UpdatePinned = $false; BackupCopyDir = ''
        Notify = [pscustomobject]@{ OnStartStop = $true; OnCrash = $true; OnLogin = $true; OnUpdate = $true }
    }
    foreach ($k in $defaults.Keys) { if ($null -eq $s.$k) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force } }
    # JSON arrays come back as one object in PowerShell 5.1: keep Events a real list.
    $s.Events = @(foreach ($e in @($s.Events)) { foreach ($i in @($e)) { if ($i -and $i.Name) { $i } } })
    if ($null -eq $s.Llm.Preset) { $s.Llm | Add-Member -NotePropertyName Preset -NotePropertyValue 'default' -Force }
    $s
}

function Save-ServerSettings([string]$Root, $Settings) {
    $copy = $Settings | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $copy.PSObject.Properties.Remove('PlayerPass')
    $copy | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Root 'tools\server-settings.json') -Encoding utf8
}

# ================================================================== config options (Extra settings / All options)
# Every server option lives in a .conf file generated from its .conf.dist by tools\apply-config.ps1.
# Options the user changes in the app are stored as overrides in server-settings.json (ConfOverrides),
# keyed by the file's path relative to server\configs, e.g. 'modules/playerbots.conf'.

$ConfFileTitles = @{
    'worldserver.conf' = 'World server'; 'authserver.conf' = 'Login server'; 'modules/playerbots.conf' = 'Playerbots (bots)'
    'modules/mod_ahbot.conf' = 'Auction House bot'; 'modules/mod_llm_chatter.conf' = 'AI chatter'
    'modules/mod_dungeon_clear.conf' = 'Dungeon Clear'; 'modules/mod_dungeon_master.conf' = 'Dungeon Master'
    'modules/mod-mounts-on-account.conf' = 'Mounts on account'
}

function Get-ConfFiles([string]$Root) {
    $cfg = Join-Path $Root 'server\configs'
    $dists = @(Get-ChildItem $cfg -Filter *.conf.dist -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'dbimport.conf.dist') +
             @(Get-ChildItem (Join-Path $cfg 'modules') -Filter *.conf.dist -File -ErrorAction SilentlyContinue)
    foreach ($d in $dists) {
        $rel = ($d.FullName.Substring($cfg.Length + 1) -replace '\.dist$', '').Replace('\', '/').ToLower()
        $title = $ConfFileTitles[$rel]
        if (-not $title) { $title = (Get-Culture).TextInfo.ToTitleCase((($d.Name -replace '\.conf\.dist$', '') -replace '^mod[_-]', '' -replace '[_-]', ' ')) }
        [pscustomobject]@{ Rel = $rel; Title = $title; Dist = $d.FullName; Conf = ($d.FullName -replace '\.dist$', '') }
    }
}

function Read-ConfValues([string]$Path) {
    # key -> raw value (first occurrence), for a .conf or .conf.dist file.
    $kv = @{}
    if (-not (Test-Path $Path)) { return $kv }
    foreach ($l in [IO.File]::ReadLines($Path)) {
        if ($l -match '^\s*([A-Za-z][\w.\-]*)\s*=\s*(.*?)\s*$' -and -not $kv.ContainsKey($Matches[1])) { $kv[$Matches[1]] = $Matches[2] }
    }
    $kv
}

function Get-ConfOptions([string]$Dist) {
    <# Every option in a .conf.dist with its default and the comment above it (the developers' own description). #>
    $out = New-Object System.Collections.ArrayList
    $pending = New-Object System.Collections.Generic.List[string]
    $block = ''
    foreach ($line in [IO.File]::ReadLines($Dist)) {
        if ($line -match '^\s*#') {
            $t = ($line -replace '^\s*#+', '').TrimEnd()
            if ($t -notmatch '^[\s#=\-*]*$') { $pending.Add($t) }
        } elseif ($line -match '^\s*([A-Za-z][\w.\-]*)\s*=\s*(.*?)\s*$') {
            $key = $Matches[1]; $def = $Matches[2]
            if ($pending.Count) {
                # Section headings (ALL CAPS lines) are not part of the option's own description.
                $lastHead = -1
                for ($i = 0; $i -lt $pending.Count; $i++) { if ($pending[$i].Trim() -cmatch '^[A-Z0-9 &()/+,.\-]{4,}#?$') { $lastHead = $i } }
                if ($lastHead -ge 0) { $pending.RemoveRange(0, $lastHead + 1) }
                # Remove the common indentation.
                $min = ($pending | Where-Object { $_.Trim() } | ForEach-Object { $_.Length - $_.TrimStart().Length } | Measure-Object -Minimum).Minimum
                $block = (($pending | ForEach-Object { if ($_.Length -ge $min) { $_.Substring([int]$min) } else { $_.Trim() } }) -join "`n").Trim()
                $pending.Clear()
            }
            [void]$out.Add([pscustomobject]@{ Key = $key; Default = $def; Description = $block })
        } elseif ($line -match '^\s*\[') { $pending.Clear() }
    }
    $out
}

function Get-ConfOverrideTable($Settings) {
    # rel file -> hashtable(key -> value)
    $t = @{}
    if ($Settings.ConfOverrides) {
        foreach ($f in $Settings.ConfOverrides.PSObject.Properties) {
            $h = @{}; foreach ($k in $f.Value.PSObject.Properties) { $h[$k.Name] = "$($k.Value)" }
            if ($h.Count) { $t[$f.Name.ToLower()] = $h }
        }
    }
    $t
}

function Set-ConfOverrideTable($Settings, [hashtable]$Table) {
    $o = [ordered]@{}
    foreach ($f in ($Table.Keys | Sort-Object)) {
        if (-not $Table[$f].Count) { continue }
        $h = [ordered]@{}; foreach ($k in ($Table[$f].Keys | Sort-Object)) { $h[$k] = "$($Table[$f][$k])" }
        $o[$f] = [pscustomobject]$h
    }
    $Settings | Add-Member -NotePropertyName ConfOverrides -NotePropertyValue ([pscustomobject]$o) -Force
}

function Format-ConfValue([string]$Value, [string]$Default) {
    # Text options are written in quotes in the .conf files; keep that form when the user types without them.
    $v = $Value.Trim()
    if ($Default.StartsWith('"') -and -not $v.StartsWith('"')) { $v = '"' + $v.Trim('"') + '"' }
    $v
}

function Get-MaxLevel($Settings) { @(60, 70, 80)[[int]$Settings.Expansion] }

function Update-ModuleConfigOverrides($Settings, $Catalog) {
    <# Some modules need server options to work (e.g. Individual Progression needs EnablePlayerSettings = 1).
       The catalog lists them per module ("config"); they are set while the module is on and removed when it is off. #>
    $table = Get-ConfOverrideTable $Settings
    foreach ($m in @($Catalog)) {
        if (-not $m.config) { continue }
        $on = @($Settings.Modules) -contains $m.name
        foreach ($f in $m.config.PSObject.Properties) {
            $rel = $f.Name.ToLower()
            if (-not $table[$rel]) { $table[$rel] = @{} }
            foreach ($k in $f.Value.PSObject.Properties) {
                if ($on) { $table[$rel][$k.Name] = "$($k.Value)" }
                elseif ($table[$rel][$k.Name] -eq "$($k.Value)") { $table[$rel].Remove($k.Name) }
            }
        }
    }
    Set-ConfOverrideTable $Settings $table
}

function Sync-ServerTools([string]$Root) {
    <# Every server folder has its own copy of the helper scripts (tools\*.ps1 and the .bat files), so it also works
       without the app. Refresh them whenever this app has newer versions, so fixes and new features reach old servers. #>
    $td = if ($global:ToolDir) { $global:ToolDir } else { $null }
    if (-not $td -or -not (Test-Path (Join-Path $td 'payload\tools'))) { return }
    $pairs = @(Get-ChildItem (Join-Path $td 'payload\tools') -File | ForEach-Object { , @($_, (Join-Path $Root "tools\$($_.Name)")) }) +
             @(Get-ChildItem (Join-Path $td 'payload') -Filter *.bat -File | ForEach-Object { , @($_, (Join-Path $Root $_.Name)) })
    foreach ($p in $pairs) {
        $src, $dst = $p
        if ((Test-Path $dst) -and (Get-FileHash $dst -Algorithm MD5).Hash -eq (Get-FileHash $src.FullName -Algorithm MD5).Hash) { continue }
        if (-not (Test-Path (Split-Path $dst))) { continue }
        try { Copy-Item $src.FullName $dst -Force } catch { Write-Warning "Could not refresh $dst ($($_.Exception.Message))" }
    }
}

function Invoke-ApplyServerConfig([string]$Root) {
    Sync-ServerTools $Root
    $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\apply-config.ps1') 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Applying settings failed: $($out -join ' ')" }
    $out
}

# ================================================================== database & SOAP

function Invoke-ServerSql {
    param([string]$Root, [string]$Sql, [string]$Database = 'acore_auth', [switch]$Raw, [switch]$NoAutoStart)
    $ErrorActionPreference = 'Continue'
    $s = Get-ServerSettings $Root
    # A server whose database stops with it may have MySQL off: start it on demand (the app stops it again on exit).
    if (-not $NoAutoStart -and -not (Test-PortListening ([int]$s.DbPort))) { Start-ServerDatabase $Root }
    $mysql = Join-Path $s.MySqlDir 'bin\mysql.exe'
    $out = $Sql | & $mysql '-uacore' '-pacore' '--host=127.0.0.1' "--port=$($s.DbPort)" '-N' '-B' $Database 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Database error: $(($out | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'Using a password' }) -join ' ')"
    }
    $rows = @($out | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'Using a password' })
    if ($Raw) { return $rows }
    $rows
}

function ConvertFrom-SqlRows([string[]]$Rows, [string[]]$Columns) {
    foreach ($r in $Rows) {
        if (-not $r) { continue }
        $parts = $r -split "`t"
        $o = [ordered]@{}
        for ($i = 0; $i -lt $Columns.Count; $i++) { $o[$Columns[$i]] = if ($i -lt $parts.Count -and $parts[$i] -ne 'NULL') { $parts[$i] } else { '' } }
        [pscustomobject]$o
    }
}

function ConvertTo-SqlString([string]$Text) { "'" + ($Text -replace '\\', '\\\\' -replace "'", "''") + "'" }

function Invoke-ServerSoap([string]$Root, [string]$Command) {
    $s = Get-ServerSettings $Root
    $credFile = Join-Path $Root 'secrets\soap.txt'
    if (-not (Test-Path $credFile)) { throw 'Admin (SOAP) credentials are missing from the secrets folder.' }
    $c = Get-Content $credFile | ConvertFrom-StringData
    $auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($c.User):$($c.Password)"))
    $body = '<?xml version="1.0" encoding="utf-8"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:AC"><SOAP-ENV:Body><ns1:executeCommand><command>' +
        [Security.SecurityElement]::Escape($Command.TrimStart('.')) + '</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>'
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$($s.SoapPort)/" -Method Post -Body $body -ContentType 'text/xml; charset=utf-8' `
            -Headers @{ Authorization = $auth } -UseBasicParsing -TimeoutSec 20
        $content = $resp.Content
    } catch [Net.WebException] {
        $r = $_.Exception.Response
        if (-not $r) { throw 'The world server is not running (or not accepting admin commands yet).' }
        $content = (New-Object IO.StreamReader($r.GetResponseStream())).ReadToEnd()
    }
    $text = if ($content -match '<result>([\s\S]*?)</result>') { $Matches[1] }
            elseif ($content -match '<faultstring>([\s\S]*?)</faultstring>') { $Matches[1] }
            else { $content }
    [Net.WebUtility]::HtmlDecode($text).Replace("`r", '').Trim()
}

# ================================================================== status

function Get-ServerProcessInfo([string]$Root, [string]$Name) {
    $serverDir = Join-Path $Root 'server'
    Get-Process -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($serverDir, [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1
}

function Get-ServerStatus([string]$Root) {
    $s = Get-ServerSettings $Root
    $svc = Get-Service $s.MySqlService -ErrorAction SilentlyContinue
    $auth = Get-ServerProcessInfo $Root 'authserver'
    $world = Get-ServerProcessInfo $Root 'worldserver'
    $bridge = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*llm_chatter_bridge.py*' -and $_.CommandLine -like "*$Root*" }
    $st = [ordered]@{
        Name = $s.RealmName
        MySql = if ($svc) { "$($svc.Status)" } else { 'Missing' }
        Auth = [bool]$auth
        World = [bool]$world
        WorldPid = if ($world) { $world.Id } else { $null }
        WorldRamGB = if ($world) { [math]::Round($world.WorkingSet64 / 1GB, 2) } else { 0 }
        Uptime = if ($world) { (Get-Date) - $world.StartTime } else { $null }
        Bridge = [bool]$bridge
        LlmEnabled = [bool]$s.Llm.Enabled
        Ollama = Test-PortListening 11434
        SoapReady = $false
        PlayersOnline = 0; BotsOnline = 0
        TickMean = $null; TickMedian = $null; TickP99 = $null
        Starting = $false
    }
    if ($world) {
        $st.SoapReady = Test-PortListening ([int]$s.SoapPort)
        $st.Starting = -not (Test-PortListening $GamePorts.World)
        if ($st.SoapReady) {
            try {
                $info = Invoke-ServerSoap $Root 'server info'
                if ($info -match 'Mean:\s*(\d+)ms') { $st.TickMean = [int]$Matches[1] }
                if ($info -match 'Median:\s*(\d+)ms') { $st.TickMedian = [int]$Matches[1] }
                if ($info -match '\(95, 99, max\):\s*\d+ms,\s*(\d+)ms') { $st.TickP99 = [int]$Matches[1] }
            } catch {}
        }
    }
    if ($svc -and $svc.Status -eq 'Running') {
        try {
            $r = Invoke-ServerSql $Root @"
SELECT
  SUM(CASE WHEN a.username LIKE 'RNDBOT%' THEN 1 ELSE 0 END),
  SUM(CASE WHEN a.username NOT LIKE 'RNDBOT%' AND a.username <> 'AHBOT' THEN 1 ELSE 0 END)
FROM acore_characters.characters c JOIN acore_auth.account a ON a.id = c.account WHERE c.online = 1;
"@
            $p = ($r | Select-Object -Last 1) -split "`t"
            $st.BotsOnline = [int]('0' + ($p[0] -replace 'NULL', ''))
            $st.PlayersOnline = [int]('0' + ($p[1] -replace 'NULL', ''))
        } catch {}
    }
    [pscustomobject]$st
}

function Start-GameServer([string]$Root) {
    # Launched through Explorer so the server is independent of this app (survives it closing).
    Sync-ServerTools $Root
    Start-Process explorer.exe -ArgumentList "`"$(Join-Path $Root 'START_SERVER.bat')`""
}

function Stop-GameServer([string]$Root) {
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\ServerControl.ps1') -Action Stop 2>&1 | ForEach-Object { "$_" }
}

# ================================================================== accounts

function Get-GameAccounts([string]$Root, [switch]$IncludeBots) {
    $filter = if ($IncludeBots) { '' } else { "WHERE a.username NOT LIKE 'RNDBOT%'" }
    $rows = Invoke-ServerSql $Root @"
SELECT a.id, a.username, COALESCE(MAX(aa.gmlevel),0), a.last_login, a.online,
  (SELECT COUNT(*) FROM account_banned b WHERE b.id = a.id AND b.active = 1),
  (SELECT COUNT(*) FROM acore_characters.characters c WHERE c.account = a.id), a.last_ip
FROM account a LEFT JOIN account_access aa ON aa.id = a.id $filter
GROUP BY a.id ORDER BY a.id;
"@
    ConvertFrom-SqlRows $rows 'Id', 'Username', 'GmLevel', 'LastLogin', 'Online', 'Banned', 'Characters', 'LastIp' | ForEach-Object {
        $_.Online = $_.Online -eq '1'; $_.Banned = $_.Banned -ne '0'; $_
    }
}

function New-ServerAccount([string]$Root, [string]$User, [string]$Pass, [int]$GmLevel = 0) {
    $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\New-GameAccount.ps1') -Username $User -Password $Pass -GmLevel $GmLevel 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$($out -join ' ')" }
    "$($out -join ' ')"
}

function Set-AccountGmLevel([string]$Root, [string]$User, [int]$Level) {
    $u = ConvertTo-SqlString $User.ToUpper()
    $sql = "SET @id=(SELECT id FROM account WHERE username=$u); DELETE FROM account_access WHERE id=@id;"
    if ($Level -gt 0) { $sql += " INSERT INTO account_access (id, gmlevel, RealmID) SELECT @id, $Level, -1 FROM DUAL WHERE @id IS NOT NULL;" }
    Invoke-ServerSql $Root $sql | Out-Null
}

function Set-AccountBan([string]$Root, [string]$User, [bool]$Banned, [string]$Reason = 'Banned by server owner') {
    $st = Get-ServerStatus $Root
    if ($st.SoapReady) {
        if ($Banned) { return Invoke-ServerSoap $Root "ban account $User -1 $Reason" }
        return Invoke-ServerSoap $Root "unban account $User"
    }
    $u = ConvertTo-SqlString $User.ToUpper()
    if ($Banned) {
        Invoke-ServerSql $Root "INSERT INTO account_banned (id, bandate, unbandate, bannedby, banreason, active) SELECT id, UNIX_TIMESTAMP(), UNIX_TIMESTAMP(), 'Control Center', $(ConvertTo-SqlString $Reason), 1 FROM account WHERE username=$u;" | Out-Null
    } else {
        Invoke-ServerSql $Root "UPDATE account_banned SET active=0 WHERE id=(SELECT id FROM account WHERE username=$u);" | Out-Null
    }
    'Done.'
}

function Remove-ServerAccount([string]$Root, [string]$User) {
    $st = Get-ServerStatus $Root
    if (-not $st.SoapReady) { throw 'Start the server first: accounts are deleted through the server so their characters are cleaned up properly.' }
    Invoke-ServerSoap $Root "account delete $User"
}

# ================================================================== characters / bots

$ClassNames = @{ 1 = 'Warrior'; 2 = 'Paladin'; 3 = 'Hunter'; 4 = 'Rogue'; 5 = 'Priest'; 6 = 'Death Knight'; 7 = 'Shaman'; 8 = 'Mage'; 9 = 'Warlock'; 11 = 'Druid' }
$RaceNames = @{ 1 = 'Human'; 2 = 'Orc'; 3 = 'Dwarf'; 4 = 'Night Elf'; 5 = 'Undead'; 6 = 'Tauren'; 7 = 'Gnome'; 8 = 'Troll'; 10 = 'Blood Elf'; 11 = 'Draenei' }

function Get-ServerCharacters([string]$Root, [ValidateSet('Players', 'Bots', 'All')][string]$Kind = 'Players', [switch]$OnlineOnly, [int]$Limit = 500) {
    $where = @()
    if ($Kind -eq 'Players') { $where += "a.username NOT LIKE 'RNDBOT%'"; $where += "a.username <> 'AHBOT'" }
    if ($Kind -eq 'Bots') { $where += "a.username LIKE 'RNDBOT%'" }
    if ($OnlineOnly) { $where += 'c.online = 1' }
    $w = if ($where) { 'WHERE ' + ($where -join ' AND ') } else { '' }
    $rows = Invoke-ServerSql $Root @"
SELECT c.guid, c.name, c.level, c.race, c.class, c.zone, c.online, a.username, c.money, c.totaltime
FROM acore_characters.characters c JOIN acore_auth.account a ON a.id = c.account $w
ORDER BY c.online DESC, c.level DESC, c.name LIMIT $Limit;
"@
    ConvertFrom-SqlRows $rows 'Guid', 'Name', 'Level', 'Race', 'Class', 'Zone', 'Online', 'Account', 'Money', 'PlayedSec' | ForEach-Object {
        $_.Race = $RaceNames[[int]$_.Race]; $_.Class = $ClassNames[[int]$_.Class]
        $_.Online = $_.Online -eq '1'
        $_.Money = '{0}g' -f [math]::Floor([double]$_.Money / 10000)
        $_.PlayedSec = '{0}h' -f [math]::Round([double]$_.PlayedSec / 3600, 1)
        $_
    }
}

function Get-BotLevelDistribution([string]$Root) {
    # Does not wake a stopped database just to draw a chart.
    if (-not (Test-PortListening ([int](Get-ServerSettings $Root).DbPort))) { return @() }
    $rows = Invoke-ServerSql $Root @"
SELECT LEAST(FLOOR((c.level-1)/10),7), COUNT(*) FROM acore_characters.characters c
JOIN acore_auth.account a ON a.id = c.account WHERE a.username LIKE 'RNDBOT%' GROUP BY 1 ORDER BY 1;
"@
    ConvertFrom-SqlRows $rows 'Bucket', 'Count' | ForEach-Object {
        $b = [int]$_.Bucket
        [pscustomobject]@{ Range = '{0}-{1}' -f ($b * 10 + 1), ($b * 10 + 10); Count = [int]$_.Count }
    }
}

# ================================================================== backups

function Get-BackupDir([string]$Root) { $d = Join-Path $Root 'backups'; New-Item -ItemType Directory -Force $d | Out-Null; $d }

function New-ServerBackup([string]$Root, [string]$Label = 'manual', [switch]$IncludeWorld) {
    # Single implementation shared with the daily scheduled task: tools\Backup-Server.ps1
    Sync-ServerTools $Root
    $ErrorActionPreference = 'Continue'
    Set-Detail $(if ($IncludeWorld) { 'Saving everything (accounts, characters, bots and the world)...' } else { 'Backing up accounts, characters and bot data...' })
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'tools\Backup-Server.ps1'), '-Label', $Label)
    if ($IncludeWorld) { $args2 += '-IncludeWorld' }
    $out = & powershell @args2 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "Backup failed: $($out -join ' ')" }
    $line = $out | Where-Object { $_ -like 'Backup created:*' } | Select-Object -Last 1
    ($line -replace '^Backup created:\s*', '').Trim()
}
function Get-ServerBackups([string]$Root) {
    $kinds = @{ 'before-update' = 'Safety copy (before update)'; savepoint = 'Save point (everything)'; daily = 'Daily'; manual = 'Manual'; 'before-restore' = 'Before a restore' }
    Get-ChildItem (Get-BackupDir $Root) -Filter *.zip | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $label = if ($_.BaseName -match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-(.+)$') { $Matches[1] } else { '' }
        [pscustomobject]@{
            Name = $_.BaseName; File = $_.FullName; Date = $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); SizeMB = [math]::Round($_.Length / 1MB, 1)
            Kind = if ($kinds[$label]) { $kinds[$label] } else { $label }
        }
    }
}


function Restore-ServerBackup([string]$Root, [string]$ZipFile, [switch]$NoSafetyBackup, [switch]$RestoreSettings) {
    if ((Get-ServerStatus $Root).World) { throw 'Stop the server before restoring a backup.' }
    $s = Get-ServerSettings $Root
    if (-not $NoSafetyBackup) {
        $safety = New-ServerBackup $Root 'before-restore'
        Write-ToolLog "Safety backup of the current state: $safety" 'OK'
    }
    $tmp = Join-Path (Get-BackupDir $Root) '_restore'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, $tmp)
    $mysql = Join-Path $s.MySqlDir 'bin\mysql.exe'
    foreach ($f in Get-ChildItem $tmp -Filter *.sql) {
        $db = $f.BaseName
        Set-Detail "Restoring $db..."
        Invoke-ServerSql $Root "CREATE DATABASE IF NOT EXISTS ``$db`` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | Out-Null
        $ErrorActionPreference = 'Continue'
        $out = cmd /c "`"$mysql`" -uacore -pacore --host=127.0.0.1 --port=$($s.DbPort) $db < `"$($f.FullName)`" 2>&1"
        if ($LASTEXITCODE -ne 0) { throw "Restoring $db failed: $(($out | Where-Object { "$_" -notmatch 'Using a password' }) -join ' ')" }
        Write-ToolLog "Restored $db." 'OK'
    }
    # A save point also remembers the settings of that moment (speed, bots, extra options...).
    $savedSettings = Join-Path $tmp 'server-settings.json'
    if ($RestoreSettings -and (Test-Path $savedSettings)) {
        $old = Get-Content $savedSettings -Raw | ConvertFrom-Json
        # Keep this PC's paths and ports; take everything about the game from the save point.
        foreach ($k in 'RootDir', 'MySqlDir', 'MySqlService', 'DbPort', 'DataDir', 'WowExe', 'SoapPort', 'AhBotGuids') { $old | Add-Member -NotePropertyName $k -NotePropertyValue $s.$k -Force }
        Save-ServerSettings $Root $old
        Invoke-ApplyServerConfig $Root | Out-Null
        Write-ToolLog 'Settings restored from the save point.' 'OK'
    }
    Remove-Item $tmp -Recurse -Force
}

function Remove-ServerBackup([string]$Root, [string]$ZipFile) {
    $full = (Resolve-Path $ZipFile).Path
    if (-not $full.StartsWith((Get-BackupDir $Root), [StringComparison]::OrdinalIgnoreCase) -or $full -notlike '*.zip') { throw 'Not a backup of this server.' }
    Remove-Item -LiteralPath $full -Force
}

$BackupTaskName = 'AzerothCore daily backup'
function Get-BackupScheduleTaskName([string]$Root) { "$BackupTaskName ($((Get-ServerSettings $Root).RealmName -replace '[\\/:*?""<>|]', ''))" }

function Set-BackupSchedule([string]$Root, [bool]$Enabled, [string]$Time = '05:00') {
    $name = Get-BackupScheduleTaskName $Root
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $Enabled) { return }
    $script = Join-Path $Root 'tools\Backup-Server.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $trigger = New-ScheduledTaskTrigger -Daily -At $Time
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Description "Backs up the accounts and characters of $Root" | Out-Null
}

function Get-BackupSchedule([string]$Root) {
    $t = Get-ScheduledTask -TaskName (Get-BackupScheduleTaskName $Root) -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    ([datetime]$t.Triggers[0].StartBoundary).ToString('HH:mm')
}

# ================================================================== auto-start with Windows

function Get-AutostartTaskName([string]$Root) { "AzerothCore autostart ($((Get-ServerSettings $Root).RealmName -replace '[\\/:*?""<>|]', ''))" }

function Set-ServerAutostart([string]$Root, [bool]$Enabled) {
    $name = Get-AutostartTaskName $Root
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $Enabled) { return }
    $action = New-ScheduledTaskAction -Execute (Join-Path $Root 'START_SERVER.bat') -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trigger.Delay = 'PT1M'
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Description "Starts the WoW server in $Root when you sign in" | Out-Null
}

function Get-ServerAutostart([string]$Root) { [bool](Get-ScheduledTask -TaskName (Get-AutostartTaskName $Root) -ErrorAction SilentlyContinue) }

# ================================================================== logs

function Get-ServerLogFiles([string]$Root) {
    $d = Join-Path $Root 'server\logs'
    if (-not (Test-Path $d)) { return @() }
    Get-ChildItem $d -File -Filter *.log | Sort-Object LastWriteTime -Descending | ForEach-Object Name
}

function Get-ServerLogTail([string]$Root, [string]$File, [int]$Lines = 400, [string]$Filter) {
    $p = Join-Path (Join-Path $Root 'server\logs') $File
    if (-not (Test-Path $p)) { return '' }
    # Read shared: the server keeps its logs open.
    $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
    try {
        $max = 4MB
        if ($fs.Length -gt $max) { $fs.Seek(-$max, 'End') | Out-Null }
        $text = (New-Object IO.StreamReader($fs)).ReadToEnd()
    } finally { $fs.Dispose() }
    $all = $text -split "`r?`n"
    if ($Filter) { $all = $all | Where-Object { $_ -match [regex]::Escape($Filter) } }
    ($all | Select-Object -Last $Lines) -join "`r`n"
}

# ================================================================== multiplayer / network

function Get-NetworkInfo {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $lan = $null
    if ($route) {
        $lan = (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254*' } | Select-Object -First 1).IPAddress
    }
    $vpn = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -match '^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.' -or $_.InterfaceAlias -match 'Tailscale|ZeroTier|Radmin|Hamachi'
    } | Select-Object -First 1
    $public = $null
    try { $public = (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 8).ToString().Trim() } catch {}
    [pscustomobject]@{
        LanIp = $lan
        PublicIp = $public
        VpnIp = if ($vpn) { $vpn.IPAddress } else { $null }
        VpnName = if ($vpn) { $vpn.InterfaceAlias } else { $null }
        Gateway = if ($route) { $route.NextHop } else { $null }
    }
}

function Get-RealmAddress([string]$Root) {
    $r = Invoke-ServerSql $Root 'SELECT address, localAddress, localSubnetMask, name FROM realmlist WHERE id=1;'
    ConvertFrom-SqlRows $r 'Address', 'LocalAddress', 'Mask', 'Name' | Select-Object -First 1
}

function Set-RealmAddress([string]$Root, [string]$Address, [string]$LocalAddress, [string]$Mask = '255.255.255.0') {
    foreach ($ip in $Address, $LocalAddress, $Mask) {
        if ($ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$' -and $ip -notmatch '^[A-Za-z0-9.-]+$') { throw "'$ip' is not a valid address." }
    }
    Invoke-ServerSql $Root "UPDATE realmlist SET address=$(ConvertTo-SqlString $Address), localAddress=$(ConvertTo-SqlString $LocalAddress), localSubnetMask=$(ConvertTo-SqlString $Mask) WHERE id=1;" | Out-Null
}

$FirewallGroup = 'AzerothCore Server'
function Get-FirewallRulesEnabled {
    [bool](Get-NetFirewallRule -Group $FirewallGroup -ErrorAction SilentlyContinue | Where-Object Enabled -eq 'True')
}

function Set-FirewallRules([string]$Root, [bool]$Enabled, [switch]$AllowPublicNetworks) {
    Get-NetFirewallRule -Group $FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (-not $Enabled) { return }
    $profile = if ($AllowPublicNetworks) { 'Private,Public,Domain' } else { 'Private,Domain' }
    New-NetFirewallRule -DisplayName 'AzerothCore login server (TCP 3724)' -Group $FirewallGroup -Direction Inbound -Protocol TCP -LocalPort 3724 -Action Allow -Profile $profile | Out-Null
    New-NetFirewallRule -DisplayName 'AzerothCore world server (TCP 8085)' -Group $FirewallGroup -Direction Inbound -Protocol TCP -LocalPort 8085 -Action Allow -Profile $profile | Out-Null
}

function Get-NetworkProfileName {
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    if (-not $route) { return $null }
    (Get-NetConnectionProfile -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue).NetworkCategory
}

# ================================================================== AI chatter (Ollama)

function Get-OllamaModels {
    $o = Find-Ollama
    if (-not $o) { return @() }
    $ErrorActionPreference = 'Continue'
    & $o list 2>$null | Select-Object -Skip 1 | ForEach-Object {
        $p = $_ -split '\s{2,}'
        if ($p[0]) { [pscustomobject]@{ Name = $p[0].Trim(); Size = $p[2] } }
    }
}

function Test-LlmModel([string]$Model) {
    $body = @{
        model = $Model; temperature = 0.8; max_tokens = 120; reasoning_effort = 'none'
        messages = @(
            @{ role = 'system'; content = 'You are Thrall-like orc shaman in World of Warcraft. Stay in character. Reply with one short line only.' },
            @{ role = 'user'; content = '/no_think A gnome just challenged you to a duel in Orgrimmar. What do you say?' })
    } | ConvertTo-Json -Depth 5
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod 'http://localhost:11434/v1/chat/completions' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 180
    [pscustomobject]@{ Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Reply = $r.choices[0].message.content.Trim() }
}

# ================================================================== health checks

function Get-ServerHealth([string]$Root, $Status) {
    <# Plain-language list of things that need attention. Each item: Level (ok|warn|bad), Text. #>
    $s = Get-ServerSettings $Root
    $out = New-Object System.Collections.ArrayList
    $add = { param($lvl, $txt) [void]$out.Add([pscustomobject]@{ Level = $lvl; Text = $txt }) }

    $free = Get-FreeSpaceGB $Root
    if ($free -lt 5) { & $add 'bad' "Only $free GB free on the server's drive. Free up space soon or the database can stop." }
    elseif ($free -lt 15) { & $add 'warn' "$free GB free on the server's drive. Consider freeing some space." }

    if ($Status.MySql -ne 'Running' -and -not ($s.MySqlStopWithServer -and -not $Status.World)) { & $add 'bad' "The database ($($s.MySqlService)) is not running. Starting the server starts it." }

    if ($Status.World -and -not $Status.Starting) {
        if ($Status.TickMean -ge 150) { & $add 'bad' "The server is struggling (average tick $($Status.TickMean) ms). Lower the number of bots in World settings." }
        elseif ($Status.TickMean -ge 80) { & $add 'warn' "The server is busy (average tick $($Status.TickMean) ms). If it feels laggy, lower the number of bots." }
        if ($s.Llm.Enabled -and -not $Status.Bridge) { & $add 'warn' 'AI chatter is enabled but its bridge is not running, so bots are silent. Restart the server.' }
    }

    if ($s.Llm.Enabled -and $Status.Ollama) {
        $o = Find-Ollama
        if ($o) {
            $ErrorActionPreference = 'Continue'
            $ps = & $o ps 2>$null | Select-Object -Skip 1
            foreach ($line in $ps) {
                if ($line -match '(\d+)%/(\d+)% CPU/GPU' -or ($line -match '(\d+)% CPU' -and $line -notmatch 'GPU')) {
                    & $add 'warn' 'The AI model does not fit on the graphics card and partly runs on the CPU, so bot chat is slow. Close other programs that use the graphics card (games, other AI apps) or pick a smaller model.'
                    break
                }
            }
        }
    }

    $last = Get-ChildItem (Join-Path $Root 'backups') -Filter *.zip -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $last) { & $add 'warn' 'No backups yet. Turn on daily backups on the Backups page.' }
    elseif ($last.LastWriteTime -lt (Get-Date).AddDays(-7)) { & $add 'warn' "Last backup is from $($last.LastWriteTime.ToString('yyyy-MM-dd')). Consider backing up (or turn on daily backups)." }

    if ($out.Count -eq 0) { & $add 'ok' 'Everything looks good.' }
    $out
}

# ================================================================== game client: addons & realmlist

function Get-ClientAddonsDir([string]$WowExe) { Join-Path (Split-Path $WowExe -Parent) 'Interface\AddOns' }

function Get-ClientAddonState([string]$WowExe, $Catalog) {
    $dir = Get-ClientAddonsDir $WowExe
    foreach ($a in $Catalog) {
        $path = Join-Path $dir $a.folder
        [pscustomobject]@{ Name = $a.name; Title = $a.title; Installed = Test-Path (Join-Path $path "$($a.folder).toc") }
    }
}

function Install-ClientAddon([string]$WowExe, $Addon) {
    $dir = Get-ClientAddonsDir $WowExe
    New-Item -ItemType Directory -Force $dir | Out-Null
    $tmp = Join-Path $env:TEMP "acc-addon-$($Addon.name)"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    $zip = "$tmp.zip"
    Get-RemoteFile -Url "https://github.com/$($Addon.repo)/archive/refs/heads/$($Addon.branch).zip" -Destination $zip -Label $Addon.title | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    $toc = Get-ChildItem $tmp -Recurse -Filter "$($Addon.folder).toc" | Select-Object -First 1
    if (-not $toc) { throw "The download for $($Addon.title) did not contain $($Addon.folder).toc." }
    $dest = Join-Path $dir $Addon.folder
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item $toc.Directory.FullName $dest -Recurse
    Remove-Item $tmp, $zip -Recurse -Force -ErrorAction SilentlyContinue
    "$($Addon.title) installed."
}

function Uninstall-ClientAddon([string]$WowExe, $Addon) {
    $dest = Join-Path (Get-ClientAddonsDir $WowExe) $Addon.folder
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
}

function Set-ClientRealmlist([string]$WowExe, [string]$Address = '127.0.0.1') {
    # Point the game at this server (used by "Launch WoW" in case the client was used elsewhere).
    $game = Split-Path $WowExe -Parent
    foreach ($rl in Get-ChildItem (Join-Path $game 'Data') -Recurse -Depth 1 -Filter realmlist.wtf -ErrorAction SilentlyContinue) {
        $current = (Get-Content $rl.FullName -Raw).Trim()
        if ($current -ne "set realmlist $Address") { "set realmlist $Address" | Set-Content $rl.FullName -Encoding ascii }
    }
    $cfg = Join-Path $game 'WTF\Config.wtf'
    if (Test-Path $cfg) {
        $lines = @(Get-Content $cfg)
        $want = "SET realmlist `"$Address`""
        if ($lines -notcontains $want) { ($lines | Where-Object { $_ -notmatch '^SET realmlist ' }) + $want | Set-Content $cfg -Encoding ascii }
    }
}

# ================================================================== scheduled restart

function Get-RestartTaskName([string]$Root) { "AzerothCore daily restart ($((Get-ServerSettings $Root).RealmName -replace '[\\/:*?""<>|]', ''))" }

function Set-DailyRestart([string]$Root, [bool]$Enabled, [string]$Time = '06:00', [int]$WarnMinutes = 5) {
    $name = Get-RestartTaskName $Root
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $Enabled) { return }
    $script = Join-Path $Root 'tools\ServerControl.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Action Restart -WarnMinutes $WarnMinutes -OnlyIfRunning"
    $trigger = New-ScheduledTaskTrigger -Daily -At $Time
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Description "Restarts the WoW server in $Root every day (players get a warning first)" | Out-Null
}

function Get-DailyRestart([string]$Root) {
    $t = Get-ScheduledTask -TaskName (Get-RestartTaskName $Root) -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    ([datetime]$t.Triggers[0].StartBoundary).ToString('HH:mm')
}

# ================================================================== item search (Mail item)

function Find-GameItems([string]$Root, [string]$Text, [int]$Limit = 200) {
    # Searches the world database's item list by name (or by ID when a number is typed).
    $t = $Text.Trim()
    if (-not $t) { return @() }
    $where = if ($t -match '^\d+$') { "entry = $t" } else { "name LIKE $(ConvertTo-SqlString ('%' + ($t -replace '[%_\\]', '') + '%'))" }
    $rows = Invoke-ServerSql $Root "SELECT entry, name, Quality, ItemLevel, RequiredLevel FROM item_template WHERE $where ORDER BY Quality DESC, ItemLevel DESC LIMIT $Limit;" -Database 'acore_world'
    $q = @('Poor', 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Artifact', 'Heirloom')
    ConvertFrom-SqlRows $rows 'Id', 'Name', 'Quality', 'ItemLevel', 'ReqLevel' | ForEach-Object {
        $_ | Add-Member -NotePropertyName QualityName -NotePropertyValue $q[[int]$_.Quality] -PassThru
    }
}

# ================================================================== copy a character to another server

function Wait-ServerReady([string]$Root, [int]$TimeoutMin = 20) {
    # True once the world server answers admin commands (bots keep logging in in the background).
    $end = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $end) {
        if ((Get-ServerProcessInfo $Root 'worldserver') -and (Test-PortListening 8085)) {
            try { if ((Invoke-ServerSoap $Root 'server info') -match 'AzerothCore|Connected|Uptime') { return $true } } catch {}
        }
        Start-Sleep -Seconds 5
    }
    $false
}

function Copy-CharacterToServer {
    <# Copies one character (with its items, quests, spells...) from one server to another using AzerothCore's own
       character dump (.pdump). Only one server can run at a time, so this briefly starts each server in turn and
       puts things back the way they were afterwards. #>
    param([string]$FromRoot, [string]$Character, [string]$ToRoot, [string]$ToAccount, [string]$NewName)
    # The server only accepts a plain file name here (relative to its own folder), not a full path.
    $name = "pdump-$Character-$(Get-Date -Format 'yyyyMMddHHmmss').sql"
    $file = Join-Path $FromRoot "server\$name"
    $target = Join-Path $ToRoot "server\$name"
    $running = Get-RunningServerRoot
    $step = {
        param([string]$r, [string]$what)
        if ((Get-RunningServerRoot) -and (Get-RunningServerRoot) -ne $r) {
            $other = Get-RunningServerRoot
            Set-Detail "Stopping $((Get-ServerSettings $other).RealmName)..."; Stop-GameServer $other | Out-Null
        }
        if (-not (Get-ServerProcessInfo $r 'worldserver')) { Set-Detail "Starting $((Get-ServerSettings $r).RealmName) ($what)..."; Start-GameServer $r }
        if (-not (Wait-ServerReady $r)) { throw "$((Get-ServerSettings $r).RealmName) did not start in time." }
    }
    & $step $FromRoot 'to save the character'
    Set-Detail "Saving $Character..."
    Invoke-ServerSoap $FromRoot 'saveall' | Out-Null
    $w = Invoke-ServerSoap $FromRoot "pdump write $name $Character"
    if (-not (Test-Path $file)) { throw "The character could not be saved: $(if ($w) { $w } else { 'no answer from the server' })" }
    Write-ToolLog "Saved $Character ($([math]::Round((Get-Item $file).Length / 1KB)) KB)." 'OK'
    Move-Item $file $target -Force
    & $step $ToRoot 'to load the character'
    Set-Detail "Loading $Character into $((Get-ServerSettings $ToRoot).RealmName)..."
    $cmd = "pdump load $name $ToAccount" + $(if ($NewName) { " $NewName" } else { '' })
    $l = Invoke-ServerSoap $ToRoot $cmd
    Write-ToolLog "Server said: $l"
    Remove-Item $target -ErrorAction SilentlyContinue
    if ($l -notmatch '(?i)success') { throw "Loading the character failed: $(if ($l) { $l } else { 'no answer from the server' })" }
    # The server answers "success" before it writes to the database; make sure the character really arrived.
    $final = if ($NewName) { $NewName } else { $Character }
    $arrived = $false
    for ($i = 0; $i -lt 10 -and -not $arrived; $i++) {
        Start-Sleep -Seconds 2
        $arrived = [bool](Invoke-ServerSql $ToRoot "SELECT guid FROM acore_characters.characters WHERE name=$(ConvertTo-SqlString $final);")
    }
    if (-not $arrived) {
        $why = (Get-Content (Join-Path $ToRoot 'server\logs\Errors.log') -Tail 3 -ErrorAction SilentlyContinue) -join ' '
        throw "The other server accepted the character but could not save it. $(if ($why) { "Its error log says: $why" })"
    }
    # Put back the way it was: the server that ran before runs again (or nothing).
    if ($running -ne $ToRoot) {
        Set-Detail 'Putting things back the way they were...'
        Stop-GameServer $ToRoot | Out-Null
        if ($running) { Start-GameServer $running }
    }
    "Copied $Character to $((Get-ServerSettings $ToRoot).RealmName)" + $(if ($NewName) { " as $NewName" } else { '' }) + " (account $ToAccount)."
}

# ================================================================== performance

function Get-PerformanceSnapshot([string]$Root) {
    $cores = [Environment]::ProcessorCount
    $cpuMs = { param($p) try { $t = $p.TotalProcessorTime; if ($t) { $t.TotalMilliseconds } else { $null } } catch { $null } }
    $a = @{}; foreach ($p in Get-Process) { $v = & $cpuMs $p; if ($null -ne $v) { $a[$p.Id] = $v } }
    $t0 = Get-Date; Start-Sleep -Milliseconds 700
    $procs = @(Get-Process); $ms = [math]::Max(1, ((Get-Date) - $t0).TotalMilliseconds)
    $cpuOf = @{}; $total = 0.0
    foreach ($p in $procs) {
        $v = & $cpuMs $p
        $pct = if ($null -ne $v -and $a.ContainsKey($p.Id)) { [math]::Max(0, [math]::Min(100, 100 * ($v - $a[$p.Id]) / $ms / $cores)) } else { 0 }
        $cpuOf[$p.Id] = $pct; $total += $pct
    }
    $os = Get-CimInstance Win32_OperatingSystem -Property TotalVisibleMemorySize, FreePhysicalMemory
    $gpu = $null
    $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
    if ($smi) {
        $ErrorActionPreference = 'Continue'
        $g = & $smi.Source '--query-gpu=name,utilization.gpu,memory.used,memory.total' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
        if ($g) { $f = $g -split ',\s*'; $gpu = [pscustomobject]@{ Name = $f[0]; Util = [int]$f[1]; UsedGB = [math]::Round([int]$f[2] / 1024, 1); TotalGB = [math]::Round([int]$f[3] / 1024, 1) } }
        $ErrorActionPreference = 'Stop'
    }
    $s = Get-ServerSettings $Root
    $srvDir = Join-Path $Root 'server'
    $mine = @(); $mineIds = @{}
    # Only look at the paths of the few process names that can belong to this server (reading paths is slow).
    foreach ($p in $procs | Where-Object { $_.Name -in 'worldserver', 'authserver', 'python', 'mysqld' -or $_.Name -match '^ollama' }) {
        $path = try { $p.Path } catch { $null }
        $label = $null
        if ($path -and $path.StartsWith($srvDir, [StringComparison]::OrdinalIgnoreCase)) { $label = @{ worldserver = 'World server'; authserver = 'Login server'; python = 'AI chatter bridge' }[$p.Name] }
        elseif ($path -and $p.Name -eq 'mysqld' -and $path.StartsWith($s.MySqlDir, [StringComparison]::OrdinalIgnoreCase)) { $label = 'Database (MySQL)' }
        elseif ($p.Name -match '^ollama' -and $s.Llm.Enabled) { $label = 'AI model (Ollama)' }
        if ($label) { $mine += [pscustomobject]@{ Label = $label; RamGB = [math]::Round($p.WorkingSet64 / 1GB, 2); Cpu = [math]::Round($cpuOf[$p.Id], 1) }; $mineIds[$p.Id] = $true }
    }
    # One row per part (MySQL can run as more than one process).
    $mine = @($mine | Group-Object Label | ForEach-Object { [pscustomobject]@{ Label = $_.Name; RamGB = [math]::Round(($_.Group | Measure-Object RamGB -Sum).Sum, 2); Cpu = [math]::Round(($_.Group | Measure-Object Cpu -Sum).Sum, 1) } })
    $others = @($procs | Where-Object { -not $mineIds.ContainsKey($_.Id) -and $_.Name -notin 'Idle', 'System', 'Memory Compression', 'Registry', 'vmmem' } | Group-Object Name | ForEach-Object {
        [pscustomobject]@{ Label = $_.Name; RamGB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1GB, 2); Cpu = [math]::Round(($_.Group | ForEach-Object { $cpuOf[$_.Id] } | Measure-Object -Sum).Sum, 1); Count = $_.Count }
    } | Sort-Object RamGB -Descending | Select-Object -First 6)
    $st = $null; try { $st = Get-ServerStatus $Root } catch {}
    [pscustomobject]@{
        CpuPct = [int][math]::Min(100, $total); Cores = $cores
        RamTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1); RamFreeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1); Gpu = $gpu
        DiskFreeGB = Get-FreeSpaceGB $Root; Server = $mine; Others = $others; Status = $st; Bots = [int]$s.Bots
    }
}

function Get-BotAdvice($Snap) {
    # Suggests a bot count from free memory, the processor, and how smoothly the world runs right now.
    $worldRam = ($Snap.Server | Where-Object Label -eq 'World server' | Measure-Object RamGB -Sum).Sum
    $st = $Snap.Status
    $measured = $st -and $st.World -and -not $st.Starting -and $st.BotsOnline -gt 50 -and $worldRam
    $perBot = if ($measured) { [math]::Max(0.004, ($worldRam - 1.5) / $st.BotsOnline) } else { 0.008 }
    $budgetGB = [math]::Max(0, $Snap.RamFreeGB + $worldRam - 4)   # keep ~4 GB free for Windows and the game itself
    $byRam = $budgetGB / $perBot
    $byCpu = $Snap.Cores * 50                                       # rule of thumb; real measurements below win
    $tick = if ($measured) { $st.TickMean } else { $null }
    if ($measured) {
        if ($tick -lt 40) { $byCpu = [math]::Max($byCpu, $Snap.Bots * 1.25) }
        elseif ($tick -ge 150) { $byCpu = [math]::Min($byCpu, $Snap.Bots * 0.6) }
        elseif ($tick -ge 80) { $byCpu = [math]::Min($byCpu, $Snap.Bots * 0.8) }
        else { $byCpu = [math]::Max($byCpu, $Snap.Bots) }
    }
    $suggest = [int]([math]::Floor([math]::Min($byRam, $byCpu) / 50) * 50)
    [pscustomobject]@{ Suggest = [math]::Min(2000, [math]::Max(50, $suggest)); PerBotMB = [math]::Round($perBot * 1024, 1); Tick = $tick; Measured = [bool]$measured }
}

# ================================================================== timed events (double XP weekend, ...)
# Stored in server-settings.json as Events: Name, Kind (xp|loot|gold|honor|rep|skill), Multiplier, StartDay/EndDay
# (-1 = every day, 0-6 = Sunday-Saturday), StartTime/EndTime (HH:mm), Enabled. apply-config.ps1 applies the
# multipliers of active events; a scheduled task (Headless.ps1 -Action Events) switches them on time.

$EventKinds = [ordered]@{ xp = 'Experience'; loot = 'Item drops'; gold = 'Gold drops'; honor = 'Honor'; rep = 'Reputation'; skill = 'Profession skill-ups' }

function Test-EventActive($e, [datetime]$now) {
    # Same rule as in apply-config.ps1 (which must work on its own).
    $toMin = { param($t) $p = "$t" -split ':'; [int]$p[0] * 60 + [int]$p[1] }
    $s = & $toMin $e.StartTime; $f = & $toMin $e.EndTime
    if ([int]$e.StartDay -lt 0) { $n = $now.Hour * 60 + $now.Minute }
    else { $n = [int]$now.DayOfWeek * 1440 + $now.Hour * 60 + $now.Minute; $s += [int]$e.StartDay * 1440; $f += [int]$e.EndDay * 1440 }
    if ($s -le $f) { $s -le $n -and $n -lt $f } else { $n -ge $s -or $n -lt $f }
}

function Get-ActiveEventNames($Settings, [datetime]$Now = (Get-Date)) {
    @(foreach ($e in @($Settings.Events)) { if ($e -and $e.Enabled -and $EventKinds.Contains("$($e.Kind)") -and (Test-EventActive $e $Now)) { $e.Name } })
}

function Get-EventTaskName([string]$Root) { "AzerothCore events ($((Get-ServerSettings $Root).RealmName -replace '[\\/:*?""<>|]', ''))" }

function Set-EventSchedule([string]$Root, [string]$ToolDirectory, [bool]$Enabled) {
    $name = Get-EventTaskName $Root
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $Enabled) { return }
    $script = Join-Path $ToolDirectory 'src\Headless.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Root `"$Root`" -Action Events"
    $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddHours((Get-Date).Hour + 1)) -RepetitionInterval (New-TimeSpan -Minutes 15)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Starts and ends the timed events of $Root" | Out-Null
}

function Get-EventSchedule([string]$Root) { [bool](Get-ScheduledTask -TaskName (Get-EventTaskName $Root) -ErrorAction SilentlyContinue) }

# ================================================================== share kit for friends

function New-FriendKit([string]$Root, [string]$Address, [string]$User, [string]$Pass, [string]$OutDir) {
    $s = Get-ServerSettings $Root
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    "set realmlist $Address" | Set-Content (Join-Path $OutDir 'realmlist.wtf') -Encoding ascii
    @"
HOW TO JOIN "$($s.RealmName)"
================================

1. You need the World of Warcraft 3.3.5a game client (version 3.3.5.12340).

2. Copy the file realmlist.wtf from this folder into your game's
   Data\enUS folder (or Data\enGB, Data\deDE ... - whichever exists),
   replacing the one that is there.

3. Also open WTF\Config.wtf in Notepad (if it exists), find the line that starts with
   SET realmlist  and change it to:
       SET realmlist "$Address"

4. Start Wow.exe and log in with:
       Username: $($User.ToUpper())
       Password: $Pass

Have fun!
"@ | Set-Content (Join-Path $OutDir 'HOW TO JOIN.txt') -Encoding ascii
    $OutDir
}

# ================================================================== app version / app updates

function Get-AppInfo {
    $f = Join-Path $global:ToolDir 'config\app.json'
    if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { [pscustomobject]@{ version = '0.0.0'; repository = '' } }
}

function Get-AppUpdateInfo {
    <# Asks GitHub for the newest release of this app. Only reads; installing stays a manual download. #>
    $app = Get-AppInfo
    if (-not $app.repository) { throw 'No repository configured in config\app.json.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $r = Invoke-RestMethod "https://api.github.com/repos/$($app.repository)/releases/latest" -Headers @{ 'User-Agent' = 'AzerothCore-ServerManager' } -TimeoutSec 15
    $latest = "$($r.tag_name)".TrimStart('v', 'V')
    $newer = $false
    try { $newer = [version]$latest -gt [version]$app.version } catch {}
    [pscustomobject]@{
        Current = $app.version; Latest = $latest; Newer = $newer
        Url = $r.html_url; Notes = "$($r.body)"; Published = "$($r.published_at)"
        Download = ($r.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1).browser_download_url
    }
}
