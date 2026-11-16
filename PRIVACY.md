# Privacy

Workday is an **offline application**. It has no accounts, no servers, no analytics, no crash reporting and no
network code. Optional sync between your own Macs works through a folder you choose and is **off by default**.

## What Workday stores, and where

All data lives in your user account on your Mac:

| Data | Location |
|---|---|
| Work sessions (start/end instants, time zone), settings, daily goal, notification bookkeeping, an audit log of Start/Stop/edit actions | `~/Library/Application Support/Workday/workday.sqlite` (+ `-wal`/`-shm`) |
| Automatic, manual and pre-restore backups of that database | `~/Library/Application Support/Workday/Backups/` |
| Window positions | macOS user defaults for `io.github.plainset.workday` |
| Login-item registration and notification permission | managed by macOS |
| Only if you turn on sync: change records of the data above (sessions, deletions, synced settings, notifications already shown) and each Mac's chosen name | `<folder you choose>/Workday Sync/devices/<random device ID>/` — by default in your iCloud Drive |

The data folder and files are created readable only by your user account (0700 / 0600).

Workday does **not** record which apps you use, websites you visit, your keystrokes, your location or idle time.
Time is counted only between your own **Start** and **Stop**.

## What leaves your Mac

With sync off (the default): nothing. Workday makes no network connections. Notifications are delivered locally by
macOS.

With sync on: Workday writes change files into the folder you picked and reads your other Macs' files from it.
Workday itself still makes no network connections — the folder is copied between your Macs by whatever keeps it in
sync, normally iCloud Drive under your Apple ID (so Apple's iCloud terms apply to those files). Nothing is sent to
the Workday project or any other server. The files contain your session times, time zones, synced settings (daily
goal, reminder choices), the days a notification was shown, a random device ID and the name you give each Mac.
They don't contain your audit log, backups, window positions or login-item choice. Sync files are created
readable only by your user account. Records read from the folder are validated and malformed ones are skipped;
nothing in them is ever run.

Turning sync off stops all reading and writing and keeps your data on this Mac. To remove synced copies, delete the
`Workday Sync` folder from the sync folder (for example in iCloud Drive) on any Mac.

## Removing your data

Quit Workday, delete `/Applications/Workday.app`, and delete `~/Library/Application Support/Workday/`. If you used
sync, also delete the `Workday Sync` folder (for example from iCloud Drive).
Remove the login item in System Settings → General → Login Items if it is still listed.

## Future online features

Any future optional online feature beyond folder sync (such as sharing daily totals with friends) will be opt-in, will never be
required to use the app, and will be documented here before release.
