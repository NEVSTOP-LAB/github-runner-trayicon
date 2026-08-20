# runner-trayicon-backup

Backup of a Windows tray tool for local GitHub Actions runner management.

## Files

- [runner-tray.ps1](C:/actions-runner/runner-trayicon-backup/runner-tray.ps1): tray app, runner control, log windows, single-instance guard
- [runner-tray.cmd](C:/actions-runner/runner-trayicon-backup/runner-tray.cmd): quick launcher
- [run.md](C:/actions-runner/runner-trayicon-backup/run.md): usage notes (Chinese)

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\runner-tray.ps1
```
