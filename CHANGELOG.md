# Changelog

All notable changes to this project. The format follows [Keep a Changelog](https://keepachangelog.com) and
versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

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
