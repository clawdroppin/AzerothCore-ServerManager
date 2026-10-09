# Safe updates: version record, changelog, build next to the running server, quick swap with a health check,
# automatic rollback, safety copies, pinning, scheduled updates and "make updatable" for moved servers.
# Requires Common.ps1, Manage.ps1 and Steps.ps1 (Invoke-ServerBuild, Update-LlmBridge, Invoke-Install).

$LockFileName = 'versions.lock.json'

# ================================================================== repositories & version record
function Get-ServerRepos([string]$Root) {
    $src = Join-Path $Root 'azerothcore-wotlk'
    if (-not (Test-Path (Join-Path $src '.git'))) { return @() }
    $list = @([pscustomobject]@{ Id = 'core'; Name = 'AzerothCore (core)'; Path = $src })
    foreach ($d in Get-ChildItem (Join-Path $src 'modules') -Directory -ErrorAction SilentlyContinue) {
        if (Test-Path (Join-Path $d.FullName '.git')) { $list += [pscustomobject]@{ Id = $d.Name; Name = $d.Name; Path = $d.FullName } }
    }
    $list
}

function Invoke-Git([string]$Path, [string[]]$GitArgs) {
    $git = Find-Git; if (-not $git) { throw 'Git is not installed (Prerequisites page).' }
    $ErrorActionPreference = 'Continue'
    $out = & $git -C $Path @GitArgs 2>&1
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = @($out | ForEach-Object { "$_" }) }
}

function Get-RepoHead([string]$Path) { "$((Invoke-Git $Path @('rev-parse', 'HEAD')).Out | Select-Object -First 1)".Trim() }

function Get-ServerVersionLock([string]$Root) {
    # What the server's programs were built from: tools\versions.lock.json (written after every successful build).
    $f = Join-Path $Root "tools\$LockFileName"
    if (Test-Path $f) { try { return Get-Content $f -Raw | ConvertFrom-Json } catch {} }
    $null
}

function Save-ServerVersionLock([string]$Root) {
    $repos = Get-ServerRepos $Root
    if (-not $repos) { return }
    $mods = [ordered]@{}
    foreach ($r in $repos | Where-Object Id -ne 'core') {
        $mods[$r.Id] = [pscustomobject]@{ Commit = Get-RepoHead $r.Path; Url = "$((Invoke-Git $r.Path @('remote', 'get-url', 'origin')).Out | Select-Object -First 1)".Trim() }
    }
    $core = $repos | Where-Object Id -eq 'core'
    [pscustomobject]@{
        Built = (Get-Date -Format 's')
        Core = [pscustomobject]@{ Commit = Get-RepoHead $core.Path; Url = "$((Invoke-Git $core.Path @('remote', 'get-url', 'origin')).Out | Select-Object -First 1)".Trim() }
        Modules = [pscustomobject]$mods
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Root "tools\$LockFileName") -Encoding utf8
}

# ================================================================== what's new
function Get-UpdateStatus([string]$Root) {
    <# One row per component: installed version, how many new changes, plain-language changelog. #>
    if (-not (Find-Git)) { throw 'Git is not installed.' }
    foreach ($r in Get-ServerRepos $Root) {
        Set-Detail "Checking $($r.Name) for updates..."
        [void](Invoke-Git $r.Path @('fetch', '--quiet'))
        $behind = "$((Invoke-Git $r.Path @('rev-list', '--count', 'HEAD..@{u}')).Out | Select-Object -First 1)".Trim()
        $n = if ($behind -match '^\d+$') { [int]$behind } else { 0 }
        $changes = @()
        $sql = $false
        if ($n -gt 0) {
            $changes = @((Invoke-Git $r.Path @('log', '--no-merges', '--format=%cs  %s', '-n', '60', 'HEAD..@{u}')).Out | Where-Object { $_ -match '^\d{4}-' })
            $files = (Invoke-Git $r.Path @('diff', '--name-only', 'HEAD', '@{u}')).Out
            $sql = [bool]($files | Where-Object { $_ -match '(^|/)data/sql/|\.sql$' })
        }
        [pscustomobject]@{
            Id = $r.Id; Name = $r.Name
            Current = "$((Invoke-Git $r.Path @('log', '-1', '--format=%h  %cs')).Out | Select-Object -First 1)"
            NewCommits = $n
            Latest = "$((Invoke-Git $r.Path @('log', '-1', '--format=%cs %s', '@{u}')).Out | Select-Object -First 1)"
            Changes = $changes
            HasSql = $sql
            Notes = (@(if ($sql) { 'database changes' }; if ($changes | Where-Object { $_ -match '(?i)\bbreak|\bremov|\bconfig|\brename|\bdeprecat' }) { 'check the changes' }) -join ', ')
        }
    }
}

# ================================================================== history & safety copies
function Get-UpdateHistoryFile([string]$Root) { Join-Path $Root 'tools\update-history.json' }

function Get-UpdateHistory([string]$Root) {
    $f = Get-UpdateHistoryFile $Root
    if (-not (Test-Path $f)) { return @() }
    try { $d = Get-Content $f -Raw | ConvertFrom-Json } catch { return @() }
    @(foreach ($i in @($d)) { foreach ($j in @($i)) { if ($j -and $j.Date) { $j } } })
}

function Add-UpdateHistory([string]$Root, $Entry) {
    $list = @(Get-UpdateHistory $Root) + @($Entry) | Select-Object -Last 50
    ConvertTo-Json -InputObject @($list) -Depth 6 | Set-Content (Get-UpdateHistoryFile $Root) -Encoding utf8
}

function Get-SafetyCopies([string]$Root) {
    <# Previous program versions kept after updates (versions\<stamp>) with their before-update backup. #>
    $dir = Join-Path $Root 'versions'
    if (-not (Test-Path $dir)) { return @() }
    foreach ($d in Get-ChildItem $dir -Directory | Sort-Object Name -Descending) {
        $info = $null; try { $info = Get-Content (Join-Path $d.FullName 'info.json') -Raw | ConvertFrom-Json } catch {}
        $backup = if ($info -and $info.Backup -and (Test-Path $info.Backup)) { Get-Item $info.Backup } else { $null }
        $size = (Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum + $(if ($backup) { $backup.Length } else { 0 })
        [pscustomobject]@{
            Name = $d.Name; Path = $d.FullName
            Date = if ($info) { ([datetime]$info.Date).ToString('yyyy-MM-dd HH:mm') } else { $d.CreationTime.ToString('yyyy-MM-dd HH:mm') }
            From = if ($info) { $info.From } else { '?' }; To = if ($info) { $info.To } else { '?' }
            Backup = if ($backup) { $backup.FullName } else { '' }
            SizeMB = [math]::Round($size / 1MB)
            Result = if ($info) { $info.Result } else { '' }
        }
    }
}

function Remove-SafetyCopy([string]$Root, [string]$Path) {
    $full = (Resolve-Path $Path).Path
    if (-not $full.StartsWith((Join-Path $Root 'versions'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Not a safety copy of this server.' }
    $info = $null; try { $info = Get-Content (Join-Path $full 'info.json') -Raw | ConvertFrom-Json } catch {}
    if ($info -and $info.Backup -and (Test-Path $info.Backup)) { Remove-Item -LiteralPath $info.Backup -Force }
    Remove-Item -LiteralPath $full -Recurse -Force
}

# ================================================================== the safe update
function Get-ServerProgramFiles([string]$Dir) {
    # The parts of a server folder that an update replaces: programs and the default config files (.conf.dist).
    @(Get-ChildItem $Dir -File -Filter *.exe -ErrorAction SilentlyContinue) +
    @(Get-ChildItem (Join-Path $Dir 'configs') -Recurse -File -Filter *.conf.dist -ErrorAction SilentlyContinue)
}

function Copy-ServerProgramFiles([string]$From, [string]$To) {
    foreach ($f in Get-ServerProgramFiles $From) {
        $rel = $f.FullName.Substring($From.Length).TrimStart('\')
        $dst = Join-Path $To $rel
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        Copy-Item $f.FullName $dst -Force
    }
}

function Stop-ServerHard([string]$Root) {
    # Used only when rolling back a server that does not start properly (nothing to save: its data is restored next).
    Set-Content (Join-Path $Root 'server\stop.requested') (Get-Date -Format o) -ErrorAction SilentlyContinue
    foreach ($n in 'worldserver', 'authserver') { $p = Get-ServerProcessInfo $Root $n; if ($p) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*llm_chatter_bridge.py*' -and $_.CommandLine -like "*$Root*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
}

function Wait-ServerHealthy([string]$Root, [int]$StartTimeoutMin = 30, [int]$ObserveSec = 120) {
    <# After an update the first start also applies database updates. Healthy = the world opens its port, answers
       admin commands and keeps running (same process) for a while. Returns $null when healthy, else the reason. #>
    $deadline = (Get-Date).AddMinutes($StartTimeoutMin)
    $proc = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $p = Get-ServerProcessInfo $Root 'worldserver'
        if ($p -and -not $proc) { $proc = $p; Write-ToolLog "World server started (PID $($p.Id)); waiting for it to finish loading..." }
        if ($proc -and (-not $p -or $p.Id -ne $proc.Id)) { return 'The world server stopped while starting (crash or database update failure).' }
        if ($proc -and (Test-PortListening 8085)) { break }
        Set-Detail "Starting the updated server... ($([int]((Get-Date) - $deadline.AddMinutes(-$StartTimeoutMin)).TotalSeconds) s)"
    }
    if (-not $proc) { return 'The world server did not start.' }
    if (-not (Test-PortListening 8085)) { return "The world server did not finish loading within $StartTimeoutMin minutes." }
    Write-ToolLog 'The world is online. Watching it for a little while...' 'OK'
    $end = (Get-Date).AddSeconds($ObserveSec)
    $soapOk = $false
    while ((Get-Date) -lt $end) {
        Start-Sleep -Seconds 5
        $p = Get-ServerProcessInfo $Root 'worldserver'
        if (-not $p -or $p.Id -ne $proc.Id) { return 'The world server crashed shortly after starting.' }
        if (-not $soapOk) { try { $r = Invoke-ServerSoap $Root 'server info'; if ($r -match 'AzerothCore|Connected|Uptime') { $soapOk = $true } } catch {} }
        Set-Detail "Checking the updated server... $([int]($end - (Get-Date)).TotalSeconds) s left"
    }
    if (-not $soapOk) { return 'The world server does not answer admin commands.' }
    # Development hook: .creationtool\test-fail-health makes a healthy update look broken (tests the rollback).
    if (Test-Path (Join-Path $Root '.creationtool\test-fail-health')) { return 'Simulated problem (test hook).' }
    $null
}

function Get-FailingComponents([string]$Root) {
    # Names the modules (or the core) in which the compiler errors happened.
    $names = @()
    foreach ($l in @($Global:BuildErrors)) {
        if ($l -match '\\modules\\([^\\]+)\\') { $names += $Matches[1] }
        elseif ($l -match '\\azerothcore-wotlk\\(src|deps)\\') { $names += 'core' }
    }
    @($names | Select-Object -Unique)
}

function Invoke-SafeUpdate {
    <# Updates the chosen components (core and/or module names). The running server keeps running while the new
       version compiles; then it is stopped (with a warning to players), fully backed up, swapped, started and checked.
       Any problem after the swap rolls everything back automatically. Returns a result object. #>
    param(
        [string]$Root,
        [string]$ToolDirectory,
        [string[]]$Components = @(),
        [int]$WarnMinutes = 0,
        [switch]$Unattended,
        [string[]]$AddModules = @(),       # module changes go through the same safe pipeline
        [string[]]$RemoveModules = @(),
        [switch]$Rebuild,                  # recompile and reinstall the current version (no download)
        [switch]$Clean                     # with -Rebuild: compile everything from scratch (fresh build folder)
    )
    $AddModules = @($AddModules | Where-Object { $_ }); $RemoveModules = @($RemoveModules | Where-Object { $_ })
    $s = Get-ServerSettings $Root
    $Global:S = $s; $Global:Root = $Root; $Global:ToolDir = $ToolDirectory
    $Global:V = Get-Content (Join-Path $ToolDirectory 'config\versions.json') -Raw | ConvertFrom-Json
    New-Item -ItemType Directory -Force (Join-Path $Root '.creationtool') | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Global:ToolLogFile = Join-Path $Root ".creationtool\update-$stamp.log"
    Update-SessionPath
    if ($null -eq $env:BOOST_ROOT) { $env:BOOST_ROOT = [Environment]::GetEnvironmentVariable('BOOST_ROOT', 'Machine') }
    $result = [ordered]@{ Ok = $false; Stage = 'start'; Message = ''; Failing = @(); RolledBack = $false; Log = $Global:ToolLogFile }
    if ($Sync) { $Sync.UpdateResult = $result }

    $repos = @(Get-ServerRepos $Root)
    if (-not $repos) { throw 'This server has no source code, so it cannot be updated yet. Use "Make updatable" first.' }
    if ($s.UpdatePinned -and -not $Rebuild) { throw 'This server is pinned to its current version (Updates page). Unpin it to update.' }
    $free = Get-FreeSpaceGB $Root
    if ($free -lt 8) { throw "Only $free GB free on the server's drive; an update needs about 8 GB." }
    Sync-ServerTools $Root
    $selected = @($repos | Where-Object { $Components -contains $_.Id })
    $moduleChange = [bool]($AddModules.Count -or $RemoveModules.Count)
    if ($Rebuild) { $selected = @() }
    if (-not $selected -and -not $moduleChange -and -not $Rebuild) { throw 'Nothing selected to update.' }

    # ---- 1. remember exactly where every component is now (and the settings)
    $prev = @{}; foreach ($r in $repos) { $prev[$r.Id] = Get-RepoHead $r.Path }
    $fromText = "core $($prev['core'].Substring(0, 9))"
    $settingsBefore = Join-Path $Root '.creationtool\settings-before-update.json'
    Copy-Item (Join-Path $Root 'tools\server-settings.json') $settingsBefore -Force
    $what = @($selected | ForEach-Object Name) + @($AddModules | ForEach-Object { "+$_" }) + @($RemoveModules | ForEach-Object { "-$_" })
    if ($Rebuild) { $what += $(if ($Clean) { 'clean recompile' } else { 'recompile' }) }
    Write-ToolLog "=== Safe update of $($s.RealmName): $($what -join ', ') ==="
    # Undo for module changes (used when the new set does not compile or does not start).
    $buildDir = Join-Path $Root 'azerothcore-wotlk\build'
    $oldBuild = Join-Path $Root 'azerothcore-wotlk\build.previous'
    $undo = {
        foreach ($x in $repos) { if ($prev[$x.Id] -and (Test-Path $x.Path) -and (Get-RepoHead $x.Path) -ne $prev[$x.Id]) { [void](Invoke-Git $x.Path @('reset', '--hard', $prev[$x.Id])) } }
        # A failed clean recompile: put the previous build folder back so the next try is quick again.
        if ((Test-Path $oldBuild) -and -not (Test-Path (Join-Path $buildDir 'bin\Release\worldserver.exe'))) {
            if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue }
            if (-not (Test-Path $buildDir)) { Rename-Item $oldBuild 'build' }
        }
        foreach ($m in $AddModules) { Disable-ServerModule $Root $m }
        foreach ($m in $RemoveModules) { Enable-ServerModuleSource $Root $m }
        Copy-Item $settingsBefore (Join-Path $Root 'tools\server-settings.json') -Force
    }

    # ---- 1b. module changes: park removed modules, fetch added ones
    if ($moduleChange) {
        $Sync.Current = 'Getting the modules'
        foreach ($m in $RemoveModules) { Disable-ServerModule $Root $m; Write-ToolLog "Module $m switched off." 'OK' }
        try { foreach ($m in $AddModules) { Set-Detail "Downloading module $m..."; Enable-ServerModuleSource $Root $m; Write-ToolLog "Module $m added." 'OK' } }
        catch { & $undo; throw "Could not download a module: $($_.Exception.Message)" }
        $s = Get-ServerSettings $Root
        $s.Modules = @(@($s.Modules | Where-Object { $RemoveModules -notcontains $_ }) + $AddModules | Select-Object -Unique)
        if ($AddModules -contains 'mod-llm-chatter') { $s.Llm.Enabled = $true }
        Update-ModuleConfigOverrides $s $Global:V.modules
        Save-ServerSettings $Root $s
        $Global:S = $s
        if ($AddModules -contains 'mod-llm-chatter') { foreach ($st in $InstallSteps | Where-Object { $_.Id -in 'python', 'ollama' }) { & $st.Run } }
    }

    # ---- 2. download the changes
    $result.Stage = 'download'
    $Sync.Current = 'Downloading the changes'
    foreach ($r in $selected) {
        Set-Detail "Downloading changes for $($r.Name)..."
        $g = Invoke-Git $r.Path @('pull', '--ff-only')
        if (-not $g.Ok) {
            foreach ($x in $repos) { [void](Invoke-Git $x.Path @('reset', '--hard', $prev[$x.Id])) }
            throw "Could not download the changes for $($r.Name): $($g.Out -join ' ')"
        }
        Write-ToolLog "$($r.Name): $($prev[$r.Id].Substring(0, 9)) -> $((Get-RepoHead $r.Path).Substring(0, 9))" 'OK'
    }
    $changed = @($repos | Where-Object { (Get-RepoHead $_.Path) -ne $prev[$_.Id] })
    if (-not $changed -and -not $moduleChange -and -not $Rebuild) { $result.Ok = $true; $result.Message = 'Everything was already up to date.'; return [pscustomobject]$result }

    # ---- 3. compile next to the running server
    $result.Stage = 'build'
    $Sync.Current = 'Compiling the new version (the server keeps running meanwhile)'
    if ($Rebuild -and $Clean -and (Test-Path $buildDir)) {
        # Keep the old build folder until the fresh one works (a rename, instant).
        if (Test-Path $oldBuild) { Remove-Item $oldBuild -Recurse -Force }
        Rename-Item $buildDir 'build.previous'
        Write-ToolLog 'Clean recompile: starting with a fresh build folder (the old one is kept until this works).'
    }
    # Development hook: .creationtool\test-fail-compile (containing a module name) simulates a module that doesn't compile.
    $simCompile = Join-Path $Root '.creationtool\test-fail-compile'
    try {
        if (Test-Path $simCompile) { $Global:BuildErrors = [Collections.ArrayList]@("$Root\azerothcore-wotlk\modules\$((Get-Content $simCompile -Raw).Trim())\src\x.cpp(1): error C2065: simulated"); throw 'simulated compile failure' }
        Invoke-ServerBuild
    }
    catch {
        if ($_.Exception -is [OperationCanceledException]) { & $undo; throw }
        $result.Failing = @(Get-FailingComponents $Root)
        Write-ToolLog "The new version does not compile ($(if ($result.Failing) { $result.Failing -join ', ' } else { 'unknown part' })). Going back to the current version - the server was not touched." 'WARN'
        & $undo
        $result.Message = 'COMPILE_FAILED'
        Add-UpdateHistory $Root ([pscustomobject]@{ Date = (Get-Date -Format 's'); Result = 'compile failed'; From = $fromText; To = ''; Detail = ($result.Failing -join ', ') })
        return [pscustomobject]$result
    }

    # ---- 4. stage the new programs
    $stage = Join-Path $Root '.creationtool\update-stage'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    $bin = Join-Path $Root 'azerothcore-wotlk\build\bin\Release'
    Copy-ServerProgramFiles $bin $stage
    foreach ($exe in 'worldserver.exe', 'authserver.exe') { if (-not (Test-Path (Join-Path $stage $exe))) { throw "The new $exe is missing after compiling." } }
    if (Test-Path $oldBuild) { Remove-Item $oldBuild -Recurse -Force -ErrorAction SilentlyContinue }
    $toText = "core $((Get-RepoHead ($repos | Where-Object Id -eq 'core').Path).Substring(0, 9))"

    # ---- 5. stop (with a warning), back up everything. From here on the job must finish (or roll back) - no cancel.
    $result.Stage = 'swap'
    if ($Sync.Cancel) { & $undo; throw [OperationCanceledException]::new('The update was cancelled. Nothing was changed.') }
    $Sync.NoCancel = $true
    $wasRunning = [bool](Get-ServerProcessInfo $Root 'worldserver')
    if ($wasRunning) {
        $Sync.Current = 'Stopping the server for the switch-over'
        if ($WarnMinutes -gt 0) {
            try {
                Invoke-ServerSoap $Root "announce The server restarts in $WarnMinutes minute(s) to install an update. Please find a safe spot." | Out-Null
                Write-ToolLog "Players warned ($WarnMinutes min)."
                Start-Sleep -Seconds ($WarnMinutes * 60)
            } catch {}
        }
        Stop-GameServer $Root | ForEach-Object { Write-ToolLog $_ }
        if (Get-ServerProcessInfo $Root 'worldserver') { & $undo; throw 'The server could not be stopped, so the update was not installed.' }
    }
    $Sync.Current = 'Saving a complete safety copy'
    $backup = New-ServerBackup $Root 'before-update' -IncludeWorld
    Write-ToolLog "Safety backup: $backup" 'OK'

    # ---- 6. swap: keep the old programs in versions\<stamp>, put the new ones in place
    $Sync.Current = 'Installing the new version'
    $srv = Join-Path $Root 'server'
    $keep = Join-Path $Root "versions\$stamp"
    New-Item -ItemType Directory -Force $keep | Out-Null
    Copy-ServerProgramFiles $srv (Join-Path $keep 'server')
    $bridge = Join-Path $srv 'llm-bridge'
    if (Test-Path $bridge) { Copy-Item $bridge (Join-Path $keep 'llm-bridge') -Recurse -Exclude '__pycache__' }
    Copy-Item $settingsBefore (Join-Path $keep 'server-settings.json')
    if ($moduleChange) { $toText += "  (" + ((@($AddModules | ForEach-Object { "+$_" }) + @($RemoveModules | ForEach-Object { "-$_" })) -join ' ') + ")" }
    $info = [ordered]@{ Date = (Get-Date -Format 's'); From = $fromText; To = $toText; Backup = $backup; Commits = [pscustomobject]$prev; Result = 'installing'; Added = @($AddModules); Removed = @($RemoveModules) }
    [pscustomobject]$info | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $keep 'info.json') -Encoding utf8
    Copy-ServerProgramFiles $stage $srv
    Remove-Item $stage -Recurse -Force
    Invoke-ApplyServerConfig $Root | ForEach-Object { Write-ToolLog "$_" }
    if ($s.Llm.Enabled -and (($changed | Where-Object Id -eq 'mod-llm-chatter') -or $AddModules -contains 'mod-llm-chatter')) { try { Update-LlmBridge } catch { Write-ToolLog "AI chatter bridge: $($_.Exception.Message)" 'WARN' } }
    if ($AddModules -contains 'mod-ah-bot-plus') {
        # The auction house bot needs its own account and seller characters.
        try { Start-ServerDatabase $Root; & ($InstallSteps | Where-Object Id -eq 'accounts').Run } catch { Write-ToolLog "Auction house bot setup: $($_.Exception.Message)" 'WARN' }
    }

    # ---- 7. start and check; roll back on any problem
    $result.Stage = 'check'
    $Sync.Current = 'Starting the updated server and checking it'
    Start-GameServer $Root
    $problem = Wait-ServerHealthy $Root
    if ($problem) {
        Write-ToolLog "Problem after the update: $problem Rolling back..." 'ERROR'
        $result.Message = $problem
        Invoke-UpdateRollback -Root $Root -SafetyCopy $keep -StartAfter:$wasRunning -Reason $problem
        $result.RolledBack = $true
        return [pscustomobject]$result
    }
    if (-not $wasRunning) { Write-ToolLog 'The update works. Stopping the server again (it was off before).'; Stop-GameServer $Root | ForEach-Object { Write-ToolLog $_ } }

    # ---- 8. done: record it, keep the last two safety copies
    Save-ServerVersionLock $Root
    $info.Result = 'ok'
    [pscustomobject]$info | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $keep 'info.json') -Encoding utf8
    $parts = @($changed | Where-Object { $AddModules -notcontains $_.Id } | ForEach-Object Name)
    if ($AddModules.Count) { $parts += "added $($AddModules -join ', ')" }
    if ($RemoveModules.Count) { $parts += "switched off $($RemoveModules -join ', ')" }
    if ($Rebuild -and -not $parts.Count) { $parts += $(if ($Clean) { 'recompiled from scratch and reinstalled' } else { 'recompiled and reinstalled' }) }
    Add-UpdateHistory $Root ([pscustomobject]@{ Date = (Get-Date -Format 's'); Result = 'ok'; From = $fromText; To = $toText; Detail = ($parts -join '; ') })
    foreach ($old in @(Get-SafetyCopies $Root | Select-Object -Skip 2)) { try { Remove-SafetyCopy $Root $old.Path } catch {} }
    Send-ServerNotice $Root "Update installed on **$($s.RealmName)**: $fromText -> $toText." 'OnUpdate'
    $result.Ok = $true; $result.Stage = 'done'
    $result.Message = if ($parts.Count) { "Done: $($parts -join '; ')." } else { 'Done.' }
    Write-ToolLog "=== Update finished: $($result.Message) ===" 'OK'
    [pscustomobject]$result
}

function Invoke-UpdateRollback {
    <# Puts back the programs, settings and databases from a safety copy (versions\<stamp>). #>
    param([string]$Root, [string]$SafetyCopy, [switch]$StartAfter, [string]$Reason = 'rolled back by the user')
    $info = Get-Content (Join-Path $SafetyCopy 'info.json') -Raw | ConvertFrom-Json
    $Sync.Current = 'Going back to the previous version'
    if (Get-ServerProcessInfo $Root 'worldserver') {
        Stop-GameServer $Root | ForEach-Object { Write-ToolLog $_ }
        if (Get-ServerProcessInfo $Root 'worldserver') { Stop-ServerHard $Root }
    }
    Stop-ServerHard $Root   # also clears a leftover login server / bridge
    Copy-ServerProgramFiles (Join-Path $SafetyCopy 'server') (Join-Path $Root 'server')
    $oldBridge = Join-Path $SafetyCopy 'llm-bridge'
    if (Test-Path $oldBridge) { Copy-Item (Join-Path $oldBridge '*') (Join-Path $Root 'server\llm-bridge') -Recurse -Force }
    Write-ToolLog 'Previous programs restored.' 'OK'
    if ($info.Backup -and (Test-Path $info.Backup)) {
        Set-Detail 'Restoring the databases from the safety copy (a few minutes)...'
        Restore-ServerBackup $Root $info.Backup -NoSafetyBackup
        Write-ToolLog 'Databases restored.' 'OK'
    } else { Write-ToolLog 'The safety backup is missing - databases were left as they are.' 'WARN' }
    # Modules and settings back to how they were (an update may have added or removed modules).
    foreach ($m in @($info.Added | Where-Object { $_ })) { Disable-ServerModule $Root $m }
    foreach ($m in @($info.Removed | Where-Object { $_ })) { try { Enable-ServerModuleSource $Root $m } catch { Write-ToolLog "Could not restore module $m ($($_.Exception.Message))" 'WARN' } }
    $oldSettings = Join-Path $SafetyCopy 'server-settings.json'
    if (Test-Path $oldSettings) { Copy-Item $oldSettings (Join-Path $Root 'tools\server-settings.json') -Force }
    # Source code back to the old version too, so the next update starts from a consistent state.
    if ($info.Commits) {
        foreach ($r in Get-ServerRepos $Root) {
            $c = $info.Commits.($r.Id)
            if ($c) { [void](Invoke-Git $r.Path @('reset', '--hard', $c)) }
        }
    }
    Invoke-ApplyServerConfig $Root | Out-Null
    Remove-Item (Join-Path $Root 'server\stop.requested') -ErrorAction SilentlyContinue
    $info.Result = 'rolled back'
    $info | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $SafetyCopy 'info.json') -Encoding utf8
    Add-UpdateHistory $Root ([pscustomobject]@{ Date = (Get-Date -Format 's'); Result = 'rolled back'; From = $info.To; To = $info.From; Detail = $Reason })
    Send-ServerNotice $Root "Update on **$((Get-ServerSettings $Root).RealmName)** was rolled back: $Reason" 'OnUpdate'
    if ($StartAfter) { Start-GameServer $Root; Write-ToolLog 'Server started again on the previous version.' 'OK' }
    else {
        # The database was only needed for the restore; put it back to sleep if it normally stops with the server.
        $st = Get-ServerSettings $Root
        if ($st.MySqlStopWithServer) { Stop-Service $st.MySqlService -ErrorAction SilentlyContinue; Remove-Item (Join-Path $Root '.creationtool\db-started-by-app') -ErrorAction SilentlyContinue }
    }
    Write-ToolLog '=== Rollback finished: the server is back on its previous version. ===' 'OK'
}

function Enable-ServerModuleSource([string]$Root, [string]$Name) {
    # Brings a module's source back from modules-disabled\, or downloads it (catalog repo and branch).
    $mod = Join-Path $Root "azerothcore-wotlk\modules\$Name"
    if (Test-Path (Join-Path $mod '.git')) { return }
    $parked = Join-Path $Root "azerothcore-wotlk\modules-disabled\$Name"
    if (Test-Path $parked) { Move-Item $parked $mod; return }
    $cat = Get-Content (Join-Path $global:ToolDir 'config\versions.json') -Raw | ConvertFrom-Json
    $m = $cat.modules | Where-Object name -eq $Name
    if (-not $m) { throw "Unknown module $Name." }
    Invoke-Native (Find-Git) "clone --depth 1 --branch $($m.branch) $($m.repo) `"$mod`"" -Quiet | Out-Null
}

function Disable-ServerModule([string]$Root, [string]$Name) {
    # Parks a module (modules-disabled\) and removes it from the settings; Updates > Modules can bring it back.
    $s = Get-ServerSettings $Root
    $mod = Join-Path $Root "azerothcore-wotlk\modules\$Name"
    $off = Join-Path $Root 'azerothcore-wotlk\modules-disabled'
    New-Item -ItemType Directory -Force $off | Out-Null
    if (Test-Path $mod) { Move-Item $mod (Join-Path $off $Name) -Force }
    $s.Modules = @($s.Modules | Where-Object { $_ -ne $Name })
    if ($Name -eq 'mod-llm-chatter') { $s.Llm.Enabled = $false }
    Save-ServerSettings $Root $s
}

# ================================================================== scheduled updates
function Get-AutoUpdateTaskName([string]$Root) { "AzerothCore auto-update ($((Get-ServerSettings $Root).RealmName -replace '[\\/:*?""<>|]', ''))" }

function Set-AutoUpdate([string]$Root, [string]$ToolDirectory, [bool]$Enabled, [string]$Day = 'Sunday', [string]$Time = '05:00') {
    $name = Get-AutoUpdateTaskName $Root
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    if (-not $Enabled) { return }
    $script = Join-Path $ToolDirectory 'src\Headless.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -Root `"$Root`" -Action AutoUpdate"
    $trigger = if ($Day -eq 'Daily') { New-ScheduledTaskTrigger -Daily -At $Time } else { New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Time }
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Installs AzerothCore updates for $Root when nobody is playing (rolls back automatically on problems)" | Out-Null
}

function Get-AutoUpdate([string]$Root) {
    $t = Get-ScheduledTask -TaskName (Get-AutoUpdateTaskName $Root) -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    $tr = $t.Triggers[0]
    $day = if ($tr.DaysOfWeek) { @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')[[math]::Log([int]$tr.DaysOfWeek, 2)] } else { 'Daily' }
    [pscustomobject]@{ Day = $day; Time = ([datetime]$tr.StartBoundary).ToString('HH:mm') }
}

# ================================================================== make a moved server updatable
function Invoke-MakeUpdatable([string]$Root, [string]$ToolDirectory) {
    <# A server imported with "Move this server" has no source code. Download the source at exactly the versions it
       was built from (tools\versions.lock.json), compile it (30-90 min), and from then on it updates like any other. #>
    $s = Get-ServerSettings $Root
    $lock = Get-ServerVersionLock $Root
    $pins = [ordered]@{}
    if ($lock) {
        $pins['core'] = $lock.Core.Commit
        foreach ($m in $lock.Modules.PSObject.Properties) { $pins[$m.Name] = $m.Value.Commit }
    } elseif ($s.CoreRevision) {
        Write-ToolLog "No exact version record; using core revision $($s.CoreRevision) and the newest modules." 'WARN'
    }
    $s.InstallMode = 'build'
    $s | Add-Member -NotePropertyName PinCommits -NotePropertyValue ([pscustomobject]$pins) -Force
    $s | Add-Member -NotePropertyName PlayerPass -NotePropertyValue '' -Force
    Invoke-Install -Settings $s -ToolDirectory $ToolDirectory -StepIds 'git', 'cmake', 'msvc', 'boost', 'openssl', 'source', 'build', 'installbin', 'config', 'bridge'
    # The pins only apply to this first build; later updates move forward normally.
    $s2 = Get-ServerSettings $Root
    $s2.PSObject.Properties.Remove('PinCommits')
    $s2.InstallMode = 'build'
    Save-ServerSettings $Root $s2
    Save-ServerVersionLock $Root
}

# ================================================================== notifications (Discord)
function Get-DiscordWebhook([string]$Root) {
    $f = Join-Path $Root 'secrets\discord-webhook.txt'
    if (Test-Path $f) { "$(Get-Content $f -Raw)".Trim() } else { '' }
}

function Send-ServerNotice([string]$Root, [string]$Text, [string]$Kind = '') {
    # Posts to the server's Discord webhook if one is set (and that kind of notice is switched on). Never throws.
    try {
        $url = Get-DiscordWebhook $Root
        if (-not $url) { return }
        if ($Kind) { $n = (Get-ServerSettings $Root).Notify; if ($n -and $n.$Kind -eq $false) { return } }
        Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body (@{ content = $Text; username = 'AzerothCore Control Center' } | ConvertTo-Json) -TimeoutSec 10 | Out-Null
    } catch {}
}
