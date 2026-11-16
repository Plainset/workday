# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- "This week" total in the calendar summary (current week, starting on your Mac's first weekday).
- Optional sync between your own Macs through a shared folder — by default *Workday Sync* in iCloud Drive. No
  account or server. Sessions, edits, deletions, the running timer, the daily goal, reminders and "goal reached"
  notifications appear on every Mac. A timer running on another Mac shows as "Running on …" with
  *Stop There & Start Here*. Overlapping sessions recorded on two Macs are listed under Settings → Sync →
  Sync conflicts (keep one or merge) and counted once until resolved. Off by default; a safety backup is made when
  it is turned on. Restoring a backup rolls back only this Mac's own sessions. `scripts/sync_e2e.sh` checks two
  real instances against a temporary folder.

### Changed
- Database schema v2: each session records the Mac that owns it, plus a sync version table. Upgrades in place;
  v1 backups still restore.
- Crash recovery only reviews sessions that were running on this Mac.
- `scripts/build_app.sh` works with SwiftPM versions that put every architecture's build in one folder.
- Privacy statement updated for optional sync (README, PRIVACY.md, Settings → Data & Privacy).
- Lower memory use: closed windows and the menu bar popover are now released completely, the running day redraws only
  its own tile, and freed memory is returned to macOS. Includes a `--memtest` harness for leak checks.

## [1.0.0] — 2026-10-24

First public release. Fully offline.

### Added
- Menu bar timer with Start/Stop, today's total, live session time, goal progress and streak.
- Month calendar with animated orange-liquid tiles (0 h empty, 18 h full, overflow beyond) and a twelve-month
  overview; Reduce Motion support; light and dark appearance.
- Day editor: add, edit and delete sessions with validation and cross-midnight previews.
- Crash and shutdown recovery with count / exclude / custom decisions; sleep counted while timing.
- Daily goal, streaks, goal-reached notification and optional start/stop reminders.
- Automatic daily local backups with validation, retention and restore.
- Launch at login; Dock icon only while a window is open.
- VoiceOver labels and keyboard navigation for the calendar.
- Release packaging (ZIP + DMG + checksums) with optional Developer ID signing and notarisation.

### Security
- Data folder, database, backups and lock file created owner-only (0700/0600); files from earlier builds are
  tightened on launch.

### Upgrading from a pre-release build
- The bundle identifier is now `io.github.plainset.workday`. Your work data is untouched. Launch at login is
  switched on once under the new identifier — if you had turned it off, turn it off again in Settings → General —
  and any stale "Workday" entry in System Settings → General → Login Items can be removed. macOS asks for
  notification permission again and window positions reset once.

[1.0.0]: https://github.com/Plainset/workday/releases/tag/v1.0.0
