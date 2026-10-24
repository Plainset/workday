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
| R1 | medium | Untouched calendar steps at 1 fps (waves) / 4 fps (bubbles) — choppy | fixed `f295749` |
| R2 | medium | First interaction after a quiet period waits for the current sleep (≤1 s) | fixed `f295749` |
| R3 | low | Year view in scroll mode: arrow-key focus can move off-screen | fixed `f295749` |
| R4 | low | Year number split is static while compact waves slosh up to ~2.9 pt | fixed `f295749` |
| R5 | low | Dimmed-day colours: confirm with a dark snapshot | no change: `month-dark.png` / `month-previous-overflow-dark.png` show adjacent days legibly; hover only grows the tile by 2 pt |

## Cycle 4 — revision `3725ca5` (source = `f295749`)

| Cycle | Revision reviewed | Reviewer(s) | Verdict | Summary |
|---|---|---|---|---|
| 4 | `3725ca5` | Functional reviewer (tests 45/45) | APPROVED | No functional change; evidence matches source |
| 4 | `3725ca5` | UI/UX + macOS reviewer | CHANGES_REQUIRED | R1–R4 verified fixed; new high regression P1 |

| ID | Sev | Finding | Resolution |
|---|---|---|---|
| P1 | high | While a layer holds a still frame, a data change redraws with the stale frame time: new transitions look finished, the loop never wakes, liquid keeps the old level (esp. editor MiniGlass) | fixed `3d31010`: `LiquidMotion` moved to WorkdayCore; transitions/impulses stamped with the wall clock and started from the level reached by now; regression test `staleFrameTimeStillAnimates` + `calmCurve` |
| P2 | low | Year waves stop at the 3 s settle cutoff rather than easing out | no change: energy at the cutoff is exp(−3.9) ≈ 0.02 and year amplitude is capped at 1 pt, so the final step is ≈0.02 pt |

## Cycle 5 — revision `e20b665` (source = `3d31010`)

| Cycle | Revision reviewed | Reviewer(s) | Verdict | Summary |
|---|---|---|---|---|
| 5 | `e20b665` | Functional reviewer (tests 47/47) | APPROVED | No findings |
| 5 | `e20b665` | UI/UX + macOS reviewer | APPROVED | P1 verified fixed; one low edge case Q1 |

| ID | Sev | Finding | Resolution |
|---|---|---|---|
| Q1 | low | A day moving from the live layer to a still idle layer could draw a pre-change level (transition evaluated at a stale frame time) | fixed `3e395e1`: `fraction()` evaluates at `max(t, wallClock)`; test `crossLayerStaleDraw` |

## Cycle 6 — revision `1d3883a` (source = `3e395e1`) — FINAL

| Cycle | Revision reviewed | Reviewer(s) | Verdict | Summary |
|---|---|---|---|---|
| 6 | `1d3883a` | Functional reviewer (tests 48/48 in private build dir) | **APPROVED** | No findings; evidence matches source |
| 6 | `1d3883a` | UI/UX + macOS reviewer | **APPROVED** | Q1 verified fixed; no critical/high/medium; P2 (low, cosmetic) accepted |

Final approved revision: `1d3883ac2d83c96cd8bd6e3ad53f8d36775afa33` (application source identical to `3e395e1`; the
installable `dist/Workday.app` and `evidence/latest/` were built from that source). Later commits change docs only.

---

# Open-source release (Phase 1) and friends system (Phase 2)

Requirements: `docs/RELEASE_AND_FRIENDS_SPEC.md`. Commit SHAs below refer to the published (rewritten) history;
earlier v1 SHAs are mapped in `docs/HISTORY_REWRITE.md`.

## Phase 1 — cycle 1 — revision `ab96ef5`

| Reviewer | Verdict | Summary |
|---|---|---|
| A functional (tests 49/49, clean-clone build, upgrade from v1 baseline c2990f9 preserved 116 sessions bit-identical, permissions tightened) | APPROVED | 3 low |
| B security & privacy (gitleaks on published history and backup branch, identity/path checks, rewrite verified pair-by-pair, workflow pins verified) | APPROVED | 2 low, 5 info |
| C architecture & quality (tests, build, probes: newer-schema refusal, lock, sidecar perms) | APPROVED | 8 low |
| D release readiness (README steps in fresh clone, package_release, DMG/zip inspection, CI run 40086099208 green) | CHANGES_REQUIRED | 1 medium, 1 low-medium, 3 low, info |

| ID | Sev | Finding | Resolution |
|---|---|---|---|
| D1 | medium | "Right-click → Open" doesn't work on macOS 15+ (Privacy & Security → Open Anyway) | cycle 2 |
| D2 / B1 | low-med | SECURITY.md channel needs private vulnerability reporting, unavailable while private; no going-public checklist | cycle 2 |
| D3 / C4 | low | CFBundleVersion = 1 in CI/release (shallow clone); release workflow doesn't verify universal binary | cycle 2 |
| D4 / B4 | low | Committed evidence stale (pre-release revision) | cycle 2 |
| D5 / B6 | low | Bundle ID `local.workday.tracker` not owner namespace | cycle 2: owner chose `io.github.plainset.workday` |
| D6 | info | CHANGELOG link ref; release notes text | cycle 2 |
| B2 | low | Distributed notification object exposes the data path (incl. username) to other local processes | cycle 2 |
| B3 | info | Local backup branch contains original history | owner action: keep local or move to an off-repo bundle; never `push --all/--mirror` (RELEASING.md) |
| B5 | info | .gitignore could add `*.p8 *.sqlite3 *.partial` | cycle 2 |
| B7 | info | Dependency advisory check needed once dependencies exist | Phase 2 |
| C1 | low | `migrate()` treats an unreadable schema version as 0 and could downgrade the marker | cycle 2 |
| C2 | low | No v1 fixture/reopen test; migration pattern undocumented | cycle 2 |
| C3 | low | CLT Testing flags detected differently in Package.swift and test.sh (`DEVELOPER_DIR`) | cycle 2 |
| C5 | low | install.sh replaces the bundle even if the app didn't quit | cycle 2 |
| C6 | low | Dead compact branch in `labelledCanvas` | cycle 2 |
| C7 | low | evidence churn in git; `#` sed delimiter; no `trap` for DMG staging dir | cycle 2 (sed/trap fixed; evidence kept deliberately as review record, regenerated only at review points) |
| C8 | low | Test temp dirs never cleaned | cycle 2 |
| A1 | low | Lock file created 0644 | cycle 2 |
| A2 | low | Backups made by v1 not tightened on upgrade | cycle 2 |
| A3 | info | `OwnerOnly` chmods an existing `WORKDAY_DATA_DIR` | cycle 2 (documented in CONTRIBUTING) |
