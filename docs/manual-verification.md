# Manual and live verification

## 1. Environment

macOS 26.6.2 (Apple Silicon), Swift 6.3.3, Command Line Tools only. GUI checks were driven through the
computer-use accessibility tool against a **test instance** (`WORKDAY_DATA_DIR=<scratch> … --seed-demo`), never
against real user data. Part-way through, the test window moved off the current Space / the screen locked, which
blocked further background GUI interaction; those steps are listed under §3 as manual checks.

## 2. Performed live checks (builder, 2026-10-23)

| Check | Result |
|---|---|
| Launch test instance with demo data and `--show-calendar` | Calendar window rendered real persisted data (live screenshot matches snapshot) |
| Automatic backup on launch | `Backups/workday-auto-…sqlite` created; `sqlite3`: `journal_mode=delete`, `integrity_check=ok`, 121 sessions |
| Click **Start Work** in the calendar header | `events` gained `start`; session row `active`; header switched to **Stop Work** |
| Heartbeat checkpoint | active row `checkpoint_kind=heartbeat` updated within 30 s |
| Click a month tile | Day editor sheet opened immediately with that day's 2 sessions, total and "Goal met" |
| Dock policy with calendar open | `lsappinfo … applicationtype` → `Foreground` (Dock icon shown) |
| `kill -9` while timing, relaunch without flags | Session became `interrupted`, `checkpoint`=last heartbeat, `detected_at`=relaunch; `interruption-detected` event; app type `UIElement` (no Dock icon, calendar not forced open) |
| Keyboard focus | Focus ring visible on today's tile in the live window |
| Accessibility tree | Header buttons labelled ("Previous month", "Today", "Next month", "Start Work"); found Month/Year both labelled "Calendar view" → fixed in commit `5f92e67` |

### Cycle 2 live checks (2026-10-24, build of the cycle-2 fix commit)

| Check | Result |
|---|---|
| Relaunch test instance (pending recovery in data) | `UIElement` (menu bar only, no Dock icon) |
| Launch a second instance on the same data | second process exits 0; running instance opens its calendar (`Foreground`); one process remains |
| CPU/memory sample, calendar window open but screen locked/occluded | 0.4–0.7 % CPU, ~34–45 MB RSS (liquid paused when not visible) |
| Recovery panel (M8, after permission was granted) | Found window sizing bug (window 3127 px tall) → fixed (explicit window sizes, scrollable panel). Panel shows start / last observed / relaunch / confirmed / gap, three options, late-decision "keep running" wording. Selected **Count the gap** → Apply: session closed at the relaunch instant, `recovery-resolved` event, panel closed, red badge cleared |
| Editor (M6) | Click 23 Oct → editor; Add Session (09:00–17:00) → Save: day total 8h, "Goal met", streak 2→3, glass and tile filled immediately. Second identical session: red "This overlaps the session 09:00–17:00 on 23 Oct 2026…" and Save disabled. Done with open draft → "Discard the unsaved session?" dialog |
| Dock policy on close (A09) | Start Work, close calendar window → `UIElement` (no Dock icon), process alive, session still `active` |
| Second launch | running instance opens its calendar (`Foreground`) |
| Timer menu (U15) | while running, Timer menu item reads "Stop Timer (records 0m)" |
| Settings → Notifications | permission denied for the test bundle: orange "Notifications are turned off for Workday in System Settings…" row with **Open Settings**; toggles still usable |
| Settings → Backups | "Last backup 24 Oct 2026 at 0:02" — a new automatic snapshot was taken after midnight because data changed; list shows 2 valid automatic backups with session counts; **Restore…** disabled while the timer runs |
| Settings → General | goal stepper + minutes picker, launch-at-login toggle (not registered for test instances by design) |

### Cycle 3 measurements (2026-10-24)

* `scripts/perf.sh` (fresh process per scenario, real calendar views with demo data in an on-screen, nearly
  transparent click-through window, CPU via getrusage) — results in `evidence/latest/perf.txt`:
  menu bar only 0.1 %; month idle drift 10 % → 1.3 % after 30 s untouched; timer running 15 % → 3.6 % untouched;
  worst case continuous slosh 25 % (only during interaction bursts); year idle 1.4 %, year slosh 13.5 %.
* Finding during measurement: the cycle-2 build used ~4–6 % CPU in menu-bar-only mode because the closed popover's
  SwiftUI view re-laid out every second (profiled with `sample`). Fixed: popover content only exists while open,
  per-second ticks only while it is visible (menu bar only now 0.1 %).
* Finding: SwiftUI `TimelineView` redrew ~40–60 fps regardless of its schedule; replaced with a task loop.
* VoiceOver text: `DayAccessibility.label` is unit-tested (date + exact hours + goal/overflow/pending/live).

## 3. Manual checks still required (need a human at the Mac)

* **M1 Login item** — `./scripts/install.sh`, log out/in: menu bar item appears, no window, no Dock icon;
  Settings → General shows "Enabled" (or "Needs approval" with a working button).
* **M2 Notifications** — fresh install: the permission prompt appears at first launch (goal notice is on by default), set goal to 15 min, start the timer, wait:
  exactly one "Daily goal reached" banner; relaunch: no repeat. Deny permission in System Settings: Settings shows
  the denied state with "Open Settings"; app keeps working.
* **M3 Real sleep** — start the timer, sleep the Mac for ≥ 5 min, wake: today's total includes the sleep time and
  no recovery prompt appears.
* **M4 Smoothness (visual)** — CPU/fps are measured (above); a human should still judge that waves, slosh and
  pour-in look smooth and unobtrusive.
* **M5 VoiceOver** — ⌘F5, navigate the grid: each tile reads e.g. "Friday 23 October 2026, 6 hours 35 minutes
  worked, goal met"; arrow keys move the focus ring, Return opens the editor.
* **M6 Editor flow** — remaining: a cross-midnight session (other-day preview) and delete confirmation (add/overlap/discard verified live).
* **M7 Restore** — Settings → Backups → Back Up Now, change data, Restore… → confirmation → data reverts and a
  safety copy appears in the list.
* **M8 Recovery panel** — remaining: Exclude and Custom options live (Count verified live; all three unit-tested).
