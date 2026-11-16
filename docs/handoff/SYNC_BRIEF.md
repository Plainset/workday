# Brief: sync Workday between the owner's two Macs

You are picking up work on **Workday**, a native macOS menu-bar work-hours tracker. It is an open-source project
owned by the person handing you this brief (the "owner"). You are running on the owner's **Mac Mini**. The owner
also uses Workday on a **MacBook (laptop)**. You cannot reach the laptop. Everything you need is in this brief and
in the repository.

## Goal

Hours logged on either Mac must appear on the other, as if both were "the same account". This covers starting
or stopping the timer, adding, editing or deleting sessions, and changing the daily goal or reminders. Existing
history on **both** Macs must be merged once, with no data lost.

## Recommended approach (use this unless the owner tells you otherwise)

**Opt-in, serverless sync through a shared iCloud Drive folder.** The account is the owner's Apple ID.

* No server, no Supabase, no Workday sign-in, and no credentials in the app or repository.
* The app stays fully usable offline. Sync is **off by default** and is switched on in Settings.
* **Prerequisite — check it first:** both Macs are signed into the same Apple ID with iCloud Drive on. On the
  Mini, look for `~/Library/Mobile Documents/com~apple~CloudDocs/`. You cannot check the laptop, so ask the owner.
* **Fallback** if the Macs don't share an Apple ID: make the sync folder user-selectable. Any folder that a file
  syncer (Dropbox, Syncthing, …) keeps in sync then works. Build it user-selectable anyway, with iCloud Drive as
  the suggested default.
* **Not this:** a Supabase or "real account" backend. That is the separately specified *Phase 2 friends system*
  (`docs/RELEASE_AND_FRIENDS_SPEC.md`), which the owner explicitly said **not to start**. If the owner insists on
  real accounts instead of Apple-ID folder sync, stop and confirm scope with them before building anything
  server-side.

## Getting set up

1. Repository: <https://github.com/Plainset/workday> (public). Default branch `main`, currently at the commit
   "Reduce idle memory and guard against window retention (#2)" or later.
2. Clone it on the Mini (`gh repo clone Plainset/workday`). You need the Xcode Command Line Tools (Swift 6.x) and
   an authenticated `gh` CLI with push access. Check `gh auth status`; if it isn't signed in, ask the owner to run
   `gh auth login`.
3. Read these first: `docs/ARCHITECTURE.md`, `Sources/WorkdayCore/WorkStore.swift`,
   `Sources/WorkdayCore/WorkLedger.swift`, `Sources/WorkdayCore/WorkSession.swift`,
   `Sources/WorkdayCore/BackupManager.swift` (data paths and backups), `Sources/Workday/AppDelegate.swift`
   (single instance, recovery) and `Sources/Workday/SettingsView.swift`.
4. Commands:
   * Tests: `./scripts/test.sh`. Swift Testing, 54 tests. It adds the flags the Command Line Tools need.
   * Release build: `swift build -c release`.
   * App bundle: `./scripts/build_app.sh` → `dist/Workday.app`.
   * Install: `./scripts/install.sh`. It quits the running app, which **prompts to stop a running timer**. See
     "Installing" below.
5. Check what is installed on the Mini:
   `defaults read /Applications/Workday.app/Contents/Info CFBundleIdentifier`. The current id is
   `io.github.plainset.workday`. Pre-1.0 builds used `local.workday.tracker` and keep the same data folder.

## How the app stores data today (facts to build on)

* **Database:** SQLite (WAL mode) at `~/Library/Application Support/Workday/workday.sqlite`, schema version 1.
  Migrations are append-only, in `WorkStore.migrate()`; bump `schemaVersion` and add a migration test. Files are
  owner-only (0700/0600).
* **Tables:**
  * `sessions(id TEXT UUID PK, start, end NULL, state active|closed|interrupted, checkpoint, checkpoint_kind,
    detected_at, tz, created_at, updated_at)`. Times are `timeIntervalSinceReferenceDate`.
  * `settings(id=1, json)`.
  * `meta(key, value)`.
  * `events`: a local audit log.
  * `notifications_sent(day, kind)`.
* **Writes:**
  * Sessions are written through `WorkStore.upsert`.
  * Deletes are **hard deletes** (`deleteSession`), so sync needs tombstones.
  * `updateCheckpoint` writes a heartbeat on the active session frequently and deliberately doesn't bump
    `data_revision`.
* **Rules in WorkLedger:**
  * Sessions may not overlap (`LedgerError.overlaps`).
  * Only one active session at a time.
  * On launch, `detectInterruptions` turns a stale **active** session into a pending recovery, shown in
    RecoveryView.
* **Settings:**
  * Synced: `dailyGoalMinutes`, `goalNotificationEnabled`, start/stop reminder flags and times.
  * Kept per device: `launchAtLoginInitialized` and `hasCompletedFirstLaunch` (plus the login item itself).
* **Other mechanics:**
  * Single instance is enforced with a flock lock file.
  * `WORKDAY_DATA_DIR=<dir>` redirects all data, for tests and demos.
  * Backups and restore live in `BackupManager`.

## Design requirements

1. **Never put the live SQLite database in iCloud.** Each Mac keeps its own local database, which stays the
   source of truth for the UI. Sync exchanges *change records* through the shared folder.
2. **Folder layout: one writer per file.**
   * Each device writes only to `<sync folder>/Workday Sync/devices/<deviceID>/`.
   * Use an append-only, sequence-numbered change log (e.g. JSON Lines segments) plus periodic compacted
     snapshots.
   * Write to a temp file and rename into place. Tolerate a truncated last line, half-synced files and iCloud
     placeholder files (`.<name>.icloud`; call `FileManager.startDownloadingUbiquitousItem(at:)` and confirm it
     works for this non-sandboxed, ad-hoc-signed app).
   * Each device records how far it has applied every peer's log in `meta`.
3. **Identity and ordering.**
   * Generate a random `deviceID` once and store it in `meta`.
   * Give each record a timestamp plus a deviceID tie-break. A hybrid logical clock is preferred, so a skewed
     clock can't silently lose edits.
   * Merging: last-writer-wins per session and per synced settings field.
   * Deletes become tombstones that beat older edits.
   * Applying the same record twice must be a no-op (idempotent).
4. **Running timer across Macs.**
   * Add `owner_device` to sessions (schema v2 migration; existing rows belong to the local device).
   * A session active on the *other* Mac shows there as running ("Running on your other Mac"), with its live
     elapsed time.
   * **`detectInterruptions` and recovery must only touch sessions owned by this device.** Otherwise the Mini
     would flag the laptop's running session as interrupted, because it never sees a local heartbeat for it.
   * Heartbeats don't need to sync every few seconds. Sync the start, the stop and occasional checkpoints so
     that a crashed remote session can still be recovered on its own device.
   * Starting the timer while the other Mac's session is running: show which Mac is running it and offer
     "Stop it there and start here". That edit ends the remote session at now and syncs.
5. **Overlaps from merging.**
   * Two Macs may hold overlapping sessions (both logged the same hours before sync existed, or both started
     while offline).
   * Never auto-delete. Import them, list them under a "Sync conflicts" section (Settings or the day editor), and
     let the owner keep one or merge.
   * Until resolved, day and week totals must not double-count. Count the union of the overlapping time and
     document this.
6. **First enable / initial merge.**
   * Make a safety backup on enable (`BackupManager`, kind safety).
   * Publish the full local history, then import peers.
   * Session UUIDs are globally unique, so the same history on both Macs (e.g. from a restored backup) merges
     cleanly; anything else is handled by rules 3 and 5.
   * Turning sync off stops reading and writing but keeps local data.
   * Restoring a backup while sync is on must re-publish the restored state as new edits, not silently revert
     the other Mac.
7. **Goal notifications.** Sync `notifications_sent` too, so the "goal reached" notification fires once per day
   across both Macs (best effort; brief delays are fine).
8. **Freshness.**
   * Sync on launch, on wake, every ~30–60 s while running, and on local change (debounced).
   * Watch the folder with a file presenter, `NSMetadataQuery` or a dispatch source if cheap. Polling is
     acceptable.
   * Keep idle CPU and memory low. The app was just tuned to about 13 MB in the menu bar, and the `--memtest`
     harness in `SnapshotRenderer.swift` must not regress. Don't add per-second disk work.
9. **UI.**
   * Settings → a new Sync section: on/off, folder (default iCloud Drive), "Last synced", device name, and the
     other devices seen.
   * Show errors in plain language: folder missing, iCloud off, unreadable records.
   * Keep it consistent with the existing settings style.
10. **Privacy and docs.**
    * `README.md`, `PRIVACY.md` and the Settings privacy text currently promise "fully offline / no cloud sync".
      Update them: sync is optional, off by default, and data goes only to the folder the owner picks (their
      iCloud Drive).
    * Add a CHANGELOG "Unreleased" entry.
    * Document the format and merge rules in `docs/ARCHITECTURE.md`.
11. **Security.** No credentials anywhere. Create sync files with owner-only permissions. Treat records read
    from the folder as untrusted input: validate and bound them, reject malformed records without crashing, and
    never run anything from them.

## Testing (required)

* **Unit tests in `Tests/WorkdayCoreTests`:**
  * Last-writer-wins ordering, including clock skew.
  * Tombstones vs late edits.
  * Idempotent re-apply and out-of-order arrival.
  * Truncated or corrupt records.
  * Overlap import and union totals.
  * Remote active sessions not flagged by `detectInterruptions`.
  * Schema v1→v2 migration on a real v1 file.
  * Settings sync excluding device-local fields.
  * Backup restore with sync on.
* **Two-instance end-to-end test on the Mini.** Run two app instances with different `WORKDAY_DATA_DIR`
  temporary folders and a shared temporary "sync folder" (not iCloud):
  * Seed one instance with `--seed-demo`.
  * Start the timer on A and see it on B. Stop it on B; it stops on A.
  * Edit, delete, change the goal.
  * Verify both converge.
* Check the single-instance lock: it may need to key on the data dir so two test instances can run side by side.
  Verify with the existing code before changing anything.
* **Real iCloud check:** once installed on the Mini, confirm the files appear under iCloud Drive → Workday Sync.

## Hard rules

* **The owner's real data** in `~/Library/Application Support/Workday` is off limits. Read-only `sqlite3 -readonly`
  queries are the only exception. Every test or demo instance runs with `WORKDAY_DATA_DIR` set to a temporary
  folder.
* **Before installing your build, back up the real data.** In the running app use Settings → Backups → back up now;
  if that isn't possible, quit the app first and copy the data folder somewhere safe.
* **Git workflow:**
  * Work on a branch (e.g. `feat/device-sync`) and commit as you go.
  * Open a PR to `main`. Branch protection requires the checks "Build, test and validate release build" and
    "Secret scan (full history)". Wait for them to pass.
  * Never bypass protection with admin rights, force-push to `main`, or use `git push --all` or `--mirror`.
* **Attribution:**
  * Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  * PR descriptions end with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
* **The repo is public.** Never commit personal data: email addresses, real names of machines, home-directory
  paths, the owner's work data or screenshots of it.
* **Scope:**
  * Don't start Phase 2 (friends system, Supabase).
  * Don't change the bundle id.
  * Keep macOS 14 as the minimum.
  * No third-party dependencies (the project has a dependency policy check).
* **Merging:** merge the PR only with the owner's OK.

## Installing (don't disrupt a running timer)

1. Before installing on the Mini, check for a running session:
   ```
   sqlite3 -readonly ~/Library/Application\ Support/Workday/workday.sqlite "select id from sessions where state='active'"
   ```
2. If nothing is running, `./scripts/install.sh` is fine.
3. If a session is running, don't use the script's quit, which asks the owner to stop the timer. Instead:
   * Quit with SIGTERM (`pkill -TERM -x Workday`) so the session is left open.
   * Replace `/Applications/Workday.app` with `dist/Workday.app` and relaunch it.
   * The recovery panel appears. Choose **"Count the gap"** and **"Keep the timer running"**, then **Apply**. The
     session continues unbroken.
   * Ask the owner to click these if you can't drive the UI.

## The laptop side (the owner does this, or you give them the steps)

The laptop already has a clone at `~/Desktop/Code Projects/Work day tracker ` (note the trailing space in the
folder name). After the PR is merged, on the laptop the owner runs:

```
git checkout main && git pull && ./scripts/build_app.sh && ./scripts/install.sh
```

These commands are a simple install; if a timer is running there, use the "Installing" procedure above. The owner
then turns on Settings → Sync, choosing the same folder as on the Mini. Give the owner these steps written out in
your final report.

## Done means

* The PR is merged after green CI and the owner's OK, with tests covering everything under "Testing".
* The Mini runs the new build with sync on, and its history is published to the sync folder.
* The owner has the exact laptop steps.
* Your final report says what was verified for real (two-instance test, files in iCloud) and what could only be
  verified once the laptop is updated: live round trip between the real Macs, and the merge of the laptop's
  existing history.
