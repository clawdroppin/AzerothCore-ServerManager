# CLAUDE.md

Read **[AGENTS.md](AGENTS.md)**: it is the full guide for working on this project (architecture, conventions,
PowerShell 5.1 pitfalls, testing).

The non-negotiables, in short:

- Never start, stop, update, repair or write to a user's real server while testing. Use a test server.
- Windows PowerShell **5.1** syntax only. UTF-8 **with BOM** for files containing non-ASCII. CRLF line endings.
- Long work goes through `Start-BgTask`. Nested closures need `$x = $x`, and handlers need `.GetNewClosure()`.
- Before committing: `tools\dev\Invoke-StaticChecks.ps1` passes and `src\App.ps1 -SelfTest` reports 0 errors.
