# Workday — native macOS work-hours tracker

A local-only, menu-bar-first work timer whose calendar shows every day as a tile of animated orange liquid
(empty at 0 h, full at 18 h, glowing overflow beyond 18 h). Built with Swift, SwiftUI and AppKit.
No accounts, no network, no third-party dependencies.

## Requirements

| | |
|---|---|
| macOS | 14 Sonoma or later (developed and tested on macOS 26.6, Apple Silicon) |
| Architectures | Universal binary: arm64 + x86_64 |
| Toolchain | Swift 6.x (language mode 5). Either full Xcode **or** just the Command Line Tools (`xcode-select --install`). Built here with Swift 6.3.3 / CLT, macOS 26.5 SDK |

## Build, test, install

```bash
./scripts/test.sh
```

```bash
./scripts/build_app.sh
```

Produces `dist/Workday.app` (universal, ad-hoc signed). Set `ARM64_ONLY=1` to skip the Intel slice.

```bash
./scripts/install.sh
```

Copies the app to `/Applications` (or `~/Applications` if `/Applications` isn't writable) and launches it.

On first launch Workday opens the calendar once, registers itself as a login item and lives in the menu bar.
After that it starts silently at login (menu bar only, no Dock icon, no window).

### One-time approvals you may be asked for

* **Login item** — macOS may show "Workday added to Login Items" or require approval in
  *System Settings → General → Login Items*. Settings → General shows the current state and links there.
* **Notifications** — requested only when you enable a notification feature (goal reached is on by default,
  so the prompt appears the first time Workday evaluates it). If denied, Workday keeps working and
  Settings → Notifications explains how to re-enable.
* **Gatekeeper** — the app is ad-hoc signed (no paid developer ID). If you copy it to another Mac, right-click → Open the first time.

## Using it

* **Menu bar**: a small orange glass (filled to today's goal progress) and today's total, e.g. `6:35`.
  Click for status (Running/Stopped), live session time, goal progress, streak, **Start Work / Stop Work**, Calendar, Settings, Quit.
  A red dot on the glass means an interrupted session needs review.
* **Calendar** (⌘0 from the Window menu, or the menu bar): month view by default; Year shows twelve mini months.
  Click any day (or use arrow keys + Return) to open its editor. ⌘← / ⌘→ navigate, ⌘T jumps to today, ⌘1 / ⌘2 switch Month / Year.
* **Day editor**: lists every session touching the day (cross-midnight sessions show both dates),
  add / edit / delete with validation and a preview of other affected days.
* Closing the calendar never stops the timer. Quitting while the timer runs asks to stop it first.

## Where data lives

* Database: `~/Library/Application Support/Workday/workday.sqlite` (SQLite, WAL, `synchronous=FULL`).
* Backups: `~/Library/Application Support/Workday/Backups/` — daily automatic snapshots when data changed
  (newest 30 kept), manual backups (20), and safety copies taken before every restore (10).
* Settings → Backups lists, validates and restores backups; Settings → Data & Privacy reveals the folder.

Nothing is ever sent off the Mac.

## Development helpers

* `WORKDAY_DATA_DIR=/some/dir` points the app at a separate data directory (used for testing; such
  instances never register a login item). Add `--seed-demo` to fill an empty directory with sample history
  and `--show-calendar` to open the calendar on launch.
* `Workday --snapshot <dir>` renders evidence PNGs (light/dark month, year, popover, tile scale, reduced motion,
  empty and recovery states) from deterministic demo data and exits.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for design decisions and policies,
[docs/requirements-checklist.md](docs/requirements-checklist.md) for the requirement-to-evidence matrix and
[docs/review-ledger.md](docs/review-ledger.md) for the independent review history.
