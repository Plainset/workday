# WORKDAY — Native macOS Work Tracker
**Autonomous agent build specification | 23 October 2026**

> /goal build the whole document until completion and in the manner described

## 01 | Mission and delivery contract

Build, test, package, and deliver a complete, genuinely usable, offline-first native macOS work-hours tracker. The app measures work only through an explicit Start/Stop timer, and its defining feature is an animated orange-liquid calendar. The implementation should be undertaken end-to-end in a single autonomous run, without stopping at a prototype, visual mockup, or unfinished skeleton.

Interpret /goal build the whole document until completion and in the manner described as an instruction to implement every mandatory requirement, run tests, launch and verify the user experience where the environment permits, and report objective evidence. Do not claim completion unless the definition of done at the end is met.

- MANDATORY: Native macOS app; no webview-based imitation or hosted backend.
- MANDATORY: Launch-at-login background menu bar companion and separately openable calendar window.
- MANDATORY: Local-only persistence, local automatic backups, notifications, editable sessions, real monthly/yearly liquid calendar.
- MANDATORY: Fully working build and reproducible local installation instructions; no paid services or user accounts.
- Agent may make minor implementation choices without asking, but must not change the behavioural requirements or silently omit features.

## 02 | Locked product decisions

- Tracking: only an explicit Start/Stop timer; time during an active session counts even when idle or Mac is asleep.
- No automatic app/site activity monitoring. No projects or task categories required.
- Multiple sessions on the same day accumulate. Cross-midnight time is allocated to the actual corresponding local calendar days.
- Platform: macOS only; single Mac; no cloud sync or accounts.
- Menu bar: small orange indicator plus today’s duration as compact text; clicking opens a dropdown with status, controls, goal progress, and small useful detail.
- Main window: month-first calendar; optional full-year view showing twelve miniature calendars. Each day is a square of animated orange liquid.
- Scale: empty at zero; full at 18 hours; beyond 18 hours an additional overflow effect (while true hours remain accurate).
- Every day square contains the date number and exact worked duration. Clicking a day opens that day’s session editor immediately.
- One configurable daily goal applied to every date; show progress and streaks without overwhelming the calendar.
- Goal-reached notifications and optional start/stop reminders.
- Auto-start at login without opening the main window. Dock icon absent in menu-bar-only operation; visible when the main window is open.
- Sessions can be added, removed and edited by start/end time; no direct daily-total overwrite required.
- After app crash or computer shutdown during work: restore and prompt user to decide whether to count the interrupted gap.
- Automatic local backups with restore; no CSV export required.

## 03 | Visual and interaction direction

The calendar is the hero. Aim for a distinctive, premium desktop feel: warm translucent orange liquid, subtle dimensional depth, gentle waves, believable sloshing, clean rounded tiles, crisp typography and restrained chrome. The effect should look fluid rather than a static orange percentage bar. Use native layout, good contrast, and purposeful motion.

Exact artistic details can be chosen by the agent, but deliver a polished, coherent system rather than a generic dashboard. Motion must remain smooth for an entire month and for the compact twelve-month overview. Respect macOS Reduce Motion, using a still liquid fill/brief transitions while retaining the exact same data.

- Default monthly grid: seven weekday columns, correctly aligned weekday headers, month/year header with previous/next navigation and Today shortcut.
- Each date tile: readable day number, readable duration (e.g. 6h 35m), bounded fill height based on clamped hours / 18, animated wave surface and clipped overflow within tile.
- Use a distinct treatment for today and a subtle goal-achievement mark; do not obscure the liquid or duration.
- For 18h+ days: base tile remains full and a tasteful visible overflow treatment appears (e.g. bright rim, bubbles or glow). It must not imply lost or capped hours.
- Month grid must show correct spillover blank slots or subdued adjacent-month days; no day misalignment.
- Year view: all twelve small monthly grids in one overview, each individual day carrying liquid fill, with readable month labels. For very small year tiles, show the exact hours on hover/focus or click while maintaining legible date/hour text in full-size month tiles.
- Transitions between views and during timer updates should be smooth, not attention-grabbing; avoid continuously redrawing every tile at high frame rate when idle.

## 04 | Menu bar experience

- Persistent status item: compact orange visual plus today’s cumulative time (e.g. ● 06:35); length should stay reasonable on the menu bar.
- Click opens a compact dropdown/popover with today’s total, active elapsed session time if running, Start/Stop primary action, progress against daily goal, and current goal value.
- Include quick access to Open Calendar, Settings, and Quit; show clear Running/Stopped status.
- Duration counts upward while running; update at a sensible cadence (e.g. every second in the popover and once per minute for compact menu-bar text, with accurate underlying start/end timestamps).
- If recovery is pending, show an obvious unresolved-session notice/action rather than falsely implying time was settled.
- Closing the calendar window must not stop work tracking or remove the menu-bar item.

## 05 | Timer, session accounting and calendar math

Store authoritative timestamped session intervals, not increment-only counters. Local calendar-day totals are derived by splitting session intersections at local-midnight boundaries. The live session is computed from the recorded start instant through the current instant. Use integer seconds or precise time intervals internally; round only for display.

Define a single time-accounting service so the menu bar, editor, monthly view, yearly view, statistics and notifications all read the same derived totals. No double counting across intervals. Prevent negative and invalid intervals. Reject or clearly resolve overlapping recorded sessions.

- Start is idempotent: when already running, do not create a second open session. Stop finalizes the active interval at the actual stop timestamp; a subsequent Start begins another interval.
- A working session continues through ordinary idle time, screen lock and system sleep, because the user selected explicit Stop as the sole ordinary termination.
- When crossing midnight, allocate seconds correctly between adjacent dates; update the displayed daily total when local date changes without requiring restart.
- Use the system local timezone and calendar for dates; store timestamps as absolute instants plus enough timezone/context to interpret historical edits consistently. Account for DST transitions and timezone changes; document the policy (recommended: date partitioning by selected/current calendar timezone with absolute-duration math).
- Calculate today’s ongoing amount accurately even if the UI refresh timer is throttled, and do not rely on UI refresh ticks to accrue work.
- Total time can exceed 18 hours without data loss or clipping; a calendar square caps only the visual fill, then uses its overflow animation.

## 06 | Crash, restart and interrupted-session recovery

Preserve a durable record of every Start/Stop action. Persist the active session start, last known trustworthy alive checkpoint, and recovery status. On relaunch after a process crash, force-quit, power loss or full reboot, detect unresolved sessions and display a non-destructive recovery decision before counting uncertain downtime.

Critical distinction: normal macOS sleep is explicitly counted as work while the active session continues; app/process termination or full machine shutdown is an interruption requiring user review. Where exact crash time cannot be proved, use the last reliable checkpoint and clearly describe any uncertainty; never silently assign the entire offline gap or quietly discard earlier work.

- Recovery UI presents the preserved start, last reliably observed time, resumed/relaunch time, and estimated gap. Offer Count the gap, Exclude the gap, or Set an exact end/resume time (or split at chosen timestamps).
- Until resolution, clearly distinguish confirmed time from pending time; never double count the gap. The original confirmed portion survives even if user declines counting the gap.
- If the app relaunches at login with a pending recovery, it may show a menu-bar badge and recovery panel/popover but must not force open the main calendar window unnecessarily.
- Use OS lifecycle signals and a durable checkpoint strategy to distinguish sleep from termination as robustly as practicable; if ambiguous, prefer asking rather than guessing.
- After a recovery decision, persist the resulting confirmed intervals atomically and remove the pending state. Recovery must remain idempotent through multiple launches.
- If an uninterrupted active app spans system sleep, resumed wall-clock elapsed time is included without prompting.

## 07 | Daily editor and historical integrity

- Clicking any day in the month calendar opens that date’s editor immediately, in a polished sheet or panel.
- Editor displays total for that date and a chronological list of all session portions affecting it; show start and end times and relevant dates for cross-midnight sessions.
- Add, change, and delete individual sessions. Every edit updates totals and liquid fill immediately after successful save.
- For cross-midnight sessions, editing either endpoint must correctly recalculate both dates; show a clear warning or preview when a change affects other days.
- Use native, timezone-aware date/time editing controls and validation. Reject end-before-start, zero/negative durations, and inadvertent overlaps with actionable explanations.
- For sessions still running, avoid unsafe past edits. Either offer a clear Stop first or support a fully validated workflow without losing the running interval.
- Confirmation is appropriate for destructive deletions; provide an easy Cancel/Save flow. Maintain data consistency even after crashes during edits.

## 08 | Goals, streaks, notifications and minimal stats

- One editable daily goal in hours/minutes (reasonable initial default: 8h, but user can change it in Settings). Daily goal must not change the 18h liquid scale.
- Menu dropdown shows daily goal progress; monthly screen can show a small progress line and minimal summary (e.g. total this month and days goal achieved). Avoid a statistics-heavy dashboard.
- Display a streak based on consecutive calendar days meeting the configured goal. Specify deterministic handling for today-in-progress: today should not break a streak before the day finishes; missed completed days do break it. Since goal is universal, weekends count unless user later changes requirements.
- Define behaviour when the user changes goal: for simplicity, apply the current goal consistently to historical streak calculation; disclose it in Settings/help.
- Notify once per day when today first reaches the goal (not repeatedly on redraw/restart). Request notification permission when the feature is enabled, and handle denial gracefully.
- Optional local reminder settings: a simple start reminder at chosen local time and stop/check-in reminder at chosen time when the timer is still running. Each can be enabled/disabled independently; avoid duplicate daily notifications.
- Keep the interface usable with notifications disabled. No analytics, remote telemetry or user tracking.

## 09 | Platform and architecture

Use Swift with SwiftUI for application views and AppKit for the best native status item/popover and Dock activation-policy control; native Core Animation, Canvas/Metal if justified, or equivalent for high-quality liquid effects. Prioritise maintainability and smooth performance over a technically flashy animation stack.

Target a modern, stable macOS version available in the build environment; document minimum supported macOS version and Xcode/Swift toolchain. Support both Apple Silicon and Intel Macs if feasible. One app bundle, with no always-on remote services.

- Use a single application lifecycle with menu-bar presence while the main window is closed; choose NSStatusItem or equivalent to support precise popover, window and Dock behaviour.
- Enable Launch at Login through supported macOS APIs (e.g. SMAppService) with a user-visible toggle and permission/error feedback.
- Keep accurate and durable local storage, preferably SQLite/SwiftData or a justified equivalent, with safe migrations and atomic operations.
- Organise code into separable modules for timer/session persistence, date slicing and aggregates, recovery, notifications, backups, animated liquid tile, calendar UI, menu bar and settings.
- Liquid simulation should be efficient, deterministic enough for testing, and accessible with Reduce Motion. Avoid third-party dependencies unless they significantly improve results.
- No cloud, network requirement, sign-in, browser extension, subscription, manual developer commands to run on every boot, or proprietary services.
- Use clear privacy posture: all work history stored locally. Explain storage and backups locations without exposing private paths in screenshots.

## 10 | Backup, restore and data safety

- Automatically create versioned local backups in an appropriate Application Support location; use separate files or database snapshots, never copying a live SQLite DB unsafely.
- Backup policy: daily when data changes, retain at least the most recent 30 daily recovery points (or a similarly justified documented policy). Preserve valid last-known-good copies.
- Provide a Settings action to view backup status, create a backup now, and restore from an available local backup after confirmation.
- Backup/restore must include sessions, goals/settings as appropriate, and unresolved recovery state. Validate backups before replacement; preserve current data in a safety backup before restore.
- Backups must remain on this Mac, without CSV export or remote sync.
- Include schema/version metadata and graceful handling for corrupted/partial backups.

## 11 | Required states and accessibility

- Correct UI for no sessions, current day with zero hours, active work, timer stopped, >18-hour day, date with multiple sessions, missing permissions, notifications denied, backup failure, and interrupted recovery.
- Native keyboard navigation, obvious focus states, VoiceOver descriptions containing date and exact hours, sufficiently contrasting labels, appropriate large-text resilience and reduced-motion mode.
- Timer controls must clearly indicate consequence and must not be accidentally triggered by opening the menu or calendar.
- Visuals must render well in both light and dark system appearances; ensure orange liquid and tile text remain legible.
- Provide sensible empty-state messaging and graceful error handling rather than blank screens or crashes.

## 12 | Implementation sequence and autonomous execution

- Inspect development environment, determine Xcode/SDK availability, initialise a maintainable native macOS application project and document decisions.
- Implement persistent session domain model, calendar slicing and unit-tested time math before binding UI to data.
- Implement start/stop controls, background menu bar behaviour, reliable lifecycle handling and crash recovery.
- Implement session editor, local settings/goals, notifications and backups.
- Build high-fidelity animated orange liquid tile and complete month/year calendars using actual persisted data. Iterate on spacing, performance and readability.
- Add full UI states, accessibility features, automated tests, integration tests, packaging/installation, launch-on-login and Dock policy.
- Execute tests, compile release build, manually exercise key flows where GUI automation exists, and fix failures. Re-run the suite after each significant fix.
- Provide final deliverables and a factual handoff with build/run instructions, tests performed, known limitations, and any environment-only blockers.

## 13 | Acceptance tests (must pass)

- A01 Timer: Start, leave active, Stop, Start again. Daily total equals sum of non-overlapping intervals; restarting UI does not reset history.
- A02 Idle/sleep: active session includes wall-clock duration across screen lock and system sleep; no pause on idle.
- A03 Midnight: a session from 23:30 to 01:15 contributes 30 minutes to day one and 75 minutes to day two.
- A04 Timezones/DST: crossing a DST change produces correct absolute duration and stable date allocation under documented policy.
- A05 Crash/restart: unresolved session survives relaunch; pending gap is not silently counted; counting, excluding, or editing gap produces correct totals and cannot be applied twice.
- A06 Edit: add/edit/delete past session; date total and liquid height change immediately and correctly; overlapping or invalid ranges cannot corrupt data.
- A07 Fill: 0h empty, 9h half-height, 18h full, 19h full plus visible overflow treatment with exact 19h displayed.
- A08 Calendar: all month layouts, leap day, navigation and twelve-month overview display correct dates/totals and clicking a date opens its editor.
- A09 Menu bar: present after login, accurate today display, Start/Stop works; main window closed does not terminate service; Dock icon visible only when window is open.
- A10 Goal: configurable target changes progress; streak logic is deterministic; one goal-reached notification per day; optional reminders respect preferences and permission state.
- A11 Backup: automatic snapshot created, recoverably restorable, validation/rollback prevents accidental loss; no remote calls.
- A12 Polish: stable frame rate in month/year views on target hardware, light/dark legibility, reduced motion, keyboard/VoiceOver usability, correct active and empty states.
- A13 Packaging: clean checkout builds without undocumented manual source edits; output a runnable .app with explicit install/start instructions.

## 14 | Definition of done and reporting

The agent is DONE only when the native app compiles, launches, records and persists time correctly, shows a fluid monthly and yearly calendar from real data, includes every required control/editor/setting, survives interruption according to recovery rules, and meets the acceptance tests above. A screenshot, design prototype, architecture document or source code alone is not completion.

If GUI signing, OS notification permissions, login item approval or available hardware prevent full verification, implement as far as possible, supply reproducible manual verification instructions, and explicitly distinguish verified vs unverified functions; do not fabricate test results.

The final report should state: project directory, exact commands to build and run, location of installable app, macOS compatibility, tests and their outcomes, remaining limitations (if any), data/backup storage locations and any user approvals needed to enable login item or notifications.

## 15 | Mandatory build → independent review → remediation loop

This section is an execution protocol, not an optional recommendation. The implementing agent must repeatedly build the actual application, submit the current project state and verification evidence to independent reviewer agent(s), repair identified gaps, and resubmit. Do not treat a single successful compile, a self-assessment, or a passing unit-test suite as completion.

### 15.1 Roles and independence

- Builder: owns implementation, test execution, release packaging, and remediation. May not approve its own work.
- Reviewer: a separate agent/context from the builder, given the original specification, the actual current repository/project state, build artifacts, and test evidence. Reviews independently against every requirement and acceptance test. Prefer an additional UI/UX reviewer for liquid animation and macOS behaviour if resources permit.
- Reviewers must inspect current code and evidence directly; neither trusting the builder’s summary nor rubber-stamping it is sufficient. Do not claim a separate reviewer was used if only the builder conducted the review.
### 15.2 Mandatory iteration

1. Translate sections 01–14 and all A01–A13 into a persistent requirement-to-evidence checklist. Each item must have an implementation location, validation method, status (PASS / FAIL / UNVERIFIED / BLOCKED), and supporting evidence.
2. Implement a coherent, end-to-end build and run available automated tests. Package a runnable .app when the environment permits. Save exact build commands, logs, test results, screenshots/video or UI test evidence as appropriate, and current Git revision.
3. Send the full specification, current project source/state, requirement checklist, and objective build/test/UI evidence to reviewer(s). Explicitly ask for adversarial comparison with the specification, regressions, missing features, visual deficiencies and unverified behaviours.
4. Reviewer(s) return a structured review: verdict (APPROVED / CHANGES_REQUIRED / BLOCKED), item-by-item A01–A13 disposition, reproducible findings with severity, file/feature references, required fixes, and evidence gaps. An unsupported “looks complete” verdict is invalid.
5. Builder fixes every actionable finding, adds regression tests where appropriate, rebuilds and retests, updates evidence/checklist and sends the revised state back to the independent reviewer(s). Repeat steps 3–5 with no arbitrary cap on review rounds.
6. If reviewer opinions conflict, reconcile them with direct evidence and rerun the relevant tests; do not quietly discard an unresolved high-severity issue. Every later cycle must include regression checks on previously approved requirements.
### 15.3 Exit criteria and blockers

- SUCCESS: The latest project state receives an explicit final APPROVED verdict from an independent reviewer; A01–A13 and every mandatory requirement have supporting verification; no unresolved critical/high defects; and the installable artifact matches the reviewed revision. Only then report COMPLETE.
- BLOCKED: End the loop only when a genuinely unresolvable blocker prevents further meaningful progress (for example unavailable Apple tooling/hardware, OS permission or signing action requiring the user, missing access to required reviewer mechanism, or irreconcilable technical constraint). First attempt practical alternatives, and distinguish a blocker from a fixable failure. Never label unreviewed work APPROVED.
- When BLOCKED, produce a blocker report: exact dependency, actions attempted, evidence/logs, what is finished, unverified items, and the minimal user action or environment change needed. If independent reviewer agents cannot be invoked, do the maximum possible build/testing and clearly state that the mandatory independent review gate was not met.
### 15.4 Review ledger and final handoff

- Maintain a versioned review ledger in the repository (e.g. docs/review-ledger.md) with each cycle’s revision, reviewer, verdict, findings, fixes, test evidence and remaining risks. Never erase prior failures or retroactively alter verdicts.
- Final handoff must include the review ledger, latest reviewer approval (or explicit blocker report), final repository revision, build/install path, verification matrix and any environment-limited manual checks. “Done” cannot be declared solely because the builder runs out of iterations, context or time.
