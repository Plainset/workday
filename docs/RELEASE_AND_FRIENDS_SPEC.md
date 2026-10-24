# Open-source release & friends system — requirements

The owner's brief for the open-source release (Phase 1) and the optional friends system (Phase 2). This is the
authority reviewers check against.

## Mission

Extend the existing, fully functional macOS Workday application into a publicly available open-source project,
followed by an optional online friends system. Two strictly sequential phases: Phase 1 prepare and release the
existing application as an open-source GitHub project; Phase 2 implement an optional Supabase-powered friends
system. Phase 1 must be independently approved before Phase 2 begins. Preserve the existing application's
functionality, visual design, local database and user data.

## Phase 1 — Open-source release

1. **Repository and security audit** — inspect the project and its complete Git history for exposed keys, tokens,
   passwords and credentials; personal information, usage history, databases and backups; hardcoded
   machine-specific paths, usernames and private configuration; development artefacts and unnecessary binaries;
   dependency vulnerabilities and licensing restrictions; copyright/redistribution restrictions of code, assets,
   images and fonts; security vulnerabilities in the app. Revoke/rotate any discovered secret; remove sensitive
   history where necessary and verify it is gone from the published history. Keep databases, backups, Keychain
   data and personal information out of the repository. Document findings and remediation.
2. **Licensing and documentation** — MIT if compatible; README.md (overview, screenshots, functionality,
   installation, build), LICENSE, CONTRIBUTING.md, SECURITY.md, PRIVACY.md, CHANGELOG.md, .gitignore. Clear
   structure; buildable by another developer from the published instructions.
3. **Build and distribution** — native macOS; clean build from a fresh checkout; documented minimum macOS;
   reproducible packaging; Developer ID signing and notarisation where credentials are available (otherwise
   complete everything possible, document remaining steps, never claim a signed/notarised build that wasn't
   produced); release artefact for GitHub Releases; installs/updates must not overwrite user data; test first
   installation, launch, menu-bar behaviour, timer persistence and local database access. No certificates,
   passwords or keys committed.
4. **GitHub repository and CI** — existing repository, preserved meaningful history, everything committed.
   GitHub Actions: compile, run tests, detect dependency vulnerabilities, check for committed secrets, validate
   release builds; least-privilege permissions; protect credentials; never run untrusted PR code with privileged
   secrets. Initial release v1.0.0 = fully offline Workday, without Supabase/friends. Independent security and
   licensing review before going public. **Publication gate:** explicit owner authorisation before making the
   repository public or publishing release artefacts; otherwise leave it ready and record the pending approval.

## Phase 2 — Friends system (separate branch, only after Phase 1 approval)

5. **Architecture** — Supabase (Auth, Postgres with RLS, Realtime where useful); no extra backend server unless
   strictly necessary. The local database stays authoritative for work sessions; timer, menu bar, calendar and
   history keep working fully offline; no account required to use Workday.
6. **Accounts and profiles** — optional registration, sign in/out, unique username and display name, edit
   profile, change password / recover access, delete account and cloud data, disable online features without
   losing local history. Credentials in the macOS Keychain; never store passwords.
7. **Friends** — exact-username search, send/receive/accept/reject requests, cancel outgoing, remove friends,
   block users, view accepted friends, see friends' daily hours, view friends' orange-liquid calendars, compare
   daily and weekly totals. Consistent with the existing design and liquid animations; calendar sharing and simple
   comparisons over leaderboards/gamification.
8. **Privacy** — hours not public by default; users control whether friends see hours/calendars; upload only
   minimal aggregated daily hours (never session timestamps, database files, usage/browser activity, backups or
   device information); removed/blocked friends lose access; easy setting to disable sharing and stop uploads;
   clear explanation of local vs Supabase data.
9. **Supabase security** — schema, migrations and policies in the repo; RLS on every exposed table; ownership and
   accepted-friendship checks in the database; no access to others' private data; no service-role/privileged
   credentials in the client; validate inputs; prevent modification of others' records; limits on invitations
   and username searches; protection against friendship enumeration and unauthorised subscriptions; account
   deletion removes/anonymises cloud data; least database privilege; validate with independent test accounts
   (including after removal and blocking); document and test the policies.
10. **Sync and offline** — offline-first; timer records locally regardless of network; reliable idempotent sync of
    permitted daily aggregates; handle network interruptions, restarts, auth expiry, failed syncs, historical
    edits, corrected totals, revoked friendships, privacy changes; never replace valid local data with empty or
    stale cloud data; explicit timestamps, identity and deterministic update rules; sign-out/account deletion never
    deletes local history.

## Process (both phases)

Implement → Build → Test → Commit → Independent review → Fix → Rebuild → Retest → Commit → Independent review,
until complete. Reviewers inspect the actual repository and app, run relevant tests and give specific findings:
**A** functional correctness/no regressions, **B** security & privacy, **C** architecture & code quality
(maintainability, reliability, local DB integrity, offline operation, sync, unnecessary complexity), **D** release
readiness (docs, installation, workflows, artefacts, licensing, versioning, distribution). Every finding is fixed
and independently verified or documented as a genuine blocker; a persistent review ledger records findings,
corrections, evidence and the exact commit assessed. Completion requires: original functionality intact; security
and licence checks pass; clean-checkout build; documented/verified installation and release (as far as permissions
allow); offline use without account; friends work with multiple real test accounts; privacy enforced by the
backend; offline/online sync tests pass; no unresolved critical/high findings; reviewers approve the exact final
commit; final SHA, test results, ledger and outstanding owner approvals reported. External approval gates (GitHub
publication, Apple signing credentials, Supabase account access) must not be bypassed.
