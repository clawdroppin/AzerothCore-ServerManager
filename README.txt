AZEROTHCORE CONTROL CENTER
==========================
Project page, downloads and issues: https://github.com/clawdroppin/AzerothCore-ServerManager

Create your own World of Warcraft 3.3.5a (Wrath of the Lich King) private servers
full of AI players (bots), then run them all from one window: start/stop, accounts,
friends, backups, updates, moving a server to another PC, and more.


WHAT YOU NEED
-------------
- Windows 10 or 11 (64-bit)
- The WoW 3.3.5a game client (version 3.3.5.12340) on this PC
- About 15-30 GB of free disk space per server (an SSD is best)
- 16 GB of RAM or more (32 GB+ for hundreds of bots)
- An internet connection
- Optional: an NVIDIA graphics card with 8 GB+ memory, for bots that chat using AI
- For a brand-new server: about 1-2 hours, most of it unattended
  (an imported server is ready in a few minutes)


START
-----
Double-click  AzerothCoreCreationTool.bat  and click "Yes" when Windows asks for permission.

- No server yet?          "Create a new server" and follow the 4 steps.
- Server on another PC?   "Import a server" and pick its .wowserver file.
- Existing server folder? "I already have one" / "Add existing folder" - existing AzerothCore
                          servers are detected and imported; nothing changes until you save.

Only the prerequisites?   tools\PrereqInstaller\PrereqInstaller.bat opens the app straight on
                          the Prerequisites page (check / install / repair everything a PC needs).


HOW SEVERAL SERVERS WORK
------------------------
- Every server lives in its own folder (by default <biggest drive>\WoWServers\<name>), with its
  own private MySQL database. Nothing is shared between servers except read-only map data and
  the download cache, so one server can never touch another's characters.
- Only ONE server runs at a time (the WoW client always uses the same login port). Starting
  another one offers to stop the running one first.
- A server's database only runs while that server runs, so idle servers use no memory.
  (The app wakes it briefly when you look at accounts/characters, and puts it back to sleep.)


WHAT EACH PAGE DOES
-------------------
My servers          One card per server: start/stop, manage, duplicate, export, free up space,
                    delete. Also where new servers go and the shared download cache.
Dashboard           Players and bots online, server speed graph, health check, services,
                    quick actions (save, announce, message of the day, launch WoW, back up),
                    start automatically with Windows, and "Check & repair" (see below).
Console             Any Game Master command on the live server (Up/Down = history).
Accounts            Create logins, reset passwords, GM levels, ban/unban, delete.
Characters & bots   Browse players and bots; kick, teleport, set level, mail gold or items.
Play with friends   Same home network, free VPN (Tailscale) or port forwarding (router guide
                    included). Adds the two firewall rules and makes a "join kit" to send.
AI chatter          AI bot chat on/off, pick/download/test a model, how chatty.
World settings      Name, game version (Vanilla/TBC/WotLK), PvP/PvE, speed, all rates, bots. Plus:
                      - Extra settings: dozens more options in plain language (flights, starting
                        gold/level, death penalty, cross-faction play, monster difficulty, loot,
                        battlegrounds, bot behaviour, module options...). Each has a "back to
                        default" button.
                      - Presets: one-click styles (Blizzlike, Relaxed solo, Fast & fun, Hardcore,
                        Instant endgame, Battleground brawl, Friends & family, Laptop mode). Save
                        your own setup as a preset and share the file with friends.
                      - All options (advanced): every option of every server file, with the
                        developers' descriptions, searchable. New options from future versions
                        show up automatically. Your changes survive updates.
Game addons         One-click MultiBot, Dungeon Clear panel, Chatter Companion.
Backups & schedules Back up now, save points (everything incl. the world and your settings, to undo
                    an experiment), daily backups, an extra copy on another drive/cloud folder,
                    delete old backups, daily restart with in-game warning, and timed events
                    (double XP weekend, loot weekend, happy hour...) that switch on and off by
                    themselves with an in-game announcement.
Characters & bots   ... also "Mail item" with a searchable item list (coloured by quality) and
                    "Copy to another server" (gear, bags, quests... via AzerothCore's pdump).
Play with friends   ... plus optional Discord notifications (online/offline, logins, crashes, updates).
Export & move       Pack the server into one file:
                      - "Move this server": runs on the other PC without compiling (minutes)
                      - "Characters and settings only": small; the other PC builds it fresh
Updates             Safe updates (see below), changelog per component, safety copies with
                    "go back", automatic updates, pinning, and modules (11 optional community
                    modules such as AutoBalance, Transmog, Solo dungeon finder, Individual
                    Progression). Module changes use the same safe pipeline.
                    "Recompile" builds the programs again from the current version (no
                    download), with the same safety copy and rollback; "Clean recompile"
                    starts from a fresh build folder (30-90 min) to cure a damaged build.
Performance         CPU, memory, graphics memory, what uses them, and a suggested bot count.
Logs                Server logs with filter and auto-refresh.
Prerequisites       What this PC has / needs, install silently or in guided mode, and a
                    "Check download links" button.
Help & about        In-game cheat sheet for bots, Dungeon Clear and GM commands, the app version
                    and "Check for app updates" (also checked quietly once a day).


MOVING A SERVER TO A LAPTOP (or any other PC)
---------------------------------------------
1. On this PC: select the server > Export & move > "Move this server" > Export now.
   (Works while the server is running. A typical file is 150 MB - 1.5 GB.)
2. Copy the .wowserver file over (USB stick, network share, cloud drive).
3. On the laptop: copy this whole AzerothCoreCreationTool folder there too, start it,
   choose "Import a server" and pick the file. Log in with the same account as before.


SAFE UPDATES (AzerothCore keeps improving - this is how the app keeps up)
------------
1. Check for updates shows what changed, per component, with warnings for database changes.
2. The new version compiles while your server keeps running (players stay online).
3. Players get a warning, the server stops, and a complete safety copy is saved
   (characters, world, settings and the current programs).
4. The new version starts and is watched for a couple of minutes. If it crashes or doesn't
   answer, everything is put back automatically - nothing is lost.
5. If a module doesn't work with the new AzerothCore yet, nothing is changed and you choose:
   update without that module for now, keep AzerothCore as it is, or wait.
- The newest two safety copies are kept; delete them on the Updates page once you're happy.
- "Go back" restores the version from before any kept update.
- Automatic updates (optional): weekly or daily at a set time, only when no real player is
  online, with the same automatic rollback. Pin a server to never update it.
- A server moved from another PC can be made updatable (it fetches the exact source it was
  built from and compiles once).
- Every server keeps tools\versions.lock.json: the exact versions its programs were built from.
- Every app update also refreshes the helper scripts inside each server folder automatically.


EVERY DAY
---------
- Start: My servers / Dashboard > Start   (or "Start <server name>" on the desktop)
- Stop:  Dashboard > Stop                  (or "Stop <server name>" on the desktop)
         Always stop this way so everyone's characters are saved.
- Without the app: START_SERVER.bat, STOP_SERVER.bat, SERVER_STATUS.bat and
  CREATE_ACCOUNT.bat in each server folder do the basics (no admin prompt needed).


IF SOMETHING GOES WRONG
-----------------------
- First try Dashboard > "Check & repair" (also in each server card's "More" menu). It checks
  about 30 things and repairs what it safely can, after you confirm:
    folders/settings pointing to an old location (moved or renamed server), missing programs,
    libraries or default config files, the Visual C++ runtime, map data, disk space, the
    database service (re-pointed to this folder), the database starting and its login, the
    game databases and key tables, the realm list entry, the admin account used for clean
    stops, auction house sellers, incomplete character records, the config files, outdated
    helper scripts, leftover server processes, ports used by another program, module source
    code, a build folder made for another location, build tools, the app's server list,
    scheduled tasks and desktop shortcuts pointing to old places, the firewall for friends,
    and the AI chatter bridge / model. It never deletes characters. Each run writes a log to
    <server folder>\.creationtool\repair-<date>.log
- An install stops: click "Try again" - it continues where it stopped.
- You closed the app mid-install: open it again and go to "New server"; your choices are kept.
- "Compile failed": close big programs (games, browsers, AI apps) to free memory, try again.
- Every install/update writes a full log to  <server folder>\.creationtool\
- Server logs: <server folder>\server\logs\  (also on the Logs page)


WHAT GETS INSTALLED ON THE PC
-----------------------------
Only what is missing (see the Prerequisites page):
  Visual C++ runtime, Git, CMake, Visual Studio 2022 Build Tools (C++), Boost 1.81 (C:\local),
  OpenSSL 3, Python 3.13 and Ollama (only with AI chatter); optional HeidiSQL and Tailscale.
Each server's MySQL 8.4 is kept inside its own folder and runs as a Windows service named
"AzerothCoreMySQL_<folder>". Your normal Windows account may start/stop that one service
(so the desktop shortcuts never need an admin prompt); it cannot change it.
Every download is verified against a published checksum or a valid digital signature.


FOR MAINTAINERS
---------------
config\versions.json   pinned versions, download links, modules (community ones: "community": true,
                       options a module needs: "config"), addons, AI models
config\extras.json     the Extra settings catalog (plain-language options -> .conf keys)
config\presets.json    built-in presets
ui\Theme.xaml          colours and control styles      ui\App.xaml   window layout
ui\icon.png            app icon
src\App.ps1            window logic. App.ps1 -SelfTest loads and clicks through every page (and the
                       extra windows); set ACC_SHOTS=<folder> to also save screenshots.
                       App.ps1 -TestScript <file> runs a test script with the app loaded.
src\Windows.ps1        Extra settings, Presets and All options windows
src\Dialogs.ps1        item search, copy character, multiple-choice dialog
src\Update.ps1         safe updates, rollback, safety copies, auto-update, make updatable, Discord
src\Headless.ps1       scheduled jobs without a window (-Action AutoUpdate | Events)
src\Manage.ps1         management backend (servers, status, accounts, backups, export/import,
                       config options/overrides, events, performance, items, pdump copy...)
src\Steps.ps1          install/update/import steps, each safe to re-run
src\Prereqs.ps1        prerequisites catalog (detect / verified download / install)
src\Common.ps1         downloads, signatures, process runner, PC detection
Settings model         server-settings.json holds the main settings plus ConfOverrides (options
                       changed in Extra settings / All options / presets, per .conf file) and
                       Events. payload\tools\apply-config.ps1 regenerates every .conf from its .dist
                       + these, so new upstream options appear automatically. Hand edits found in
                       older .conf files are kept as overrides the first time.
Test hooks             <server>\.creationtool\test-fail-compile (module name) / test-fail-health
                       simulate a failing update (development only).
payload\               scripts copied into every server folder
tools\PrereqInstaller\ standalone launcher for the Prerequisites page
