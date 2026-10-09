# Contributing

Thanks for helping! Bug reports, ideas, modules, presets, translations of the plain-language texts and code are
all welcome.

## Getting started
1. Fork and clone the repo. There's nothing to build: the app is PowerShell 5.1 + WPF.
2. Run it: `AzerothCoreCreationTool.bat` (it asks for admin).
3. **Make a disposable test server** with the wizard (for example 100 bots in `S:\AzerothCoreToolTest`). Test
   everything that starts, stops or writes against that server, never against a server you play on.
4. Read **[AGENTS.md](AGENTS.md)**. It explains the architecture and the PowerShell 5.1 pitfalls we've already
   hit, so you won't hit them again.

## Before you open a pull request
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev\Invoke-StaticChecks.ps1      # must pass
powershell -NoProfile -STA -ExecutionPolicy Bypass -File src\App.ps1 -SelfTest            # 0 errors expected
```
- Keep files UTF-8 **with BOM** when they contain non-ASCII characters, and keep CRLF line endings
  (`.gitattributes` stops git from converting them).
- Update `README.md`, `README.txt` (the manual shipped with the app) and `AGENTS.md` when behaviour changes.
- Add a line to `CHANGELOG.md` under *Unreleased*.

## Easy first contributions
- A new **preset** (`config/presets.json`) or **Extra setting** (`config/extras.json`): JSON only, no code.
- A new **community module** entry (`config/versions.json`), tested on a test server.
- A new **Check & repair** check (`src/Repair.ps1`) for a problem you ran into.

## Releasing (maintainers)
1. Bump `version` in `config/app.json` (semver) and move *Unreleased* in `CHANGELOG.md` to the new version.
2. Run the static checks and the self-test.
3. Commit, tag and push: `git tag v1.2.3 && git push origin main --tags`.
4. Build the zip from the tag (keeps bytes exact and leaves out docs/.github):
   `git archive --format=zip --prefix=AzerothCore-ServerManager/ -o dist/AzerothCore-ServerManager-v1.2.3.zip v1.2.3`
5. `gh release create v1.2.3 dist/AzerothCore-ServerManager-v1.2.3.zip --title "v1.2.3" --notes-file <notes>`

Installed apps find the new release through **Help & about → Check for app updates**, which reads the GitHub
"latest release".
