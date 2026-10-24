# Workday — final handoff report

**Status: COMPLETE (independent review gate met).** Both independent reviewers (functional/spec and UI/UX +
macOS behaviour) returned **APPROVED** on the final revision after 6 build → review → remediation cycles
(`docs/review-ledger.md`). No critical, high or medium findings remain. Items that need a person at the Mac are
listed below and are *not* reported as passed.

| | |
|---|---|
| Project directory | repository root |
| Final approved revision | `1d3883ac2d83c96cd8bd6e3ad53f8d36775afa33` — app source identical to `3e395e1` |
| Installable app | `dist/Workday.app` — universal (arm64 + x86_64), ad-hoc signed, built from the approved source |
| macOS | 14 Sonoma or later; developed and verified on macOS 26.6.2, Apple M3 |
| Toolchain | Swift 6.3.3, Xcode Command Line Tools only (no Xcode needed), macOS 26.5 SDK |
| Tests | 48 Swift Testing tests in 9 suites — all pass (`evidence/latest/test.log`) |

## Build, test, install, run

```bash
./scripts/test.sh            # unit tests
./scripts/build_app.sh       # → dist/Workday.app (universal, signed)
./scripts/install.sh         # copies to /Applications (or ~/Applications) and launches
./scripts/collect_evidence.sh  # tests + build + snapshots → evidence/latest/
./scripts/perf.sh            # CPU per animation scenario (needs a normal, non-full-screen Space)
```

First launch opens the calendar once and registers the login item; afterwards Workday starts silently in the
menu bar at login.

## User approvals that may be needed

* **Login item** — macOS may notify "Workday added to Login Items" or require approval in System Settings → General
  → Login Items (Settings → General shows the state and a button to open it).
* **Notifications** — asked once at first launch (the goal-reached notice is on by default). Denial is handled; the
  app works without them.
* **Gatekeeper** — ad-hoc signed: on another Mac use right-click → Open the first time.

## Data and backups

* Database: `~/Library/Application Support/Workday/workday.sqlite` (SQLite, WAL, synchronous=FULL).
* Backups: `~/Library/Application Support/Workday/Backups/` — automatic daily snapshot when data changed (30 kept),
  manual (20), pre-restore safety copies (10). Nothing leaves the Mac; there is no networking code.

## Verification matrix

Full matrix with implementation locations: `docs/requirements-checklist.md`. Live GUI checks and perf:
`docs/manual-verification.md`, `evidence/latest/perf.txt`. Visual evidence: `evidence/latest/snapshots/`.

| Test | Result | Basis |
|---|---|---|
| A01 Timer | **PASS** | unit tests + live Start persisted |
| A02 Idle/sleep | PASS (logic) · **UNVERIFIED on hardware** | no idle/sleep pause exists; real sleep cycle = M3 |
| A03 Midnight | **PASS** | unit tests (30 m / 75 m), live rollover logic |
| A04 DST/time zone | **PASS** | spring-forward, fall-back, zone-change tests; policy in ARCHITECTURE |
| A05 Crash/restart | PASS (logic) · PARTIAL (UI) | 14 recovery tests; live `kill -9` → interrupted; Count applied live; Exclude/Custom live = M8 |
| A06 Edit | PASS (logic) · PARTIAL (UI) | tests; live add/overlap/discard; cross-midnight preview & delete dialog live = M6 |
| A07 Fill | **PASS** | scale test + snapshots (0 / 9 h / 18 h / 19 h+, overflow) |
| A08 Calendar | **PASS** | 60-month grid test incl. leap day; month/year snapshots at several sizes; live click → editor |
| A09 Menu bar | PARTIAL | live Dock policy, close-keeps-tracking, second-launch hand-off; **login at boot = M1** |
| A10 Goal | PASS (logic) · **UNVERIFIED delivery** | streak/once-per-day/reminder tests; banner delivery = M2 |
| A11 Backup | **PASS** | backup/restore/corruption/retention tests; live daily auto-backup |
| A12 Polish | PARTIAL | perf measured (menu bar 0.1 %, idle calendar ≤1 % once still); light/dark, Reduce Motion, keyboard, a11y labels tested; spoken VoiceOver = M5, visual smoothness judgement = M4 |
| A13 Packaging | **PASS** | clean build script, universal signed app, install script |

## Remaining manual checks (need a person at the Mac)

Details in `docs/manual-verification.md` §3:
M1 login item at a real login · M2 notification banner delivery · M3 real sleep/wake · M4 visual smoothness ·
M5 spoken VoiceOver pass · M6 cross-midnight preview, delete dialog, tile rising after an edit while idle ·
M7 restore through the UI · M8 Exclude/Custom recovery options live.

## Known limitations

* Ad-hoc signature only (no paid Developer ID / notarisation).
* Fixed point sizes in the tile grid (macOS has no system Dynamic Type for AppKit apps); tiles scale with the window.
* After a time-zone change, past sessions are shown on the dates they fall on in the *current* zone (documented
  policy).
* Year-view slosh stops at a 3 s cutoff rather than easing out (cosmetic, accepted as low by the reviewer).
* GUI automation for this verification was partly limited by screen-capture permission availability; affected checks
  are listed above as manual.

## Notable defects found and fixed through the review loop

Goal notifications never requesting permission (F1); late recovery decisions silently counting hours (F2);
year view truncating dates at small sizes (U18); labels unreadable where the waterline crossed them (U2/U19);
TimelineView redrawing near display rate and a hidden popover costing 4–6 % CPU (U20, found by profiling);
a 3127 px recovery window (found live); stale liquid level after edits while still (P1).
