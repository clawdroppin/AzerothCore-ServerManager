# AGENTS.md: guide for AI coding agents (and humans)

This file is for anyone, model or human, who works on **AzerothCore Control Center**
(repo: `clawdroppin/AzerothCore-ServerManager`). Read it fully before changing code. It records the
architecture, the conventions, and the pitfalls that already cost real debugging time.

---

## 0. Golden rules

1. **Never touch a user's real server while testing.** Users run real servers with real characters.
   Test only on a server you created for testing, or on scratch copies. Don't start, stop, update, repair or
   write to anyone's server folder, database or MySQL service unless the user explicitly asked for exactly that.
   Reading files to diagnose is fine.
2. **Target Windows PowerShell 5.1** (`powershell.exe`), not PowerShell 7. No `??`, `?.`, ternary `a ? b : c`,
   `&&`/`||` pipeline chains, or `-Parallel`. See §6.
3. **Keep the user non-technical.** Every message, label and error must make sense to someone who has never
   seen a terminal. Say what happened, what it means for them, and what to click.
4. **Everything long runs in the background** (`Start-BgTask`). The UI thread must never block.
5. **Every install step and repair must be safe to run twice** (idempotent), and every risky operation needs a
   way back (safety copy, rollback, `.bak`).
6. **Run the checks before you commit:** `tools\dev\Invoke-StaticChecks.ps1` must pass, and `App.ps1 -SelfTest` must
   report `0 unexpected handler errors` and `window errors: 0`.
7. **Preserve file encodings.** Files with non-ASCII characters (emoji, `✔`, `•`, `·`) must be **UTF-8 with
   BOM**. CRLF line endings throughout. `.gitattributes` keeps git from converting anything.

---

## 1. What the app is

A WPF desktop app written in PowerShell that:

- **Creates** AzerothCore 3.3.5a servers with the Playerbots fork (`mod-playerbots/azerothcore-wotlk`, branch
  `Playerbot`). It installs prerequisites, clones the sources and modules, compiles with MSVC, sets up a private
  MySQL 8.4 per server, imports databases, downloads map data, generates configs and creates accounts.
- **Manages** them: start and stop, status, console (SOAP), accounts, characters, settings, backups, events,
  updates, modules, performance, logs, friends and networking, AI chatter (Ollama), check & repair.
- **Moves** them: export/import `.wowserver` packages (a zip with a manifest, SQL dumps and the compiled server).

A server is a folder:

```
<server root>\
  azerothcore-wotlk\        source (git) + build\ (CMake/MSBuild); modules\ ; modules-disabled\ (parked)
  server\                   installed programs: worldserver.exe, authserver.exe, dbimport.exe, DLLs
    configs\                *.conf generated from *.conf.dist (+ modules\)
    data\                   map data (or shared: <ServersFolder>\_shared\client-data, see Settings.DataDir)
    logs\                   Server.log, Errors.log, server-control.log, llm-bridge*.log
    llm-bridge\ llm-bridge-venv\   AI chatter bridge (Python) and its venv
  mysql\  database\         private MySQL (service AzerothCoreMySQL_<leaf>), my.ini, data\
  tools\                    copy of payload\tools + server-settings.json (THE settings file) + state files
  secrets\                  soap.txt (admin login for SOAP), mysql-root.txt, my-game-login.txt, discord-webhook.txt
  backups\                  *.zip backups (labels: manual, daily, savepoint, before-update)
  versions\<stamp>\         safety copies kept by safe updates (old programs + info.json)
  .creationtool\            install state (state.json), logs (install-*, update-*, repair-*), test hooks
  START_SERVER.bat STOP_SERVER.bat SERVER_STATUS.bat CREATE_ACCOUNT.bat
```

App-wide data: `%LOCALAPPDATA%\AzerothCoreCreationTool\` holds `servers.json` (the list of servers, `.bak`
alongside), `preferences.json` (ServersFolder, ShareMapData, LastAppUpdateCheck) and `presets\` (user presets).

---

## 2. Architecture

```
AzerothCoreCreationTool.bat ─► src\App.ps1 (self-elevates, STA)
                                 │ dot-sources at GLOBAL scope:
                                 │   Common → Manage → Steps(+Prereqs) → Update → Repair → Windows → Dialogs
                                 │ loads ui\Theme.xaml + ui\App.xaml, wires every handler
                                 │
                                 ├─ UI thread: pages (Enter-<Page>), dialogs, DispatcherTimer (300 ms)
                                 │     └─ timer: completes finished background tasks, refreshes status/logs
                                 │
                                 └─ RunspacePool workers (Start-BgTask): StartupScripts = Common, Manage,
                                       Steps, Update, Repair. Each task gets $Sync (synchronized hashtable:
                                       Log queue, Detail, Current, Cancel, NoCancel) for progress/cancel.

Scheduled tasks ─► src\Headless.ps1 -Root <server> -Action AutoUpdate|Events   (no UI)
Server folder   ─► tools\ServerControl.ps1 (Start/Stop/Restart/Status/Monitor), tools\apply-config.ps1,
                   tools\Backup-Server.ps1, tools\New-GameAccount.ps1  (work WITHOUT the app)
```

### Key files

| File | Role |
|---|---|
| `src\App.ps1` | Everything UI: pages, handlers, `Start-BgTask`/`Complete-BgTask`, overlay, toasts, timer, `-SelfTest`, `-TestScript` |
| `src\Manage.ps1` | Back end for installed servers: registry, settings, conf option model, SQL (`Invoke-ServerSql`), SOAP (`Invoke-ServerSoap`), status, start/stop, accounts, characters, backups, schedules, network, events, item search, character copy (pdump), performance, app version/update check |
| `src\Steps.ps1` | `$InstallSteps` (ordered, idempotent; `Id`, `Title`, optional `When`, `Run`), `Invoke-Install` (resume through `.creationtool\state.json`), `Invoke-ServerBuild` (CMake + MSBuild, RAM-aware parallelism, retries with fewer threads), `Update-LlmBridge` |
| `src\Update.ps1` | `Invoke-SafeUpdate` (`-Components`, `-AddModules`, `-RemoveModules`, `-Rebuild`, `-Clean`, `-WarnMinutes`, `-Unattended`), `Invoke-UpdateRollback`, safety copies, version lock, auto-update task, "make updatable", Discord notices |
| `src\Repair.ps1` | `$RepairChecks` (ordered list of `@{ Id; Area; Name; Test; Fix; NeedsDb; NeedsStop; When }`), `Get-ServerRepairReport`, `Invoke-ServerRepair` |
| `src\Windows.ps1` | Extra settings, Presets and All options windows; `New-ThemedWindow`, `Show-AppDialog` (self-test hook), `Save-ServerOptions` |
| `src\Dialogs.ps1` | `Show-Choice`, `Show-ItemPicker`, `Show-CopyCharacterDialog`, `Show-RepairWindow`; PowerShell classes for DataGrid rows (`UpdRow`, `RepairRow`) |
| `src\Prereqs.ps1` | `$PrereqCatalog`: `Detect` / `Get` (download + verify signature or hash) / silent and guided install |
| `payload\tools\apply-config.ps1` | **The only writer of `.conf` files.** Regenerates every conf from its `.dist` + `server-settings.json` |
| `payload\tools\ServerControl.ps1` | Start/stop for a server folder; SOAP shutdown; crash monitor with auto-restart; Discord notices |
| `config\versions.json` | Core repo and branch, module catalogue (`name`, `title`, `repo`, `branch`, `required`, `community`, `minExpansion`, `config`, `note`), prerequisites, AI models, addons |
| `config\extras.json` / `presets.json` | Extra settings catalogue (plain-language items → conf keys) / built-in presets |
| `config\app.json` | App `version` (semver) and GitHub `repository`, used by "Check for app updates" |

### Settings → config files (important)

- `tools\server-settings.json` is the **source of truth**. `.conf` files are **generated** and never edited by hand.
- `apply-config.ps1` maps settings to conf keys (rates, bots, expansion profile, DB connections, paths), then applies
  `ConfOverrides` (from Extra settings / All options / presets) **last**, then timed-event multipliers.
- `ConfOverrides` is keyed by the conf path relative to `server\configs`, lower-case, with forward slashes:
  `'worldserver.conf'`, `'modules/playerbots.conf'`.
- The first line of every generated conf is a marker (`# Generated by AzerothCore Control Center...`). On the first
  run over a conf *without* the marker, hand-made changes are **captured as overrides**, so no edit is lost.
- Confs are written **UTF-8 without BOM**: the server's config reader fails on a BOM ("Failure to read line 1").
- `Sync-ServerTools` copies `payload\tools\*` and `payload\*.bat` into each server whenever the hashes differ
  (called before applying config, starting, backing up and updating), so fixes reach existing servers.

### Database ports (shared or own)

- `DbPortMode` in a server's settings: `'shared'` (default for new and imported servers) or `'own'` (older servers).
  Shared-mode servers all use `Get-SharedDbPort` (remembered in the preferences as `SharedDbPort`). Own-mode servers
  get a unique port from `Get-FreeDbPort`.
- `payload\tools\DbSlot.ps1` is shared by the app (dot-sourced by `Manage.ps1`), `ServerControl.ps1` and `Backup-Server.ps1`:
  - `Enter-DatabaseSlot` swaps: it stops another *AzerothCoreMySQL_* service holding the port, unless that server's
    worldserver is running (then it throws and changes nothing). It refuses outright if a different program owns the port.
  - `Test-DatabaseIdentity` compares MySQL's `@@datadir` (use `-r` raw output: batch mode doubles backslashes) with
    `<root>\database\data`. `Assert-ServerDatabase` (Manage) caches the result per listening process. `Invoke-ServerSql`,
    `Invoke-MySql` (install steps), ServerControl Start and the backup script all verify before touching data.
  - MySQL 8.4 listens from a **child** of the service process, so find the service through the parent PID.
- The database port is internal only (MySQL binds 127.0.0.1). Online play only ever needs 3724 and 8085.

### Background tasks

```powershell
Start-BgTask -Tag 'unique-tag' -Overlay 'Title for the busy overlay' -Hideable -Cancellable `
    -Script { param($a, $b) Do-Work $a $b } -Arguments @($a, $b) -OnDone {
        param($result, $err)      # runs on the UI thread
        if ($err) { ... }
    }.GetNewClosure()
```

- `-Script` runs in a pooled runspace. Only functions from the StartupScripts exist there, so **no UI objects**.
  Pass data in through `-Arguments`.
- `-Tag` de-duplicates. A periodic task with a tag is skipped while the previous run is still going.
- The worker sets `$global:Sync`. Use `Set-Detail 'text'` and `Write-ToolLog 'text' 'OK|WARN|ERROR'` for progress,
  and check `$Sync.Cancel` at safe points. Once you set `$Sync.NoCancel = $true`, Cancel is disabled.
- **The process environment is shared by all workers** (see §6, PATH).

---

## 3. Major flows

### Safe update (`Invoke-SafeUpdate`)
1. Record git HEADs and copy the settings → `git pull --ff-only` the chosen components (or add/remove modules,
   or `-Rebuild` with no download; `-Clean` moves `build` → `build.previous` first).
2. `Invoke-ServerBuild` in the build directory **while the server keeps running**.
   On a compile failure, `Get-FailingComponents` parses the error paths and the undo resets repos, modules and
   settings. The result is `COMPILE_FAILED` with nothing changed.
3. Stage the new programs from `build\bin\Release`. CMake install destinations are absolute, so `--prefix` can't redirect them.
4. Warn players → stop → `New-ServerBackup 'before-update' -IncludeWorld` → keep the old programs in `versions\<stamp>`
   → copy in the new programs → `apply-config` → start → `Wait-ServerHealthy` (port 8085, stable PID for
   120 s, SOAP answers).
5. On any problem, `Invoke-UpdateRollback`. On success, save the version lock, record history, prune to 2 safety copies, and post a Discord notice.

### Check & repair
`Get-ServerRepairReport` runs each check's `Test` (read-only, except that it may start the database so it can look
inside). The UI ticks the fixable problems. `Invoke-ServerRepair` runs the chosen `Fix`es **in list order**, with
a fresh context each time, skipping `NeedsStop` fixes while the server runs. To add a check, append to
`$RepairChecks` in the right place. `Test` returns `$null` (OK) or `@{ Status='Problem'|'Warning'|'OK'|'Skipped';
Detail='...'; Fix='what the repair does' }`. `Fix` must be idempotent and must never delete user data.

### Install (`Invoke-Install`)
The steps run in order. Completed step ids go to `.creationtool\state.json`, so "Try again" resumes. Build mode
compiles; import mode unpacks a package. Install steps read the globals `$S` (settings), `$V` (versions.json),
`$Root` and `$ToolDir`. Set them when you call a step from elsewhere (see `Set-RepairStepGlobals`).

---

## 4. How to…

| Task | Where |
|---|---|
| Add an **Extra setting** | `config\extras.json`: add an item to a group (`type`: bool / number / gold / choice / ratio / flags; `keys`; optional `minExpansion`). No code needed. |
| Add a **preset** | `config\presets.json` (`changes` per conf file; `{MaxLevel}` token; `clearOverrides`; `botsFactor`). |
| Add a **module** | `config\versions.json` → `modules[]`. Use `config` for conf keys it needs and `note` for user-facing caveats. Compile-test it through Updates → Modules on a **test** server. |
| Add a **repair check** | `src\Repair.ps1` → `$RepairChecks` (see §3). Add it to the README list. |
| Add a **page** | `ui\App.xaml` (a `Nav*` RadioButton + a `Page*` element), add the name to `$Pages` in `App.ps1`, write an `Enter-<Page>` function, and add the page to the self-test lists. |
| Add a **prerequisite** | `src\Prereqs.ps1` → `$PrereqCatalog` (`Detect`, `Get` with signature or hash verification, `Silent`/`Guided`). |
| Change what a **server folder** contains | `payload\` (synced automatically into every server by `Sync-ServerTools`). |
| Bump the **app version** | `config\app.json` + `CHANGELOG.md` (see CONTRIBUTING.md → Releasing). |

---

## 5. Testing

```powershell
# 1. static checks: syntax, BOM/encoding, XAML, JSON, closure pitfalls
powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev\Invoke-StaticChecks.ps1

# 2. self-test: loads every page, clicks safe controls, opens every window (off-screen), reports errors
powershell -NoProfile -STA -ExecutionPolicy Bypass -File src\App.ps1 -SelfTest
#    with screenshots:  $env:ACC_SHOTS = 'C:\temp\shots'  (README screenshots are made this way)
#    with an isolated app profile (no personal servers in the list): set LOCALAPPDATA to a temp folder
#    that contains AzerothCoreCreationTool\servers.json listing only your test server

# 3. scripted scenarios: everything is loaded, then your script runs instead of the window
powershell -NoProfile -STA -ExecutionPolicy Bypass -File src\App.ps1 -TestScript C:\path\my-test.ps1
```

In a `-TestScript`: `$ui`, `$Window`, `$Tasks` and all functions exist. To finish background tasks, pump the
dispatcher and call `Complete-BgTask` on the completed ones. To drive a modal window, set `$global:AccDialogHook = { param($x) ... }`
and `Show-AppDialog` calls it instead of `ShowDialog()` (show off-screen, poke the controls, close).

Test hooks inside a server's `.creationtool\`:
- `test-fail-compile` (containing a module name) simulates a module that doesn't compile.
- `test-fail-health` makes the post-update health check fail (exercises the automatic rollback).

**Make a disposable test server** with the wizard (100 bots, any folder such as `S:\AzerothCoreToolTest`), and
run everything that starts, stops or writes against it. Before starting a test server, check that no other
WoW server is running, since they share ports 3724 / 8085 / 7878.

---

## 6. PowerShell 5.1 and WPF pitfalls (all hit for real)

| Pitfall | Rule |
|---|---|
| **Nested `.GetNewClosure()`**: an inner closure created *inside* a closure does **not** see the variables the outer closure captured. (This was the "Mail item" bug: `$x.Grid` was `$null` in `-OnDone`.) | At the top of the outer block write `$x = $x` (makes it local, so it gets captured). The static check finds these. |
| Event handlers or `-OnDone` blocks without `.GetNewClosure()` run later at global scope, so function locals are `$null`. | Always add `.GetNewClosure()`, or store state in a hashtable you capture. The static check finds these. |
| **`[Environment]::GetEnvironmentVariable('Path','User')` expands `%PATH%`** if the user's registry PATH contains it, so rebuilding `$env:Path` from it doubled the PATH on every task until Windows refused it ("Environment variable name or value is too long") and **every background task failed**. | `Update-SessionPath` reads the raw registry values (`DoNotExpandEnvironmentNames`), drops `%PATH%`, de-duplicates, and only writes on change. The environment is **process-wide**: never append to `$env:*` from workers. |
| Files without a BOM are read as ANSI, so emoji and symbols turn into mojibake or cause parse errors. | UTF-8 **with BOM** for any file with non-ASCII text. `apply-config` writes confs **without** BOM (server requirement). |
| `ConvertFrom-Json` returns a JSON array as **one** pipeline object. | Unroll with `foreach ($i in @($x))`. See `Get-ServerRegistry` and `Get-ServerSettings` (Events). |
| Native tools write warnings to stderr, and with `$ErrorActionPreference='Stop'` that is fatal. | Set `$ErrorActionPreference = 'Continue'` locally around native calls and check `$LASTEXITCODE` (`Invoke-ServerSql`, `Invoke-Native`). |
| An unquoted `-h127.0.0.1` gets split at the dot. | Use `'--host=127.0.0.1'` (quoted). |
| `Get-Content -ErrorAction SilentlyContinue` still adds to `$Error` (and the self-test counts `$Error`). | Guard with `Test-Path`. |
| Setting `Owner` on a dialog fails when the main window isn't shown (self-test). | `New-ThemedWindow` sets the owner only if `$Window.IsVisible`. |
| Multi-line `.Replace()` on files fails silently on CRLF/LF mismatch. | Normalize line endings and assert the match count when patching. |
| Several app-made databases on one port | Always go through `Enter-DatabaseSlot` before starting a database service, and verify with `Test-DatabaseIdentity` / `Assert-ServerDatabase` before reading or writing. |
| A shared settings file read by several processes can be caught mid-write and come back empty. | `servers.json` is written atomically (`.tmp` → `File.Replace` with `.bak`), and reads retry and fall back to `.bak`. Never treat an unreadable file as "empty list". |
| Servers launched from a tool shell die with that shell (job object). | `Start-GameServer` launches through `explorer.exe START_SERVER.bat`, so the server is independent of the app. |

## 7. AzerothCore / server pitfalls

- **pdump** (`pdump write/load`) only accepts a plain file name relative to `server\` (absolute paths fail
  silently), and says "success" *before* the asynchronous DB write. Verify with SQL (`Copy-CharacterToServer`).
- An empty `taximask` in `characters` breaks pdump loads (`NULL` → error 1048). Use 14 numbers:
  `'0 0 0 0 0 0 0 0 0 0 0 0 0 0 '`. The auction-house seller insert and the `taximask` repair use that.
- MSVC with full parallelism runs out of memory (C1076/C3859) when RAM is tight. `Invoke-ServerBuild` sizes
  `/m` and `CL_MPCount` to free RAM (~1.5 GB per compiler) and retries with half.
- A **moved server folder** breaks CMake (`CMakeCache.txt` records the old source path). `Test-BuildCacheStale` +
  `Clear-BuildCache` handle it before every build, and Check & repair offers it too.
- Bot DB deadlocks: `transaction_isolation = READ-COMMITTED` in `my.ini` and `CharacterDatabase.WorkerThreads=2`.
- `AC_DISABLE_INTERACTIVE=1` lets worldserver create missing DBs (for example `acore_playerbots`) without prompting.
- A server moved without source code has no `data\sql`. `apply-config` then disables the DB auto-updaters.
- Thinking AI models (gemma4, qwen3) return empty replies unless `LLMChatter.Ollama.DisableThinking=1`.
- Only one server can run at a time (shared ports). `ServerControl.ps1 Start` refuses when a port is taken and
  names the owner.

---

## 8. Style

- Match the surrounding code: comment density, naming (`Verb-Noun` functions; `$ui.<XamlName>` for controls),
  and short "why" comments only where the code isn't obvious.
- User-facing text uses plain words ("the database", "the login server"), never jargon like "SOAP" or "pdump" without
  an explanation.
- No new runtime dependencies. Everything has to work on a clean Windows 10/11 with only what the app installs.
- Keep `README.txt` (the plain-text manual shipped with the app), `README.md` and this file in sync when behaviour
  changes.
