# Architecture and decisions

## Environment

Only the Xcode Command Line Tools are installed on the build machine (no Xcode.app), so the project is a
Swift Package rather than an `.xcodeproj`:

* `WorkdayCore` (library) — domain model, calendar math, SQLite persistence, the time-accounting ledger,
  recovery, backups, goals/streaks/reminder planning. No UI. Fully unit-tested.
* `Workday` (executable) — AppKit lifecycle (`NSApplicationDelegate`, `NSStatusItem`, `NSPopover`, `NSWindow`)
  hosting SwiftUI views; liquid rendering; notifications; launch at login.
* `WorkdayCoreTests` — Swift Testing suite (`./scripts/test.sh` adds the CLT Testing framework search paths).
* `scripts/build_app.sh` assembles `dist/Workday.app` (Info.plist with `LSUIElement`, icon, universal `lipo`, ad-hoc `codesign`).

Minimum macOS 14 (needed for the Observation framework and modern SwiftUI APIs). No third-party dependencies.

## Module map

| Concern | Location |
|---|---|
| Session model, states, checkpoints | `Sources/WorkdayCore/WorkSession.swift` |
| Date keys, month grid layout | `Sources/WorkdayCore/DayKey.swift` |
| Midnight slicing, formatting, liquid scale | `Sources/WorkdayCore/TimeMath.swift` |
| SQLite wrapper / store / schema & migrations | `Sources/WorkdayCore/SQLite.swift`, `WorkStore.swift` |
| Single time-accounting service (start/stop, edits, recovery, totals) | `Sources/WorkdayCore/WorkLedger.swift` |
| Streaks, month summary, reminder planning | `Sources/WorkdayCore/GoalsAndReminders.swift` |
| Backups, paths, single-instance lock | `Sources/WorkdayCore/BackupManager.swift` |
| App lifecycle, Dock policy, OS signals, timers, menu | `Sources/Workday/AppDelegate.swift` |
| Menu bar item / popover | `Sources/Workday/StatusItem.swift`, `MenuPopoverView.swift` |
| Liquid renderer | `Sources/Workday/Liquid.swift` |
| Month / year calendar | `Sources/Workday/CalendarViews.swift` |
| Day editor | `Sources/Workday/DayEditorView.swift` |
| Recovery panel | `Sources/Workday/RecoveryView.swift` |
| Settings (goal, login item, notifications, backups, privacy) | `Sources/Workday/SettingsView.swift` |
| Notifications, launch at login | `Sources/Workday/Services.swift` |

## Time accounting

* The only stored truth is a list of sessions: absolute `start`/`end` instants (`Date`, seconds since reference
  date as `REAL`), a state (`active`, `closed`, `interrupted`), the last trustworthy checkpoint and the time zone
  identifier in effect when recorded.
* `WorkLedger` is the single service every view reads. Per-day totals are derived by splitting each interval at
  local midnight (`TimeMath.slices`). Closed and interrupted (confirmed part) totals are cached and rebuilt on every
  change; the running session's contribution is computed on demand from its start to `now`. UI ticks never accrue
  time, so throttled timers or sleep can't lose or add work.
* Start is idempotent (a running session is returned unchanged). Stop writes the real stop instant. A zero-length
  stop is discarded instead of stored.
* Overlaps are rejected: a running session reserves `[start, ∞)`, an interrupted session reserves up to its
  relaunch time, so a pending gap can never be double counted. Touching endpoints are allowed.
* Manual sessions must end after they start, last at least one minute and not end in the future (60 s tolerance
  for minute-precision pickers). The running session can't be edited (Stop first); it can be discarded via delete
  with confirmation.

### Time zone and DST policy

Durations are always absolute elapsed seconds. Dates are partitioned using the Mac's **current** calendar and
time zone (`Calendar.autoupdatingCurrent`), recomputed when the system time zone, locale or day changes. A DST
transition therefore makes a local day 23 h or 25 h long but never changes recorded work; after travelling, past
sessions are shown on the dates they fall on in the current zone. Each session also stores the zone it was recorded
in for future reinterpretation if ever needed.

## Sleep vs. termination (recovery)

* While running, the app writes a checkpoint every 30 s, on `willSleep`, on `didWake`, and on `willPowerOff`
  (kind `shutdown`, exact).
* Sleep: the process survives, so on wake the session simply continues and sleep time counts (no prompt).
* Crash / force quit / power loss / reboot: on the next launch any session still `active` belongs to a dead process
  (a `flock` single-instance lock guarantees no other live instance owns it), so it becomes `interrupted` with
  `detectedAt = launch`. Confirmed time = start → checkpoint; the gap checkpoint → relaunch is shown as pending and
  is never counted until the user decides: **Exclude**, **Count**, or **Custom** (exact stop time, optional resume
  time). "Keep the timer running" continues from the relaunch. Resolution re-reads the row inside one transaction,
  so it is atomic and idempotent across windows and relaunches.
* Quitting from the menu while running asks to stop first; a system shutdown is recorded as an exact `shutdown`
  checkpoint and reviewed on next launch (the spec treats shutdown as an interruption).
* Pending recovery shows a red dot on the menu bar glyph, a banner in the popover/calendar/editor, and a floating
  recovery panel at launch — the calendar is not forced open and no Dock icon appears.

## Goals, streaks, notifications

* One goal (default 8 h, 15 min–24 h) for every day. It never changes the 18 h liquid scale.
* Streak: consecutive days meeting the **current** goal; today counts once met but never breaks the streak while in
  progress; weekends count. Disclosed in Settings.
* `ReminderPlanner` (pure, tested) decides due notifications; the `notifications_sent(day, kind)` table guarantees
  each fires at most once per local day across redraws and restarts. Start reminder fires within 3 h of the chosen
  time if the timer isn't running; stop/check-in reminder fires once after the chosen time while running.
* Permission is requested only when a notification feature is enabled; denial is handled gracefully.

## Backups

SQLite online backup API into a `.partial` file → `journal_mode=DELETE` → `PRAGMA integrity_check` + schema check →
atomic rename. Daily automatic snapshot when `data_revision` changed (checked at launch, hourly, and on wake);
retention 30 automatic / 20 manual / 10 safety. Restore validates first, takes a safety copy, copies into the live
database in one SQLite write transaction, rolls back to the safety copy on failure, re-runs migrations and
interruption detection. Corrupt or truncated files are listed as unusable and cannot be restored.
Restore is disabled while the timer runs.

## Liquid rendering and performance

* One `Canvas` per month grid (and per mini month in the year view) draws all tiles in a single pass, driven by one
  `TimelineView`; text and interaction are lightweight SwiftUI overlays.
* Each tile: tile base, back wave (offset phase), gradient front wave, side gloss, lit meniscus, glass highlight.
  Live days get rising bubbles; > 18 h days stay full and add an outer glow, bright rim, foam along the brim,
  sparkles and an icon — the exact hours stay printed.
* Motion: fill changes animate with a damped settle and trigger a slosh impulse; hovering a tile sloshes it.
* Cadence: ≤ 40 fps while the calendar is key (20 fps for the compact year tiles), 8 fps when visible but inactive,
  paused when hidden/occluded/minimised. **Reduce Motion** pauses the timeline and draws flat, still liquid with the
  same data.
* Text on liquid switches to a dark brown (`Theme.onLiquid`) that contrasts with orange in both appearances.
