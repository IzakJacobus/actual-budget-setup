# Actual Budget Setup for Windows

A double-click installer that runs your own private [Actual Budget](https://actualbudget.org) server on a Windows 11 laptop.
Use it from your phone anywhere, over HTTPS, through [Tailscale](https://tailscale.com).

> This is an unofficial helper. It is not made by or affiliated with the Actual Budget project.
> It installs the official `@actual-app/sync-server` package from npm.

## What you get

- The server starts automatically and invisibly when you sign in to Windows, and restarts itself if it crashes.
- Daily backups, plus a backup each time the server starts. The newest 30 are kept.
- Phone access at home and away via Tailscale HTTPS. Only your own devices can reach it.
- No router ports, no firewall changes, and nothing is exposed to the public internet.
- Uninstall removes the autostart but never deletes your data or backups.

## Install

1. **Download:** click **Code → Download ZIP** (or get the zip from **Releases**), then unzip it.
2. **Read:** open **READ ME FIRST.txt**.
3. **Run:** double-click **Install.cmd**.

## Requirements

- Windows 11 with winget, which Windows 11 includes.
- A free [Tailscale](https://tailscale.com) account, for phone access.
- The installer offers to install Node.js LTS and Tailscale if they're missing.

## Files

| File | Purpose |
|---|---|
| `Install.cmd` | Installs everything into `C:\actual-server` |
| `Uninstall.cmd` | Removes autostart, backups task and phone access (keeps your data) |
| `READ ME FIRST.txt` | Short step-by-step guide |
| `program\` | The PowerShell scripts that do the work (backup, restore, update, start/stop) |
