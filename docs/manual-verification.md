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
| computer-use GUI driving | not possible this cycle: macOS Screen Recording permission for the tool was not granted |

## 3. Manual checks still required (need a human at the Mac)

* **M1 Login item** — `./scripts/install.sh`, log out/in: menu bar item appears, no window, no Dock icon;
  Settings → General shows "Enabled" (or "Needs approval" with a working button).
* **M2 Notifications** — fresh install: the permission prompt appears at first launch (goal notice is on by default), set goal to 15 min, start the timer, wait:
  exactly one "Daily goal reached" banner; relaunch: no repeat. Deny permission in System Settings: Settings shows
  the denied state with "Open Settings"; app keeps working.
* **M3 Real sleep** — start the timer, sleep the Mac for ≥ 5 min, wake: today's total includes the sleep time and
  no recovery prompt appears.
* **M4 Frame rate** — with the calendar key, Activity Monitor CPU for Workday should stay modest and animation
  smooth in month and year views; with the window in the background animation slows; hidden → near-zero CPU.
* **M5 VoiceOver** — ⌘F5, navigate the grid: each tile reads e.g. "Friday 23 October 2026, 6 hours 35 minutes
  worked, goal met"; arrow keys move the focus ring, Return opens the editor.
* **M6 Editor flow** — add an overlapping session (red explanation, Save disabled), a cross-midnight session
  (other-day preview), edit, delete with confirmation; liquid level updates immediately.
* **M7 Restore** — Settings → Backups → Back Up Now, change data, Restore… → confirmation → data reverts and a
  safety copy appears in the list.
* **M8 Recovery panel** — `kill -9` while timing, relaunch: floating "Interrupted Session" panel; try Exclude /
  Count / Custom; Apply twice is impossible; menu bar red dot clears.
