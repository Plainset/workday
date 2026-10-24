# Privacy

Workday 1.x is an **offline application**. It has no accounts, no servers, no analytics, no crash reporting and no
network code.

## What Workday stores, and where

All data lives in your user account on your Mac:

| Data | Location |
|---|---|
| Work sessions (start/end instants, time zone), settings, daily goal, notification bookkeeping, an audit log of Start/Stop/edit actions | `~/Library/Application Support/Workday/workday.sqlite` (+ `-wal`/`-shm`) |
| Automatic, manual and pre-restore backups of that database | `~/Library/Application Support/Workday/Backups/` |
| Window positions | macOS user defaults for `local.workday.tracker` |
| Login-item registration and notification permission | managed by macOS |

The data folder and files are created readable only by your user account (0700 / 0600).

Workday does **not** record which apps you use, websites you visit, your keystrokes, your location or idle time.
Time is counted only between your own **Start** and **Stop**.

## What leaves your Mac

Nothing. Workday makes no network connections. Notifications are delivered locally by macOS.

## Removing your data

Quit Workday, delete `/Applications/Workday.app`, and delete `~/Library/Application Support/Workday/`.
Remove the login item in System Settings → General → Login Items if it is still listed.

## Future online features

Any future optional online feature (such as sharing daily totals with friends) will be opt-in, will never be
required to use the app, and will be documented here before release.
