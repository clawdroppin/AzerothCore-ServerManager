# Check & repair: finds the usual ways a server gets out of step (a moved or renamed folder, missing files,
# a database that does not start, a broken admin login, outdated helper scripts...) and fixes what can be fixed safely.
# Each check has a Test (returns $null when fine, or @{ Status; Detail; Fix }) and an optional Fix.
# Fixes run in list order, so earlier ones (folder paths, database) are in place for later ones.
# Requires Common.ps1, Manage.ps1, Steps.ps1 (with Prereqs.ps1) and Update.ps1.

function Get-RepairContext([string]$Root) {
    $s = Get-ServerSettings $Root
    [pscustomobject]@{
        Root = $Root; S = $s
        Srv = Join-Path $Root 'server'
        Src = Join-Path $Root 'azerothcore-wotlk'
        HasSource = Test-Path (Join-Path $Root 'azerothcore-wotlk\.git')
        Running = [bool](Get-ServerProcessInfo $Root 'worldserver')
        AppDb = "$($s.MySqlService)" -like 'AzerothCoreMySQL*'    # a database this app installed for this server
        DbOk = $false
    }
}

function Get-RepairDataDir($c) { if ($c.S.DataDir) { $c.S.DataDir } else { Join-Path $c.Srv 'data' } }

function Test-MapData([string]$Dir) {
    # Names of the map data folders that are missing or empty.
    @(foreach ($d in 'dbc', 'maps', 'vmaps', 'mmaps') {
        $p = Join-Path $Dir $d
        if (-not (Test-Path $p) -or -not (Get-ChildItem $p -File -ErrorAction SilentlyContinue | Select-Object -First 1)) { $d }
    })
}

function Get-RepairSql($c, [string]$Sql) { Invoke-ServerSql $c.Root $Sql -NoAutoStart }

function Get-MySqlErrorTail($c) {
    # Last lines of the database's own error log, to explain why it does not start.
    $ini = Join-Path $c.Root 'database\my.ini'
    $log = $null
    if (Test-Path $ini) { $m = Select-String $ini -Pattern '^\s*log-error\s*=\s*"?([^"]+)"?' | Select-Object -First 1; if ($m) { $log = $m.Matches[0].Groups[1].Value.Replace('/', '\') } }
    if (-not $log -or -not (Test-Path $log)) { $log = Get-ChildItem (Join-Path $c.Root 'database\data') -Filter *.err -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
    if (-not $log -or -not (Test-Path $log)) { return '' }
    ((Get-Content $log -Tail 40 | Where-Object { $_ -match '\[ERROR\]' } | Select-Object -Last 2) -join ' ') -replace '\s+', ' '
}

function Get-CoreDistSource($c, [string]$Name) {
    # Where a missing default config (.conf.dist) can be taken from: the last compile, or the source code.
    $paths = @(
        (Join-Path $c.Src "build\bin\Release\configs\$Name"),
        (Join-Path $c.Src "src\server\apps\$($Name -replace '\.conf\.dist$', '')\$Name"),
        (Join-Path $c.Src "src\tools\$($Name -replace '\.conf\.dist$', '')\$Name"))
    $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Get-ModuleDists($c) {
    # Every module's default config file in the source code, with where the server expects it.
    if (-not (Test-Path (Join-Path $c.Src 'modules'))) { return @() }
    foreach ($m in Get-ChildItem (Join-Path $c.Src 'modules') -Directory) {
        foreach ($f in Get-ChildItem (Join-Path $m.FullName 'conf') -Filter *.conf.dist -File -ErrorAction SilentlyContinue) {
            [pscustomobject]@{ Module = $m.Name; Source = $f.FullName; Target = Join-Path $c.Srv "configs\modules\$($f.Name)" }
        }
    }
}

function Get-ToolsOutOfDate($c) {
    $td = $global:ToolDir
    if (-not $td -or -not (Test-Path (Join-Path $td 'payload\tools'))) { return @() }
    $pairs = @(Get-ChildItem (Join-Path $td 'payload\tools') -File | ForEach-Object { , @($_.FullName, (Join-Path $c.Root "tools\$($_.Name)")) }) +
             @(Get-ChildItem (Join-Path $td 'payload') -Filter *.bat -File | ForEach-Object { , @($_.FullName, (Join-Path $c.Root $_.Name)) })
    @(foreach ($p in $pairs) {
        if (-not (Test-Path $p[1]) -or (Get-FileHash $p[1] -Algorithm MD5).Hash -ne (Get-FileHash $p[0] -Algorithm MD5).Hash) { Split-Path $p[1] -Leaf }
    })
}

function Get-ServerTaskList($c) {
    # This server's scheduled tasks, with a way to register each again.
    $list = @(
        @{ Kind = 'daily backup'; Name = Get-BackupScheduleTaskName $c.Root; Redo = { param($r) Set-BackupSchedule $r $true (Get-BackupSchedule $r) } },
        @{ Kind = 'daily restart'; Name = Get-RestartTaskName $c.Root; Redo = {
            param($r)
            $t = Get-ScheduledTask -TaskName (Get-RestartTaskName $r)
            $w = if ($t.Actions[0].Arguments -match '-WarnMinutes (\d+)') { [int]$Matches[1] } else { 5 }
            Set-DailyRestart $r $true (Get-DailyRestart $r) $w } },
        @{ Kind = 'start with Windows'; Name = Get-AutostartTaskName $c.Root; Redo = { param($r) Set-ServerAutostart $r $true } },
        @{ Kind = 'timed events'; Name = Get-EventTaskName $c.Root; Redo = { param($r) Set-EventSchedule $r $global:ToolDir $true } },
        @{ Kind = 'automatic updates'; Name = Get-AutoUpdateTaskName $c.Root; Redo = { param($r) $a = Get-AutoUpdate $r; Set-AutoUpdate $r $global:ToolDir $true $a.Day $a.Time } }
    )
    foreach ($t in $list) {
        $task = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        if (-not $task) { continue }
        $a = $task.Actions[0]
        $paths = @()
        if ($a.Execute -match '\\') { $paths += $a.Execute.Trim('"') }
        foreach ($m in [regex]::Matches("$($a.Arguments)", '"([A-Za-z]:\\[^"]+)"')) { $paths += $m.Groups[1].Value }
        $missing = @($paths | Where-Object { -not (Test-Path $_) })
        [pscustomobject]@{ Kind = $t.Kind; Name = $t.Name; Missing = $missing; Redo = $t.Redo }
    }
}

function Get-BrokenShortcuts($c) {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($lnk in Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -Filter *.lnk -ErrorAction SilentlyContinue) {
        $sc = $shell.CreateShortcut($lnk.FullName)
        $leaf = Split-Path $sc.TargetPath -Leaf
        if ($leaf -notin 'START_SERVER.bat', 'STOP_SERVER.bat' -or (Test-Path $sc.TargetPath)) { continue }
        # Only shortcuts that belong to this server: named after it, or pointing into a folder with its name.
        $label = ($c.S.RealmName -replace '[\\/:*?"<>|]', '').Trim()
        if ($lnk.BaseName -like "* $label" -or $sc.TargetPath -like "*\$(Split-Path $c.Root -Leaf)\*") {
            [pscustomobject]@{ File = $lnk.FullName; Target = Join-Path $c.Root $leaf }
        }
    }
}

function Get-OrphanProcesses($c) {
    # Parts of this server still running after the world server stopped (they hold files and ports).
    if ($c.Running) { return @() }
    $out = @()
    $auth = Get-ServerProcessInfo $c.Root 'authserver'
    if ($auth) { $out += [pscustomobject]@{ Id = $auth.Id; What = 'login server (authserver)' } }
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*llm_chatter_bridge.py*' -and $_.CommandLine -like "*$($c.Srv)*" } |
        ForEach-Object { $out += [pscustomobject]@{ Id = $_.ProcessId; What = 'AI chatter bridge' } }
    $out
}

function Set-RepairStepGlobals($c) {
    # The install steps read these globals.
    $Global:S = $c.S; $Global:Root = $c.Root
    if (-not $Global:V) { $Global:V = Get-Content (Join-Path $global:ToolDir 'config\versions.json') -Raw | ConvertFrom-Json }
}

function Invoke-RepairStep($c, [string]$Id) {
    Set-RepairStepGlobals $c
    & ($InstallSteps | Where-Object Id -eq $Id).Run
}

$RepairChecks = @(

# ------------------------------------------------------------------ folders & files
@{ Id = 'rootdir'; Area = 'Folders'; Name = 'Server folder location'
   Test = {
       param($c)
       if ($c.S.RootDir -and $c.S.RootDir.TrimEnd('\') -ne $c.Root.TrimEnd('\')) {
           @{ Status = 'Problem'; Detail = "The settings still point to $($c.S.RootDir) - the folder was moved or renamed."; Fix = 'Point the settings to the folder the server is in now' }
       } else { @{ Status = 'OK'; Detail = $c.Root } }
   }
   Fix = {
       param($c)
       $old = $c.S.RootDir.TrimEnd('\')
       foreach ($p in 'DataDir', 'MySqlDir') {
           $v = "$($c.S.$p)"
           if ($v -and $v.StartsWith($old, [StringComparison]::OrdinalIgnoreCase)) {
               $new = $c.Root.TrimEnd('\') + $v.Substring($old.Length)
               if (Test-Path $new) { $c.S.$p = $new }
           }
       }
       $c.S.RootDir = $c.Root
       Save-ServerSettings $c.Root $c.S
       if (Test-Path (Join-Path $c.Srv 'configs\worldserver.conf.dist')) { Invoke-ApplyServerConfig $c.Root | Out-Null }
   }
},

@{ Id = 'folders'; Area = 'Folders'; Name = 'Working folders'
   Test = {
       param($c)
       $miss = @('server\logs', 'server\configs\modules', 'tools', 'secrets', 'backups', '.creationtool' | Where-Object { -not (Test-Path (Join-Path $c.Root $_)) })
       if ($miss) { @{ Status = 'Problem'; Detail = "Missing: $($miss -join ', ')"; Fix = 'Create the missing folders' } }
   }
   Fix = { param($c) foreach ($d in 'server\logs', 'server\configs\modules', 'tools', 'secrets', 'backups', '.creationtool') { New-Item -ItemType Directory -Force (Join-Path $c.Root $d) | Out-Null } }
},

@{ Id = 'programs'; Area = 'Folders'; Name = 'Server programs'; NeedsStop = $true
   Test = {
       param($c)
       $miss = @('worldserver.exe', 'authserver.exe' | Where-Object { -not (Test-Path (Join-Path $c.Srv $_)) })
       if (-not $miss) { return @{ Status = 'OK'; Detail = 'worldserver.exe and authserver.exe are there' } }
       $from = @((Join-Path $c.Src 'build\bin\Release')) + @(Get-SafetyCopies $c.Root | ForEach-Object { Join-Path $_.Path 'server' })
       $have = $from | Where-Object { $d = $_; -not @($miss | Where-Object { -not (Test-Path (Join-Path $d $_)) }) } | Select-Object -First 1
       if ($have) { @{ Status = 'Problem'; Detail = "Missing: $($miss -join ', ')"; Fix = "Put them back from $have" } }
       else { @{ Status = 'Problem'; Detail = "Missing: $($miss -join ', '). No copy found - $(if ($c.HasSource) { 'use Updates > Recompile' } else { 'import the server package again' })." } }
   }
   Fix = {
       param($c)
       $from = @((Join-Path $c.Src 'build\bin\Release')) + @(Get-SafetyCopies $c.Root | ForEach-Object { Join-Path $_.Path 'server' })
       foreach ($exe in 'worldserver.exe', 'authserver.exe', 'dbimport.exe') {
           if (Test-Path (Join-Path $c.Srv $exe)) { continue }
           $src = $from | Where-Object { Test-Path (Join-Path $_ $exe) } | Select-Object -First 1
           if ($src) { Copy-Item (Join-Path $src $exe) $c.Srv -Force }
       }
   }
},

@{ Id = 'dlls'; Area = 'Folders'; Name = 'Program libraries (OpenSSL, MySQL)'; NeedsStop = $true
   Test = {
       param($c)
       $miss = @('libssl-3-x64.dll', 'libcrypto-3-x64.dll', 'legacy.dll', 'libmysql.dll' | Where-Object { -not (Test-Path (Join-Path $c.Srv $_)) })
       if ($miss) { @{ Status = 'Problem'; Detail = "Missing next to the programs: $($miss -join ', ') - the server cannot start without them."; Fix = 'Copy them from OpenSSL / MySQL (or another server)' } }
   }
   Fix = {
       param($c)
       foreach ($dll in 'libssl-3-x64.dll', 'libcrypto-3-x64.dll', 'legacy.dll', 'libmysql.dll') {
           if (Test-Path (Join-Path $c.Srv $dll)) { continue }
           $f = if ($dll -eq 'libmysql.dll') { Join-Path $c.S.MySqlDir 'lib\libmysql.dll' }
                else { Get-ChildItem "$env:ProgramFiles\OpenSSL-Win64" -Recurse -Filter $dll -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
           if (-not $f -or -not (Test-Path $f)) {
               $f = Get-ServerRegistry | ForEach-Object { Join-Path $_.RootDir "server\$dll" } | Where-Object { Test-Path $_ } | Select-Object -First 1
           }
           if (-not $f) { throw "No copy of $dll found. Install OpenSSL 3 / MySQL on the Prerequisites page." }
           Copy-Item $f $c.Srv -Force
       }
   }
},

@{ Id = 'vcredist'; Area = 'Folders'; Name = 'Microsoft Visual C++ runtime'
   Test = {
       param($c)
       if (-not (& (Get-PrereqItem 'vcredist').Detect).Installed) { @{ Status = 'Problem'; Detail = 'Not installed - the server programs need it to start.'; Fix = 'Install it (small download)' } }
   }
   Fix = { param($c) Install-Prereq 'vcredist' }
},

@{ Id = 'dists'; Area = 'Settings'; Name = 'Default config files (.conf.dist)'
   Test = {
       param($c)
       $miss = @('worldserver.conf.dist', 'authserver.conf.dist' | Where-Object { -not (Test-Path (Join-Path $c.Srv "configs\$_")) })
       $mods = @(Get-ModuleDists $c | Where-Object { -not (Test-Path $_.Target) })
       if (-not $miss -and -not $mods) { return $null }
       $names = @($miss) + @($mods | ForEach-Object { Split-Path $_.Target -Leaf })
       $fixable = @($miss | Where-Object { Get-CoreDistSource $c $_ }).Count -eq $miss.Count
       @{ Status = 'Problem'; Detail = "Missing: $($names -join ', ') - without them those settings cannot be written."; Fix = $(if ($fixable) { 'Copy them from the source code' } else { $null }) }
   }
   Fix = {
       param($c)
       foreach ($n in 'worldserver.conf.dist', 'authserver.conf.dist', 'dbimport.conf.dist') {
           $dst = Join-Path $c.Srv "configs\$n"
           if (-not (Test-Path $dst)) { $f = Get-CoreDistSource $c $n; if ($f) { Copy-Item $f $dst -Force } }
       }
       foreach ($m in Get-ModuleDists $c | Where-Object { -not (Test-Path $_.Target) }) { Copy-Item $m.Source $m.Target -Force }
       # Write the config files that belong to the defaults just put back.
       Invoke-ApplyServerConfig $c.Root | Out-Null
   }
},

@{ Id = 'tools'; Area = 'Settings'; Name = 'Helper scripts (tools folder, START/STOP files)'
   Test = {
       param($c)
       $old = @(Get-ToolsOutOfDate $c)
       if ($old) { @{ Status = 'Problem'; Detail = "Missing or outdated: $($old -join ', ')"; Fix = "Refresh them from this app" } }
   }
   Fix = { param($c) Sync-ServerTools $c.Root }
},

@{ Id = 'data'; Area = 'Folders'; Name = 'World map data'
   Test = {
       param($c)
       $dir = Get-RepairDataDir $c
       $miss = @(Test-MapData $dir)
       if (-not $miss) { return @{ Status = 'OK'; Detail = $dir } }
       $shared = Get-SharedDataDir
       if ($shared -ne $dir -and -not @(Test-MapData $shared)) { return @{ Status = 'Problem'; Detail = "Missing or empty in ${dir}: $($miss -join ', ')"; Fix = "Use the shared map data in $shared" } }
       @{ Status = 'Problem'; Detail = "Missing or empty in ${dir}: $($miss -join ', ')"; Fix = 'Download the map data again (about 1.2 GB)' }
   }
   Fix = {
       param($c)
       $shared = Get-SharedDataDir
       if ((Get-RepairDataDir $c) -ne $shared -and -not @(Test-MapData $shared)) { $c.S.DataDir = $shared; Save-ServerSettings $c.Root $c.S; Invoke-ApplyServerConfig $c.Root | Out-Null }
       else {
           $marker = Join-Path (Get-RepairDataDir $c) 'data-version'
           Remove-Item $marker -Force -ErrorAction SilentlyContinue      # makes the step download again
           Invoke-RepairStep $c 'clientdata'
       }
   }
},

@{ Id = 'disk'; Area = 'Folders'; Name = 'Free disk space'
   Test = {
       param($c)
       $free = Get-FreeSpaceGB $c.Root
       if ($free -lt 3) { @{ Status = 'Problem'; Detail = "Only $free GB free - the database and logs can fail to save. Free up space (Backups page: delete old backups; Updates page: delete safety copies)." } }
       elseif ($free -lt 10) { @{ Status = 'Warning'; Detail = "$free GB free. Updates need about 8 GB." } }
       else { @{ Status = 'OK'; Detail = "$free GB free" } }
   }
},

# ------------------------------------------------------------------ database
@{ Id = 'dbservice'; Area = 'Database'; Name = 'Database service'; NeedsStop = $true
   Test = {
       param($c)
       $name = $c.S.MySqlService
       $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
       $canRebuild = $c.AppDb -and (Test-Path (Join-Path $c.S.MySqlDir 'bin\mysqld.exe')) -and (Test-Path (Join-Path $c.Root 'database\data\mysql'))
       if (-not $svc) {
           return @{ Status = 'Problem'; Detail = "The Windows service '$name' does not exist."; Fix = $(if ($canRebuild) { 'Register the database service again (your data is kept)' } else { $null }) }
       }
       $exe = if ($svc.PathName -match '^"([^"]+)"') { $Matches[1] } else { ($svc.PathName -split '\s')[0] }
       $ini = if ($svc.PathName -match '--defaults-file="?([^"]+?\.ini)"?(\s|$)') { $Matches[1] } else { $null }
       $bad = @()
       if (-not (Test-Path $exe)) { $bad += "its program ($exe) is missing" }
       if ($ini -and -not (Test-Path $ini)) { $bad += "its settings file ($ini) is missing" }
       if ($c.AppDb -and $ini -and $ini -ne (Join-Path $c.Root 'database\my.ini')) { $bad += "it belongs to another folder ($ini)" }
       if ($bad) { return @{ Status = 'Problem'; Detail = "The service '$name' is broken: $($bad -join '; ')."; Fix = $(if ($canRebuild) { 'Point the service to this folder again (your data is kept)' } else { $null }) } }
       @{ Status = 'OK'; Detail = "$name ($($svc.State))" }
   }
   Fix = {
       param($c)
       $name = $c.S.MySqlService
       if (Get-Service $name -ErrorAction SilentlyContinue) {
           Stop-Service $name -Force -ErrorAction SilentlyContinue
           $exe = Join-Path $c.S.MySqlDir 'bin\mysqld.exe'
           $ini = Join-Path $c.Root 'database\my.ini'
           Invoke-Native "$env:SystemRoot\System32\sc.exe" "config $name binPath= `"\`"$exe\`" --defaults-file=\`"$ini\`" $name`"" -Quiet | Out-Null
       }
       # The install step writes my.ini for this folder, registers the service if needed, starts it and checks the logins.
       Invoke-RepairStep $c 'mysql'
   }
},

@{ Id = 'dbrun'; Area = 'Database'; Name = 'Database running'
   Test = {
       param($c)
       $svc = Get-Service $c.S.MySqlService -ErrorAction SilentlyContinue
       if ((Test-PortListening ([int]$c.S.DbPort)) -and (-not $svc -or $svc.Status -eq 'Running')) { return @{ Status = 'OK'; Detail = "Port $($c.S.DbPort)$(if ($c.S.DbPortMode -eq 'shared') { ' (shared port)' })" } }
       $why = $null
       try { Start-ServerDatabase $c.Root } catch { $why = $_.Exception.Message }
       # Shared database port in use by another server that is running: not a fault, just not checkable now.
       if ($why -match 'is running and is using the shared database port') { return @{ Status = 'Skipped'; Detail = $why } }
       if ($why -match 'used by another program') { return @{ Status = 'Problem'; Detail = $why } }
       if (Test-PortListening ([int]$c.S.DbPort)) { return @{ Status = 'OK'; Detail = "Started it for this check (port $($c.S.DbPort))" } }
       $why = Get-MySqlErrorTail $c
       @{ Status = 'Problem'; Detail = "The database does not start.$(if ($why) { " Its log says: $why" } else { '' })" }
   }
},

@{ Id = 'dblogin'; Area = 'Database'; Name = 'Database login (acore)'
   Test = {
       param($c)
       if (-not (Test-PortListening ([int]$c.S.DbPort))) { return @{ Status = 'Skipped'; Detail = 'The database is not running.' } }
       if (-not (Test-DatabaseIdentity $c.Root $c.S)) { return @{ Status = 'Problem'; Detail = "The database answering on port $($c.S.DbPort) belongs to another server. Start this server so it swaps its own database in, or give one of them its own port." } }
       try { Get-RepairSql $c 'SELECT 1;' | Out-Null; $c.DbOk = $true; return $null }
       catch {
           $root = Join-Path $c.Root 'secrets\mysql-root.txt'
           @{ Status = 'Problem'; Detail = "The server's database login does not work: $($_.Exception.Message)"; Fix = $(if (Test-Path $root) { 'Create the login again (with the saved database admin password)' } else { $null }) }
       }
   }
   Fix = {
       param($c)
       Set-RepairStepGlobals $c
       $pw = ((Get-Content (Join-Path $c.Root 'secrets\mysql-root.txt') -Raw) -split ':\s*')[-1].Trim()
       Invoke-MySql @"
CREATE USER IF NOT EXISTS 'acore'@'localhost' IDENTIFIED BY 'acore';
CREATE USER IF NOT EXISTS 'acore'@'127.0.0.1' IDENTIFIED BY 'acore';
ALTER USER 'acore'@'localhost' IDENTIFIED BY 'acore';
ALTER USER 'acore'@'127.0.0.1' IDENTIFIED BY 'acore';
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'acore'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
"@ -User root -Password $pw | Out-Null
   }
},

@{ Id = 'schemas'; Area = 'Database'; Name = 'Game databases'; NeedsDb = $true; NeedsStop = $true
   Test = {
       param($c)
       $rows = ConvertFrom-SqlRows (Get-RepairSql $c "SELECT table_schema, COUNT(*) FROM information_schema.tables WHERE table_schema IN ('acore_auth','acore_world','acore_characters','acore_playerbots') GROUP BY table_schema;") 'Db', 'Tables'
       $n = @{}; foreach ($r in $rows) { $n[$r.Db] = [int]$r.Tables }
       $bad = @()
       if ($n['acore_auth'] -lt 10) { $bad += 'accounts (acore_auth)' }
       if ($n['acore_characters'] -lt 30) { $bad += 'characters (acore_characters)' }
       $world = $n['acore_world'] -lt 100
       if ($bad) { return @{ Status = 'Problem'; Detail = "Missing or empty: $($bad -join ', '). Restore a backup on the Backups page." } }
       if ($world) { return @{ Status = 'Problem'; Detail = 'The world database (acore_world) is missing or incomplete.'; Fix = $(if ((Test-Path (Join-Path $c.Srv 'dbimport.exe')) -and $c.HasSource) { 'Build the world database again from the source (several minutes)' } else { $null }) } }
       $extra = if ($c.S.Modules -contains 'mod-playerbots' -and -not $n['acore_playerbots']) { ' (the bots database is created at the next start)' } else { '' }
       @{ Status = 'OK'; Detail = "accounts $($n['acore_auth']), world $($n['acore_world']), characters $($n['acore_characters']) tables$extra" }
   }
   Fix = { param($c) Invoke-RepairStep $c 'databases' }
},

@{ Id = 'tables'; Area = 'Database'; Name = 'Account and character tables intact'; NeedsDb = $true
   Test = {
       param($c)
       $r = @(Get-RepairSql $c 'CHECK TABLE acore_auth.account, acore_characters.characters, acore_characters.character_inventory, acore_characters.item_instance QUICK;')
       $bad = @($r | Where-Object { $p = $_ -split "`t"; $p.Count -ge 4 -and ($p[2] -eq 'error' -or ($p[2] -eq 'status' -and $p[3] -ne 'OK')) } | ForEach-Object { ($_ -split "`t")[0] })
       if ($bad) { @{ Status = 'Problem'; Detail = "Damaged: $($bad -join ', '). Restore the newest backup on the Backups page." } }
   }
},

@{ Id = 'realm'; Area = 'Database'; Name = 'Realm list entry'; NeedsDb = $true
   Test = {
       param($c)
       $r = ConvertFrom-SqlRows (Get-RepairSql $c 'SELECT name, address, port, gamebuild, icon FROM acore_auth.realmlist WHERE id=1;') 'Name', 'Address', 'Port', 'Build', 'Icon' | Select-Object -First 1
       if (-not $r) { return @{ Status = 'Problem'; Detail = 'Your realm is missing from the realm list - nobody can choose it.'; Fix = 'Add the realm entry again' } }
       $bad = @()
       if ([int]$r.Port -ne 8085) { $bad += "port is $($r.Port) instead of 8085" }
       if ([int]$r.Build -ne 12340) { $bad += "game version is $($r.Build) instead of 12340 (3.3.5a)" }
       if (-not $r.Address) { $bad += 'the address is empty' }
       if ($r.Name -ne $c.S.RealmName) { $bad += "the name is '$($r.Name)' instead of '$($c.S.RealmName)'" }
       $icon = if ([int]$c.S.GameType -eq 1) { 1 } else { 0 }
       if ([int]$r.Icon -ne $icon) { $bad += "the realm type does not match $(if ($icon) { 'PvP' } else { 'PvE' })" }
       if ($bad) { @{ Status = 'Problem'; Detail = ($bad -join '; '); Fix = 'Correct the realm entry' } }
       else { @{ Status = 'OK'; Detail = "'$($r.Name)' at $($r.Address):8085" } }
   }
   Fix = {
       param($c)
       $name = ConvertTo-SqlString $c.S.RealmName
       $icon = if ([int]$c.S.GameType -eq 1) { 1 } else { 0 }
       Get-RepairSql $c @"
INSERT INTO acore_auth.realmlist (id, name, address, localAddress, localSubnetMask, port, icon, flag, timezone, allowedSecurityLevel, population, gamebuild)
VALUES (1, $name, '127.0.0.1', '127.0.0.1', '255.255.255.0', 8085, $icon, 0, 1, 0, 0, 12340)
ON DUPLICATE KEY UPDATE name=$name, port=8085, gamebuild=12340, icon=$icon, address=IF(address='', '127.0.0.1', address);
"@ | Out-Null
   }
},

@{ Id = 'admin'; Area = 'Database'; Name = 'Admin account (used to stop the server safely)'; NeedsDb = $true
   Test = {
       param($c)
       $f = Join-Path $c.Root 'secrets\soap.txt'
       if (-not (Test-Path $f)) { return @{ Status = 'Problem'; Detail = 'The admin login file (secrets\soap.txt) is missing - the app cannot save and stop the server cleanly.'; Fix = 'Create a new admin account' } }
       $cr = Get-Content $f | ConvertFrom-StringData
       if (-not $cr.User -or -not $cr.Password) { return @{ Status = 'Problem'; Detail = 'secrets\soap.txt is damaged.'; Fix = 'Create a new admin account' } }
       $gm = Get-RepairSql $c "SELECT COALESCE(MAX(aa.gmlevel), -1) FROM acore_auth.account a LEFT JOIN acore_auth.account_access aa ON aa.id = a.id WHERE a.username = $(ConvertTo-SqlString $cr.User.ToUpper());" | Select-Object -Last 1
       if ("$gm" -eq '' -or [int]$gm -lt 3) { return @{ Status = 'Problem'; Detail = "The admin account $($cr.User) $(if ("$gm" -eq '') { 'does not exist' } else { 'has no admin rights' })."; Fix = 'Set up the admin account again' } }
       if ($c.Running -and (Test-PortListening ([int]$c.S.SoapPort))) {
           $answer = try { Invoke-ServerSoap $c.Root 'server info' } catch { $_.Exception.Message }
           if ($answer -notmatch 'uptime|Online|AzerothCore') { return @{ Status = 'Problem'; Detail = "The server does not accept the admin login: $answer"; Fix = 'Set up the admin account again' } }
       }
       @{ Status = 'OK'; Detail = "$($cr.User)" }
   }
   Fix = {
       param($c)
       $f = Join-Path $c.Root 'secrets\soap.txt'
       $cr = if (Test-Path $f) { Get-Content $f | ConvertFrom-StringData } else { @{} }
       if (-not $cr.User -or -not $cr.Password) { "User=SERVERADMIN`r`nPassword=$(New-RandomSecret 16)" | Set-Content $f -Encoding ascii; $cr = Get-Content $f | ConvertFrom-StringData }
       $ErrorActionPreference = 'Continue'
       $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $c.Root 'tools\New-GameAccount.ps1') -Username $cr.User -Password $cr.Password -GmLevel 3 2>&1
       if ($LASTEXITCODE -ne 0) { throw "Could not set up the admin account: $o" }
       if ($c.Running) { Write-ToolLog 'The admin account was changed while the server runs: restart the server so it picks it up.' 'WARN' }
   }
},

@{ Id = 'ahbot'; Area = 'Database'; Name = 'Auction house sellers'; NeedsDb = $true; NeedsStop = $true
   When = { param($c) $c.S.Modules -contains 'mod-ah-bot-plus' }
   Test = {
       param($c)
       $ids = @("$($c.S.AhBotGuids)" -split ',' | Where-Object { $_ -match '^\d+$' })
       $have = if ($ids) { [int](Get-RepairSql $c "SELECT COUNT(*) FROM acore_characters.characters WHERE guid IN ($($ids -join ','));" | Select-Object -Last 1) } else { 0 }
       if ($have -lt [math]::Max(1, $ids.Count)) { @{ Status = 'Problem'; Detail = 'The auction house bot has no seller characters, so the auction house stays empty.'; Fix = 'Create the seller characters again' } }
   }
   Fix = { param($c) Invoke-RepairStep $c 'accounts' }
},

@{ Id = 'taximask'; Area = 'Database'; Name = 'Character records complete'; NeedsDb = $true; NeedsStop = $true
   Test = {
       param($c)
       $n = [int](Get-RepairSql $c "SELECT COUNT(*) FROM acore_characters.characters WHERE taximask = '' OR taximask IS NULL;" | Select-Object -Last 1)
       if ($n) { @{ Status = 'Problem'; Detail = "$n character(s) have an empty flight-path record (they cannot be copied to another server)."; Fix = 'Fill in the empty records' } }
   }
   Fix = { param($c) Get-RepairSql $c "UPDATE acore_characters.characters SET taximask = '0 0 0 0 0 0 0 0 0 0 0 0 0 0 ' WHERE taximask = '' OR taximask IS NULL;" | Out-Null }
},

# ------------------------------------------------------------------ settings (needs the files above)
@{ Id = 'configs'; Area = 'Settings'; Name = 'Server config files'
   Test = {
       param($c)
       $cfg = Join-Path $c.Srv 'configs'
       $bad = @()
       foreach ($n in 'worldserver.conf', 'authserver.conf') {
           $f = Join-Path $cfg $n
           if (-not (Test-Path $f)) { $bad += "$n is missing"; continue }
           if ((Get-Content $f -TotalCount 1) -notlike '# Generated by AzerothCore Control Center*') { $bad += "$n was not written by this app (hand edits are kept as overrides)" }
       }
       $ws = Join-Path $cfg 'worldserver.conf'
       if (Test-Path $ws) {
           $dd = "$(Get-ConfValue $ws 'DataDir')".Replace('/', '\').TrimEnd('\')
           if ($dd -ne (Get-RepairDataDir $c).TrimEnd('\')) { $bad += "worldserver.conf looks for map data in '$dd'" }
           if ("$(Get-ConfValue $ws 'LoginDatabaseInfo')" -notlike "*;$($c.S.DbPort);*") { $bad += 'worldserver.conf uses another database port' }
           $logs = "$(Get-ConfValue $ws 'LogsDir')".Replace('/', '\')
           if ($logs -and -not (Test-Path $logs)) { $bad += "the log folder '$logs' does not exist" }
           if ((Get-ConfValue $ws 'SOAP.Enabled') -ne '1') { $bad += 'admin commands (SOAP) are switched off' }
       }
       foreach ($d in Get-ChildItem (Join-Path $cfg 'modules') -Filter *.conf.dist -ErrorAction SilentlyContinue) {
           if (-not (Test-Path ($d.FullName -replace '\.dist$', ''))) { $bad += "$($d.Name -replace '\.dist$', '') is missing" }
       }
       if ($bad) { @{ Status = 'Problem'; Detail = ($bad -join '; '); Fix = 'Write all config files again from your settings' } }
   }
   Fix = { param($c) Invoke-ApplyServerConfig $c.Root | ForEach-Object { Write-ToolLog "$_" } }
},

# ------------------------------------------------------------------ running programs
@{ Id = 'orphans'; Area = 'Programs'; Name = 'Leftover server processes'
   Test = {
       param($c)
       $o = @(Get-OrphanProcesses $c)
       if ($o) { @{ Status = 'Problem'; Detail = "Still running although the world server is off: $(($o | ForEach-Object What) -join ', ')."; Fix = 'Stop them' } }
   }
   Fix = { param($c) foreach ($p in Get-OrphanProcesses $c) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
},

@{ Id = 'ports'; Area = 'Programs'; Name = 'Game ports free'
   Test = {
       param($c)
       if ($c.Running) { return @{ Status = 'OK'; Detail = 'In use by this server (it is running)' } }
       $busy = @()
       foreach ($port in 3724, 8085, [int]$c.S.SoapPort) {
           $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
           if (-not $conn) { continue }
           $p = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
           if ($p -and $p.Path -and $p.Path.StartsWith($c.Srv, [StringComparison]::OrdinalIgnoreCase)) { continue }   # leftover of this server: see above
           $who = if (-not $p) { "process $($conn.OwningProcess)" } elseif ($p.Name -in 'worldserver', 'authserver' -and $p.Path) { "another WoW server ($(Split-Path (Split-Path $p.Path -Parent) -Parent))" } else { "$($p.Name)" }
           $busy += "$port used by $who"
       }
       if ($busy) { @{ Status = 'Problem'; Detail = "$($busy -join '; '). Stop that program first - this server cannot start while it holds the port." } }
   }
},

# ------------------------------------------------------------------ source code & compiling
@{ Id = 'git'; Area = 'Source code'; Name = 'Source code folder'
   When = { param($c) $c.HasSource }
   Test = {
       param($c)
       $g = Invoke-Git $c.Src @('status', '--porcelain', '--untracked-files=no')
       if (-not $g.Ok) { @{ Status = 'Problem'; Detail = "The source code folder is damaged: $(($g.Out | Select-Object -First 2) -join ' ')" } }
   }
},

@{ Id = 'modsrc'; Area = 'Source code'; Name = 'Module source code'
   When = { param($c) $c.HasSource }
   Test = {
       param($c)
       $dir = Join-Path $c.Src 'modules'
       $known = @($Global:V.modules | ForEach-Object name)
       $miss = @($c.S.Modules | Where-Object { $_ -in $known -and -not (Test-Path (Join-Path $dir $_)) })
       $extra = @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Where-Object { (Test-Path (Join-Path $_.FullName '.git')) -and $c.S.Modules -notcontains $_.Name } | ForEach-Object Name)
       $d = @()
       if ($miss) { $d += "missing (they would be dropped at the next compile): $($miss -join ', ')" }
       if ($extra) { $d += "compiled in but not in the app's list: $($extra -join ', ')" }
       if ($d) { @{ Status = 'Problem'; Detail = ($d -join '; '); Fix = $(if ($miss) { 'Download the missing modules again' } else { "Add them to the app's module list" }) } }
       else { @{ Status = 'OK'; Detail = "$(@($c.S.Modules).Count) modules" } }
   }
   Fix = {
       param($c)
       $dir = Join-Path $c.Src 'modules'
       $known = @($Global:V.modules | ForEach-Object name)
       foreach ($m in @($c.S.Modules | Where-Object { $_ -in $known -and -not (Test-Path (Join-Path $dir $_)) })) {
           $parked = Join-Path $c.Src "modules-disabled\$m"
           if (Test-Path $parked) { Move-Item $parked (Join-Path $dir $m) } else { Enable-ServerModuleSource $c.Root $m }
       }
       $s = Get-ServerSettings $c.Root
       $extra = @(Get-ChildItem $dir -Directory | Where-Object { (Test-Path (Join-Path $_.FullName '.git')) -and $s.Modules -notcontains $_.Name } | ForEach-Object Name)
       if ($extra) { $s.Modules = @(@($s.Modules) + $extra | Select-Object -Unique); Save-ServerSettings $c.Root $s }
   }
},

@{ Id = 'cmake'; Area = 'Source code'; Name = 'Build folder'
   When = { param($c) $c.HasSource }
   Test = {
       param($c)
       if (Test-BuildCacheStale $c.Src) { @{ Status = 'Problem'; Detail = 'The build folder was set up for another location (the server folder was moved), so compiling would fail.'; Fix = 'Reset the build setup (the next compile sets it up again)' } }
       elseif (Test-Path (Join-Path $c.Src 'build.previous')) { @{ Status = 'Warning'; Detail = 'A leftover from an interrupted clean recompile (build.previous) takes up space.'; Fix = 'Delete the leftover' } }
   }
   Fix = {
       param($c)
       if (Test-BuildCacheStale $c.Src) { Clear-BuildCache $c.Src }
       $old = Join-Path $c.Src 'build.previous'
       if (Test-Path $old) {
           if (Test-Path (Join-Path $c.Src 'build\bin\Release\worldserver.exe')) { Remove-Item $old -Recurse -Force }
           elseif (-not (Test-Path (Join-Path $c.Src 'build'))) { Rename-Item $old 'build' }
           else { Remove-Item (Join-Path $c.Src 'build') -Recurse -Force; Rename-Item $old 'build' }
       }
   }
},

@{ Id = 'buildtools'; Area = 'Source code'; Name = 'Build tools (for updates and recompiling)'
   When = { param($c) $c.HasSource }
   Test = {
       param($c)
       $miss = @(foreach ($id in 'git', 'cmake', 'msvc', 'boost', 'openssl') { $p = Get-PrereqItem $id; if (-not (& $p.Detect).Installed) { $p.Name } })
       if ($miss) { @{ Status = 'Warning'; Detail = "Not installed: $($miss -join ', '). The server runs fine, but updates and recompiling need them."; Fix = 'Install them (the C++ compiler is a big download)' } }
   }
   Fix = { param($c) foreach ($id in 'git', 'cmake', 'msvc', 'boost', 'openssl') { Install-Prereq $id; if ($id -eq 'boost') { & (Get-PrereqItem 'boost').After } } }
},

# ------------------------------------------------------------------ app & Windows
@{ Id = 'registry'; Area = 'App & Windows'; Name = "Listed in this app"
   Test = {
       param($c)
       if (-not (Get-ServerRegistry | Where-Object { $_.RootDir.TrimEnd('\') -eq $c.Root.TrimEnd('\') })) { @{ Status = 'Problem'; Detail = 'This server is not in the app''s server list.'; Fix = 'Add it to the list' } }
   }
   Fix = { param($c) Register-Server $c.Root $c.S.RealmName }
},

@{ Id = 'tasks'; Area = 'App & Windows'; Name = 'Scheduled tasks'
   Test = {
       param($c)
       $all = @(Get-ServerTaskList $c)
       $bad = @($all | Where-Object { $_.Missing.Count })
       if ($bad) { @{ Status = 'Problem'; Detail = "Pointing to files that no longer exist: $(($bad | ForEach-Object Kind) -join ', ')"; Fix = 'Set them up again for this folder' } }
       elseif ($all) { @{ Status = 'OK'; Detail = ($all | ForEach-Object Kind) -join ', ' } }
       else { @{ Status = 'OK'; Detail = 'None set up' } }
   }
   Fix = { param($c) foreach ($t in Get-ServerTaskList $c | Where-Object { $_.Missing.Count }) { & $t.Redo $c.Root } }
},

@{ Id = 'shortcuts'; Area = 'App & Windows'; Name = 'Desktop shortcuts'
   Test = {
       param($c)
       $b = @(Get-BrokenShortcuts $c)
       if ($b) { @{ Status = 'Problem'; Detail = "Pointing to a folder that no longer exists: $(($b | ForEach-Object { Split-Path $_.File -Leaf }) -join ', ')"; Fix = 'Point them to this folder' } }
   }
   Fix = {
       param($c)
       $shell = New-Object -ComObject WScript.Shell
       foreach ($b in Get-BrokenShortcuts $c) { $l = $shell.CreateShortcut($b.File); $l.TargetPath = $b.Target; $l.WorkingDirectory = $c.Root; $l.Save() }
   }
},

@{ Id = 'firewall'; Area = 'App & Windows'; Name = 'Firewall (friends joining)'; NeedsDb = $true
   Test = {
       param($c)
       $addr = "$(Get-RepairSql $c 'SELECT address FROM acore_auth.realmlist WHERE id=1;' | Select-Object -Last 1)".Trim()
       if (-not $addr -or $addr -in '127.0.0.1', 'localhost') { return @{ Status = 'OK'; Detail = 'Only you play on this PC (friends not set up)' } }
       if (-not (Get-FirewallRulesEnabled)) { @{ Status = 'Problem'; Detail = "Friends connect to $addr, but Windows Firewall blocks the game ports."; Fix = 'Allow the game ports in the firewall (home/private networks)' } }
       else { @{ Status = 'OK'; Detail = "Game ports open for friends ($addr)" } }
   }
   Fix = { param($c) Set-FirewallRules $c.Root $true }
},

# ------------------------------------------------------------------ AI chatter
@{ Id = 'bridge'; Area = 'AI chatter'; Name = 'AI chatter bridge'; NeedsStop = $true
   When = { param($c) $c.S.Llm.Enabled -and $c.S.Modules -contains 'mod-llm-chatter' }
   Test = {
       param($c)
       $files = (Test-Path (Join-Path $c.Srv 'llm-bridge\llm_chatter_bridge.py')) -or (Test-Path (Join-Path $c.Src 'modules\mod-llm-chatter\tools\llm_chatter_bridge.py'))
       $vpy = Join-Path $c.Srv 'llm-bridge-venv\Scripts\python.exe'
       $works = $false
       if (Test-Path $vpy) { $ErrorActionPreference = 'Continue'; $o = & $vpy -c "import sys; print('ok')" 2>&1; $works = "$o" -match 'ok' }
       $bad = @()
       if (-not $files) { $bad += 'its program files are missing' }
       if (-not $works) { $bad += 'its Python environment is missing or broken' }
       if ($bad) { @{ Status = 'Problem'; Detail = "Bots can't chat with AI: $($bad -join ', ')."; Fix = $(if ($files -or (Test-Path (Join-Path $c.Src 'modules\mod-llm-chatter\tools'))) { 'Set up the bridge again' } else { $null }) } }
   }
   Fix = {
       param($c)
       $venv = Join-Path $c.Srv 'llm-bridge-venv'
       $vpy = Join-Path $venv 'Scripts\python.exe'
       $ErrorActionPreference = 'Continue'
       if ((Test-Path $venv) -and -not ("$(& $vpy -c "print('ok')" 2>&1)" -match 'ok')) { Remove-Item $venv -Recurse -Force }
       $ErrorActionPreference = 'Stop'
       Set-RepairStepGlobals $c
       Update-LlmBridge
   }
},

@{ Id = 'ollama'; Area = 'AI chatter'; Name = 'Ollama and the AI model'
   When = { param($c) $c.S.Llm.Enabled }
   Test = {
       param($c)
       $o = Find-Ollama
       if (-not $o) { return @{ Status = 'Problem'; Detail = 'Ollama is not installed - bots stay silent.'; Fix = 'Install Ollama' } }
       if (-not (Test-PortListening 11434)) { return @{ Status = 'OK'; Detail = 'Installed (starts together with the server)' } }
       $ErrorActionPreference = 'Continue'
       $have = (& $o list 2>$null) -match "^$([regex]::Escape($c.S.Llm.Model))\s"
       if (-not $have) { @{ Status = 'Problem'; Detail = "The AI model $($c.S.Llm.Model) is not downloaded."; Fix = "Download $($c.S.Llm.Model) (several GB)" } }
       else { @{ Status = 'OK'; Detail = "$($c.S.Llm.Model) ready" } }
   }
   Fix = { param($c) Invoke-RepairStep $c 'ollama' }
}
)

function Get-ServerRepairReport([string]$Root) {
    <# Runs every check (read-only, except that it may start the database to look inside). #>
    $c = Get-RepairContext $Root
    foreach ($chk in $RepairChecks) {
        if ($chk.When -and -not (& $chk.When $c)) { continue }
        if ($global:Sync) { Set-Detail "Checking: $($chk.Name)..." }
        $r = $null
        if ($chk.NeedsDb -and -not $c.DbOk) { $r = @{ Status = 'Skipped'; Detail = 'Needs a working database.' } }
        else {
            try { $r = & $chk.Test $c } catch { $r = @{ Status = 'Warning'; Detail = "Could not check: $($_.Exception.Message)" } }
        }
        if (-not $r) { $r = @{ Status = 'OK'; Detail = '' } }
        $fix = if ($chk.Fix -and $r.Fix) { $r.Fix } else { '' }
        if ($fix -and $chk.NeedsStop -and $c.Running) { $fix = "$fix (stop the server first)" }
        [pscustomobject]@{
            Id = $chk.Id; Area = $chk.Area; Check = $chk.Name; Status = $r.Status; Detail = "$($r.Detail)"
            Fix = $fix; CanFix = [bool]($fix -and -not ($chk.NeedsStop -and $c.Running))
        }
    }
}

function Invoke-ServerRepair([string]$Root, [string[]]$Ids) {
    <# Runs the fixes of the given checks (in the checks' order). Returns one line per fix. #>
    New-Item -ItemType Directory -Force (Join-Path $Root '.creationtool') | Out-Null
    $Global:ToolLogFile = Join-Path $Root ".creationtool\repair-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
    Update-SessionPath
    Write-ToolLog "=== Check & repair: $($Ids -join ', ') ==="
    foreach ($chk in $RepairChecks | Where-Object { $Ids -contains $_.Id -and $_.Fix }) {
        $c = Get-RepairContext $Root      # fresh each time: an earlier fix may have changed the settings
        $c.DbOk = Test-PortListening ([int]$c.S.DbPort)
        if ($chk.NeedsStop -and $c.Running) { "• $($chk.Name): skipped - stop the server first."; continue }
        if ($global:Sync) { Set-Detail "Repairing: $($chk.Name)..." }
        try {
            & $chk.Fix $c | Out-Null
            Write-ToolLog "$($chk.Name): repaired." 'OK'
            "✔ $($chk.Name): repaired."
        } catch {
            Write-ToolLog "$($chk.Name): $($_.Exception.Message)" 'ERROR'
            "✖ $($chk.Name): $($_.Exception.Message)"
        }
    }
    Write-ToolLog '=== Check & repair finished ==='
}
