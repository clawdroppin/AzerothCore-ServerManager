# Security

## What the app does on your PC
- It runs as administrator, so it can install prerequisites, register each server's MySQL service and manage
  firewall rules.
- Installers come from official sources and are verified (Authenticode signature and/or SHA-256) before they run
  (see `src/Prereqs.ps1`). Source code is cloned with git from the repositories listed in `config/versions.json`.
- Each server's MySQL listens on **127.0.0.1 only**. The game ports (3724, 8085) are opened in the firewall only
  when you set up *Play with friends*, and only for private networks unless you choose otherwise.
- Admin commands (SOAP, port 7878) are bound to localhost and use a random password stored in `secrets\soap.txt`.
- Passwords stay in each server's `secrets\` folder and are only included in exports when you tick that option.
  *Copy report* never includes them.

## Reporting a vulnerability
Please don't open a public issue for security problems. Use GitHub's
**[private vulnerability reporting](https://github.com/clawdroppin/AzerothCore-ServerManager/security/advisories/new)**
instead. We'll respond as soon as we can.
