# Changelog

All notable changes to this project. The format follows [Keep a Changelog](https://keepachangelog.com) and
versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

## [1.0.3] - 2026-10-09
### Added
- Check & repair reports options a server version doesn't recognise (written by the config writer to
  `tools\config-unknown.txt`), so a future rename by a module shows up instead of silently doing nothing.
- **PTR Character Templates** module ([mod-ptr-template](https://github.com/azerothcore/mod-ptr-template)), optional
  under Updates → Modules: Blizzard's public-test-realm premade characters. `.template list` and
  `.template apply <number>` turn a character into a ready-to-play Wrath Classic level 80 (or 70) with gear, spells,
  skills, flight paths and reputations. Level 60 Classic sets are included and can be enabled by an admin.

### Fixed
- **The number of bots (and every other bot option) had no effect on newly built servers.** Playerbots renamed all
  its options from `AiPlayerbot.X` to `Playerbots.X`; the app wrote the old names, which the new version ignores.
  The config writer now uses whichever names the server's Playerbots version has, so old and new servers both work.
- Changing a value in World settings (or a preset / the Performance suggestion) now removes older Extra settings or
  All options overrides of the same option, which would otherwise silently win.
- Bot guild-chat chatter is now silenced with an option that exists in every Playerbots version (one was removed).
- Switching servers (or Players/Bots) while a list was still loading could show the previous selection's results;
  accounts, characters, network info, update check and the level chart now ignore stale results.
- A finished install could end up missing from the app's server list. The installer now verifies the entry and logs
  it, and the app re-adds a finished install that is missing at startup (unless you removed it on purpose).

## [1.0.2] - 2026-10-09
### Fixed
- **Presets → Apply crashed the app** (every preset). The button handler read the selected server through a
  variable that a closure cannot see, got an empty path, and the unhandled error closed the app.
- The same mistake silently broke a few other spots: the bot level chart refresh, the Performance page refresh,
  refreshing the Updates page after an update or recompile, the "pinned" note on the Updates page, and
  "Free up space" on the server card.

### Added
- Safety net: an unexpected error in a button handler now shows a message and is logged to
  `%LOCALAPPDATA%\AzerothCoreCreationTool\app-errors.log` instead of closing the app.
- Static check 7 in `tools\dev\Invoke-StaticChecks.ps1` catches `$script:` variables used inside closures.

## [1.0.1] - 2026-10-09
### Added
- **Database port choice** when creating a server: a *shared port* (recommended; every server uses the same database
  port and starting one swaps its database in automatically) or *its own port* (its database can stay available while
  another server runs). Imported servers use the shared port. The database port never needs port forwarding.
- Every connection to a database (app, START/STOP scripts, scheduled backups, install steps) checks that it reached
  the right server's data, so a shared port can never read or change another server's characters.

### Fixed
- The wizard could suggest a database port that already belonged to another (stopped) server.
- A resumed install (for example after a reboot) now starts the new server's database before continuing.

## [1.0.0] - 2026-10-09
First public release.

### Create
- Four-step wizard that builds a complete AzerothCore 3.3.5a + Playerbots server: silent, verified prerequisite
  installs, a private MySQL 8.4 per server, RAM-aware compiling, database import, shared map data, config
  generation, accounts, realmlist and desktop shortcuts. Every step can be resumed.
- Import from a `.wowserver` package (no compiling) or add an existing AzerothCore folder (hand edits kept).

### Manage
- Dashboard (players, bots, tick graph, health check, services, quick actions), console, accounts, characters
  and bots (kick, teleport, level, mail gold, searchable **Mail item**, **copy a character to another server**).
- World settings plus **Extra settings** (100+ plain-language options), **Presets** (8 built-in, shareable user
  presets) and **All options** (every conf key, with descriptions; survives updates).
- Backups: daily, save points, extra copy on another drive, restore, delete. Daily restart with warning. Timed
  events (double XP weekend...).
- Play with friends (LAN / Tailscale / port forwarding, firewall rules, join kit) and Discord notifications.
- AI bot chat through Ollama (model picker, download, test). Performance page with a suggested bot count.

### Update & repair
- **Safe updates**: changelog per component, compile while running, full safety copy, health check, automatic
  rollback, module-compatibility choices, safety copies you can delete, auto-update, pinning, "make updatable"
  for moved servers.
- Modules on a switch through the same pipeline, plus 11 community modules.
- **Recompile** and **clean recompile** with the same safety net. A moved server folder no longer breaks compiling.
- **Check & repair**: about 30 checks with one-click fixes and a copyable report.
- **Check for app updates** on Help & about (and a quiet daily check).

### Fixed during the final test pass
- Mail item's search results never reached the list (nested closure capture).
- Presets showed a false "Could not apply" after applying successfully.
- A user PATH containing `%PATH%` made the app's PATH double on every background task until every task failed
  with "Environment variable name or value is too long".
- The server list could be overwritten with an incomplete list if read while another window was writing it
  (now atomic with a backup).
- Auction-house seller characters were created with an empty flight-path record, which broke character copies.
