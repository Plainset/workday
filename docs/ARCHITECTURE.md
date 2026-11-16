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
| Liquid animation state (fill transitions, slosh, calm/wake) | `Sources/WorkdayCore/LiquidMotion.swift` (unit-tested) |
| Liquid renderer | `Sources/Workday/Liquid.swift` |
| Month / year calendar | `Sources/Workday/CalendarViews.swift` |
| Day editor | `Sources/Workday/DayEditorView.swift` |
| Recovery panel | `Sources/Workday/RecoveryView.swift` |
| Settings (goal, login item, notifications, backups, sync, privacy) | `Sources/Workday/SettingsView.swift` |
| Sync format, clock, merge engine | `Sources/WorkdayCore/Sync/SyncModel.swift`, `SyncEngine.swift` |
| Sync scheduling and status | `Sources/Workday/SyncController.swift` |
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
  checkpoint and reviewed on next launch (the spec treats shutdown as an interruption). If a logout/shutdown is
  cancelled, the quit confirmation re-arms after 90 s.
* "Keep the timer running" after a decision: within 5 minutes of the relaunch it continues from the relaunch;
  later, the default starts a new interval *now*, and counting from the relaunch is an explicit option showing the
  exact time it adds.
* Stopping when the clock has moved before the session start is refused (nothing is discarded).
* Pending recovery shows a red dot on the menu bar glyph, a banner in the popover/calendar/editor, and a floating
  recovery panel at launch — the calendar is not forced open and no Dock icon appears.

## Goals, streaks, notifications

* One goal (default 8 h, 15 min–24 h) for every day. It never changes the 18 h liquid scale.
* Streak: consecutive days meeting the **current** goal; today counts once met but never breaks the streak while in
  progress; weekends count. Disclosed in Settings.
* `ReminderPlanner` (pure, tested) decides due notifications; the `notifications_sent(day, kind)` table guarantees
  each fires at most once per local day across redraws and restarts. Start reminder fires within 3 h of the chosen
  time if the timer isn't running; stop/check-in reminder fires once after the chosen time while running.
* Permission is requested once when any notification feature is enabled — the goal notice is on by default, so a
  fresh install asks at first launch (`NotificationPermissionPolicy`). Denial is handled gracefully.
* The check-in reminder only fires for a session that was already running at the chosen time.
* A restore keeps the record of notifications already delivered, so it never re-fires today's goal notice.

## Backups

SQLite online backup API into a `.partial` file → `journal_mode=DELETE` → `PRAGMA integrity_check` + schema check →
atomic rename. Daily automatic snapshot when `data_revision` changed (checked at launch, hourly, and on wake);
retention 30 automatic / 20 manual / 10 safety. Restore validates first, takes a safety copy, copies into the live
database in one SQLite write transaction, rolls back to the safety copy on failure, re-runs migrations and
interruption detection. Corrupt or truncated files are listed as unusable and cannot be restored.
Restore is disabled while the timer runs.

## Sync between Macs

Optional, off by default (Settings → Sync). There is no server and no Workday account: the "account" is whatever
keeps a folder in sync between the owner's Macs — normally iCloud Drive under one Apple ID, or an iCloud Drive
folder shared between two Apple IDs, but any folder kept in sync by another tool works.

**Each Mac keeps its own SQLite database** as the source of truth for its UI. The live database is never put in
the sync folder; Macs exchange change records instead.

### Folder layout (one writer per file)

```
<folder>/Workday Sync/devices/<deviceID>/device.json          {format, device, name, epoch, seq, updatedAt}
<folder>/Workday Sync/devices/<deviceID>/log-<firstSeq>.jsonl  one immutable batch of records, JSON Lines
<folder>/Workday Sync/devices/<deviceID>/snapshot.json         {format, device, epoch, seq, createdAt, records}
```

* `deviceID` is a random UUID created once (`meta.device_id`); it is never derived from hardware or the account.
* A Mac writes only inside its own folder. Every file is written to a `.tmp-…` file (0600) and renamed into
  place, so readers and iCloud only see complete files. Log files are never rewritten.
* Each pass that has local changes writes one new `log-<firstSeq>.jsonl`; records are numbered by a per-device
  sequence (`meta.sync_seq`). When 64 log files exist (and whenever a Mac starts in a new folder) they are folded
  into `snapshot.json` and deleted. A snapshot holds the full merged state with each record's original clock.
* Each Mac stores how far it has applied every peer as `meta.sync_cursor_<peer> = "<epoch>:<seq>"`. A new epoch
  (the peer started over, e.g. in a new folder) resets the cursor; a cursor before the peer's first log file
  reads its snapshot first.
* Reading tolerates iCloud: a placeholder (`.<name>.icloud`) triggers `startDownloadingUbiquitousItem` and the
  pass waits for it; a last line without a newline (a half-synced file) is not applied until complete.

### Records and merge rules

| Kind | Key | Merge |
|---|---|---|
| `session` | session UUID | last writer wins on the whole session |
| `tombstone` | session UUID | a delete; wins over any older edit, loses to a newer one |
| `setting` | field name | last writer wins per field (`dailyGoalMinutes`, goal notification, start/stop reminder flags and times) |
| `notified` | day + kind | grow-only set, so "goal reached" is shown once per day across Macs (best effort) |
| `checkpoint` | session UUID | advisory: moves a still-running session of the sending Mac forward; never an edit |

* **Clock**: every record carries a hybrid logical clock `wall(ms)-counter-deviceID`, compared in that order. A Mac
  never issues a clock below the largest it has seen, so an edit made after seeing another Mac's edit always wins
  even if this Mac's wall clock is behind. Records more than a year ahead of this Mac's clock are held (the cursor
  stops before them and Settings asks to check the date); records of a kind, setting or format this version
  doesn't know are held the same way until Workday is updated, never skipped for good.
* **Finding local changes**: `sync_versions(entity, key, hlc, hash, deleted)` holds the last synced version of every
  record. A pass compares the database with it (sessions and settings only when `data_revision` changed): a new
  or changed row gets a fresh clock, a row that vanished becomes a tombstone. All write paths — timer, editor,
  recovery, conflict resolution, restore — are therefore published the same way. Sessions never synced before
  use their own `updated_at` as the clock; a Mac joining a folder that already has other Macs adopts their settings.
* **Applying** is idempotent: a record is applied only if its clock is newer than the stored version, so
  re-reading a log, out-of-order arrival and snapshots overlapping logs are harmless. Each pass publishes before it
  imports, so local edits are clocked before anything is merged.
* **Untrusted input**: files are read only as regular files (`O_NOFOLLOW`, `fstat`), at most 16 MB per file and
  4 KB per line; links inside the sync tree are refused; bootstrap deletes only the engine's own file names.
  Every field is bounded (UUIDs, instants 2000–2100, end after start, finished sessions ≤ 400 days, enums, time
  zone text, setting ranges, sequence numbers ≤ 2^53); a malformed record is skipped and reported, never run.
* **Identity checks**: if this Mac's own `device.json` carries an epoch it didn't write, another Mac shares its
  identity (a database copied by Migration Assistant), so it takes a new `device_id` and starts a fresh log. If
  that file is ahead of `meta.sync_seq`, the database went back in time and the Mac also starts a fresh log.
* **Restore**: a backup restored while sync is on rolls back only this Mac's own sessions (republished as new edits).
  Versions of sessions another Mac owns are dropped and every peer is read again, so their current state returns.

### Running timer across Macs

* Schema v2 adds `sessions.owner_device`; existing rows belong to the local device.
* Only the owning Mac treats an active session as its timer: `activeSession`, `detectInterruptions` and recovery
  ignore other Macs' sessions (the Mini never sees the laptop's heartbeats, so it must never flag them).
* Another Mac's running session shows as "Running on <name>" with its live elapsed time and counts toward totals.
  Starting while it runs offers **Stop It There and Start Here** (`stopRemoteAndStart`): an edit that ends the
  remote session now, which then stops the timer on that Mac when it syncs.
* Heartbeats stay local (every 30 s); a `checkpoint` record is shared at most every 10 minutes. Another Mac's
  running session counts toward totals only up to 30 minutes past its last shared checkpoint, so a Mac that went to
  sleep or offline doesn't inflate totals here. A crashed remote session is recovered on its own Mac at its next
  launch, and the result syncs back.

### Overlaps and totals

Two Macs can hold overlapping sessions (the same hours logged on both before sync, or both started while
offline). They are imported, never deleted automatically, and listed under Settings → Sync → **Sync conflicts**,
where the owner keeps one or merges them into one. Until then, day and week totals count the **union** of all
sessions' time (`WorkLedger.union`; running sessions add only time not already covered), so no minute is counted
twice. The editor still refuses to *create* overlaps.
Keeping one or merging is published as one decision (the kept session and the other's deletion share one clock),
so if both Macs settle the same overlap differently while offline, the later decision wins whole.

### Lifecycle

* Turning sync on makes a `safety` backup, then publishes the full local history and imports the other Macs.
* Passes run at launch, on wake, every 45 s while on, and 2 s after a local change (debounced). Idle cost is a
  directory listing and a few small reads; nothing runs when sync is off, and there is no per-second disk work.
* Turning sync off stops all reading and writing and keeps local data. Choosing a different folder publishes
  everything there again.
* A restore keeps the sync bookkeeping (`device_id`, `sync_*` meta, `sync_versions` for this Mac's own sessions),
  so this Mac's restored sessions are published as new edits rather than being overwritten by the other Macs.

## Liquid rendering and performance

* One `Canvas` per month grid (and per mini month in the year view) draws all tiles in a single pass, driven by one
  `TimelineView`; text and interaction are lightweight SwiftUI overlays.
* Each tile: tile base, back wave (offset phase), gradient front wave, side gloss, lit meniscus, glass highlight.
  Live days get rising bubbles; > 18 h days stay full and add an outer glow, bright rim, foam along the brim,
  sparkles and an icon — the exact hours stay printed.
* Motion: fill changes animate with a damped settle and trigger a slosh impulse; hovering a tile sloshes it.
* Cadence: each liquid layer runs a structured `.task(id:)` loop that wakes every ~33 ms (so hover, keys or data
  changes respond immediately) but only produces a frame when the interval chosen by `liquidInterval` has elapsed:
  30 fps while a fill transition or slosh is settling; 12 fps for the live tile's bubbles (its own one-tile layer);
  a 10 fps idle drift while the user is engaged. 30 s after the last interaction the idle waves ease to a flat,
  still surface over 2.5 s and no more frames are drawn until the next interaction, when they ramp back up over
  0.8 s. Year tiles hold still unless sloshed. Non-key windows use slower rates; hidden/occluded/minimised windows
  and **Reduce Motion** draw one still frame and run no loop. The loop is cancelled when the layer disappears.
  (SwiftUI's `TimelineView` was measured redrawing near display rate regardless of its schedule, so it is not used.)
* The month view draws the running day's tile in its own small layer, so bubbles don't redraw the other 41 tiles.
  Tiny fill changes (the live minute ticking over) apply quietly without a slosh.
* The year view draws all 365 tiles with one batched Canvas (`CompactLiquidPainter`: a handful of draw calls),
  day numbers in one static Canvas per month, and one hover/click surface per month with per-day
  accessibility children — so animation frames don't re-walk hundreds of views. Its grid picks 6×2 / 4×3 / 3×4 /
  2×6 to maximise tile size and scrolls (never truncating day numbers) when tiles would be smaller than 14 pt.
* Month tile labels are drawn inside the liquid Canvas as symbols: normal colours clipped to above the exact wave
  path of the current frame, dark-on-orange clipped to below it — legible through pour-in, slosh and hover growth.
* The popover's SwiftUI content exists only while it is open; the display clock ticks every second only while the
  popover is visible, otherwise once a minute.
* Measured CPU (`scripts/perf.sh`, one process per scenario, % of one core, Apple Silicon): see
  `evidence/latest/perf.txt`.
* Reduce Motion also replaces slide/spring navigation with short cross-fades and disables hover growth and slosh.
* Text sizes are fixed points tuned for the tile grid with `minimumScaleFactor` fallbacks; macOS has no system-wide
  Dynamic Type for AppKit apps, so large-text support relies on window resizing (tiles grow with the window) and the
  system's display scaling. Settings/editor forms use standard controls that follow system font settings.
