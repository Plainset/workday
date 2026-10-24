# Review ledger

Append-only record of each build → independent review → remediation cycle. Prior entries are never edited
except to add the fix commit for a finding.

| Cycle | Revision reviewed | Reviewer(s) | Verdict | Summary |
|---|---|---|---|---|
| 1 | `d743750` | Functional reviewer (independent subagent, ran tests in private build dir: 33/33 pass) | CHANGES_REQUIRED | 1 high, 2 medium, 7 low |
| 1 | `d743750` | UI/UX + macOS reviewer (independent subagent, read code + all 13 snapshots) | CHANGES_REQUIRED | 2 high, 7 medium, 8 low |

## Cycle 1 — findings (revision `d743750`)

Functional reviewer (A10 FAIL; A09/A12 UNVERIFIED; others PASS at logic level):

| ID | Sev | Finding | Resolution |
|---|---|---|---|
| F1 | high | Goal notification (on by default) never requests permission, so it never fires | fixed `71f3b67`/`2c20e84` |
| F2 | medium | "Keep running" after a late recovery decision silently counts hours since relaunch | fixed `71f3b67`/`2c20e84` |
| F3 | medium | `poweringOff` never reset after a cancelled logout disables quit confirmation | fixed `71f3b67`/`2c20e84` |
| F4 | low | Backwards clock can discard a session on stop / recovery | fixed `71f3b67`/`2c20e84` |
| F5 | low | Start refused right after a manual entry ending ≤60 s in the future | fixed `71f3b67`/`2c20e84` |
| F6 | low | Deleting the running session from the editor leaves nap activity/status stale | fixed `71f3b67`/`2c20e84` |
| F7 | low | "Last backup" counts safety copies; pruning doesn't protect newest valid copy | fixed `71f3b67`/`2c20e84` |
| F8 | low | Reminder time picker off by an hour on DST days | fixed `71f3b67`/`2c20e84` |
| F9 | low | Restore can re-fire today's goal notification | fixed `71f3b67`/`2c20e84` |
| F10 | low | Check-in reminder has no window | fixed `2c20e84` (check-in only for sessions running at the chosen time; test F10) |
| F-EG | — | Ledger empty; A05/A06 marked PASS while UI unverified | fixed: ledger maintained; A05/A06 now PARTIAL |

UI/UX reviewer (A07 PASS, A08 PASS, A09 UNVERIFIED, A12 FAIL):

| ID | Sev | Finding | Resolution |
|---|---|---|---|
| U1 | high | Idle redraw at 40 fps / 12×20 fps year timelines; MiniGlass always 40 fps; 1 s body refresh | fixed `71f3b67`/`2c20e84` |
| U2 | high | Dark year view day numbers illegible where waterline crosses glyph | fixed `71f3b67`/`2c20e84` |
| U3 | medium | Fixed coverage thresholds split month tile text | fixed `71f3b67`/`2c20e84` |
| U4 | medium | No empty-state guidance in calendar | fixed `71f3b67`/`2c20e84` |
| U5 | medium | Reduce Motion doesn't gate slide transitions/springs | fixed `71f3b67`/`2c20e84` |
| U6 | medium | Adjacent-month days faded twice; unreadable in dark | fixed `71f3b67`/`2c20e84` |
| U7 | medium | Day editor doesn't scroll | fixed `71f3b67`/`2c20e84` |
| U8 | medium | Automatic backup failure only visible in Settings | fixed `71f3b67`/`2c20e84` |
| U9 | medium | Year view lacks keyboard navigation; readout hover-only | fixed `71f3b67`/`2c20e84` |
| U10 | low | Goal 0 → nonsense progress | no change: `WorkdaySettings.normalized()` clamps to ≥15 min (test `streakBreak`) |
| U11 | low | Exactly-18h tile is a static slab | fixed `71f3b67`/`2c20e84` |
| U12 | low | Recovery panel floats above other apps | fixed `71f3b67`/`2c20e84` |
| U13 | low | Second launch gives no feedback | fixed `71f3b67`/`2c20e84` |
| U14 | low | Esc on Done discards unsaved draft | fixed `71f3b67`/`2c20e84` |
| U15 | low | ⇧⌘S toggles timer without clear feedback | fixed `71f3b67`/`2c20e84` |
| U16 | low | `month-overflow-light.png` mislabelled (same month) | fixed `71f3b67`/`2c20e84` |
| U17 | low | Fixed font sizes | partially fixed `2c20e84` (scale factors; limitation documented in ARCHITECTURE) |

Fix commits: core findings in `71f3b67` (regression suite `Tests/WorkdayCoreTests/RegressionTests.swift`, 9 tests),
app/UI findings in `2c20e84`. Evidence regenerated for `2c20e84`: 42/42 tests, universal build, 20 snapshots.

## Cycle 2 — revision `c1a5e05`

| Cycle | Revision reviewed | Reviewer(s) | Verdict | Summary |
|---|---|---|---|---|
| 2 | `c1a5e05` | Functional reviewer (re-ran tests in private dir: 42/42) | APPROVED (functional scope) | F1–F10 verified fixed; 3 new low findings |
| 2 | `c1a5e05` | UI/UX + macOS reviewer | CHANGES_REQUIRED | U1–U17 verified (U1, U9 partial); 1 high, 2 medium, 2 low new; A08/A12 FAIL |

| ID | Sev | Finding | Resolution |
|---|---|---|---|
| F11 | low | `poweringOff` reset after 90 s can show the quit alert during a very slow logout | fixed `aa56666` |
| F12 | low | Resume after a backwards clock can start a piece in the future (stop refused) | fixed `aa56666` |
| F13 | low | Stop & Quit terminates even when the stop failed | fixed `aa56666` |
| U18 | high | Year view at small window sizes: ~4 pt tiles, day numbers truncate to first digit (`year-minsize-*.png`) | fixed `aa56666` |
| U19 | medium | WaterlineSplit mask doesn't follow the drawn liquid during pour-in/slosh/hover growth | fixed `aa56666` |
| U20 | medium | Live session redraws the whole month at 24 fps; per-minute target change sloshes; MiniGlass visibility unproven | fixed `aa56666` |
| U21 | low-med | Year view doesn't take focus on appear; focus overrides hover readout; Space unhandled | fixed `aa56666` |
| U22 | low/gap | CPU only sampled in the paused state; need key-window measurements | fixed `aa56666` |

Cycle 2 fixes in `aa56666`; evidence (45/45 tests, universal build, snapshots, perf) regenerated for `aa56666`.

## Cycle 3 — revision `4ae1c6e`

| Cycle | Revision reviewed | Reviewer(s) | Verdict | Summary |
|---|---|---|---|---|
| 3 | `4ae1c6e` | Functional reviewer (re-ran tests: 45/45) | APPROVED | F11–F13 verified; no findings; perf/snapshot modes can't touch real data |
| 3 | `4ae1c6e` | UI/UX + macOS reviewer | APPROVED | U18–U22 verified; no critical/high; 2 medium + 3 low motion/keyboard polish items recommended before release |

| ID | Sev | Finding | Resolution |
|---|---|---|---|
| R1 | medium | Untouched calendar steps at 1 fps (waves) / 4 fps (bubbles) — choppy | cycle 4 |
| R2 | medium | First interaction after a quiet period waits for the current sleep (≤1 s) | cycle 4 |
| R3 | low | Year view in scroll mode: arrow-key focus can move off-screen | cycle 4 |
| R4 | low | Year number split is static while compact waves slosh up to ~2.9 pt | cycle 4 |
| R5 | low | Dimmed-day colours: confirm with a dark snapshot | no change: `month-dark.png` / `month-previous-overflow-dark.png` show adjacent days legibly; hover only grows the tile by 2 pt |
