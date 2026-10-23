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
| F1 | high | Goal notification (on by default) never requests permission, so it never fires | cycle 2 |
| F2 | medium | "Keep running" after a late recovery decision silently counts hours since relaunch | cycle 2 |
| F3 | medium | `poweringOff` never reset after a cancelled logout disables quit confirmation | cycle 2 |
| F4 | low | Backwards clock can discard a session on stop / recovery | cycle 2 |
| F5 | low | Start refused right after a manual entry ending ≤60 s in the future | cycle 2 |
| F6 | low | Deleting the running session from the editor leaves nap activity/status stale | cycle 2 |
| F7 | low | "Last backup" counts safety copies; pruning doesn't protect newest valid copy | cycle 2 |
| F8 | low | Reminder time picker off by an hour on DST days | cycle 2 |
| F9 | low | Restore can re-fire today's goal notification | cycle 2 |
| F10 | low | Check-in reminder has no window | cycle 2 (documented behaviour) |
| F-EG | — | Ledger empty; A05/A06 marked PASS while UI unverified | cycle 2 |

UI/UX reviewer (A07 PASS, A08 PASS, A09 UNVERIFIED, A12 FAIL):

| ID | Sev | Finding | Resolution |
|---|---|---|---|
| U1 | high | Idle redraw at 40 fps / 12×20 fps year timelines; MiniGlass always 40 fps; 1 s body refresh | cycle 2 |
| U2 | high | Dark year view day numbers illegible where waterline crosses glyph | cycle 2 |
| U3 | medium | Fixed coverage thresholds split month tile text | cycle 2 |
| U4 | medium | No empty-state guidance in calendar | cycle 2 |
| U5 | medium | Reduce Motion doesn't gate slide transitions/springs | cycle 2 |
| U6 | medium | Adjacent-month days faded twice; unreadable in dark | cycle 2 |
| U7 | medium | Day editor doesn't scroll | cycle 2 |
| U8 | medium | Automatic backup failure only visible in Settings | cycle 2 |
| U9 | medium | Year view lacks keyboard navigation; readout hover-only | cycle 2 |
| U10 | low | Goal 0 → nonsense progress | no change: `WorkdaySettings.normalized()` clamps to ≥15 min (test `streakBreak`) |
| U11 | low | Exactly-18h tile is a static slab | cycle 2 |
| U12 | low | Recovery panel floats above other apps | cycle 2 |
| U13 | low | Second launch gives no feedback | cycle 2 |
| U14 | low | Esc on Done discards unsaved draft | cycle 2 |
| U15 | low | ⇧⌘S toggles timer without clear feedback | cycle 2 |
| U16 | low | `month-overflow-light.png` mislabelled (same month) | cycle 2 |
| U17 | low | Fixed font sizes | cycle 2 (partial: scale factors; limitation documented) |
