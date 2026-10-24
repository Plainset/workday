# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/Plainset/workday/releases/tag/v1.0.0
