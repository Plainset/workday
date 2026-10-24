# Phase 1 — open-source release: final report

**Status: complete, independently approved and published** (owner authorised publication on 2026-10-24).
Phase 2 (friends system) was not started, per owner instruction.

| | |
|---|---|
| Repository | <https://github.com/Plainset/workday> — **public** |
| Approved release commit | `1e5bcff1f76367c0e509b73ea1a98cacab61a8a4`, annotated tag **`v1.0.0`** |
| Release | <https://github.com/Plainset/workday/releases/tag/v1.0.0> — published 2026-10-24 (Release workflow run 40092371464; assets verified: checksums, id, 1.0.0 build 37, universal, signature, DMG) |
| Review | 4 cycles; reviewers A (functional), B (security & privacy), C (architecture), D (release readiness) all **APPROVED** the exact commit — `docs/review-ledger.md` |
| Tests | 53 Swift Testing tests, all passing locally and in CI (macOS 15 runner, Xcode 16.4) |
| CI | build, tests, dependency policy, release-build validation, full-history gitleaks scan — green on `1e5bcff` |
| Artefacts | `Workday-1.0.0-macOS.zip`, `.dmg`, `SHA256SUMS.txt` via `scripts/package_release.sh` (universal, ad-hoc signed, **not notarised**) |
| Minimum macOS | 14.0 Sonoma |
| Bundle id | `io.github.plainset.workday` |

## What was done

* **Audit** (`docs/SECURITY_AUDIT.md`): no secrets in any commit (gitleaks + pattern scans), no databases/backups/keys
  ever committed. Personal information found — author emails with account name and hostnames, and the home path in
  committed build logs — was removed by an owner-approved history rewrite (`docs/HISTORY_REWRITE.md`); the original
  history is kept only on the local branch `backup/pre-public-rewrite`, never pushed. No third-party dependencies;
  all code and assets original; MIT licence.
* **App hardening:** owner-only (0700/0600) data folder, database, lock file and backups, including files created by
  older builds; strict schema-version read; newer schemas refused; IPC no longer broadcasts the data path.
* **Docs:** README (screenshots, install incl. macOS 14 vs 15+ first-launch steps, build), LICENSE, CONTRIBUTING,
  SECURITY, PRIVACY, CHANGELOG, `docs/RELEASING.md` (signing, notarisation, going-public checklist).
* **Distribution:** reproducible packaging; install/update never touches user data (verified: upgrade from the v1
  baseline keeps all sessions bit-identical); first install from the DMG verified.
* **GitHub:** private repo, CI and tag-triggered *draft* release workflow; read-only default token, SHA-pinned
  actions, no secrets, `pull_request` only; Dependabot for actions.

## Publication (done with owner authorisation)

* Repository made public; only `main` and tag `v1.0.0` are on GitHub (the backup branch remains local).
* Enabled: private vulnerability reporting, Dependabot alerts and security updates, secret scanning with push
  protection, approval for first-time contributors' workflows, and branch protection on `main` (required checks
  *Build, test and validate release build* and *Secret scan (full history)*; no force pushes or deletion).
* Tag `v1.0.0` pushed → Release workflow built, validated and drafted the release → artefacts downloaded and verified
  → release published.

## Remaining owner actions

1. **Optional, for notarised builds** — Developer ID Application certificate + `xcrun notarytool store-credentials`,
   then `DEVELOPER_ID_APPLICATION=… NOTARY_PROFILE=… ./scripts/package_release.sh` and upload the notarised ZIP/DMG
   (v1.0.0 artefacts are ad-hoc signed and not notarised).
2. **Your installed copy** still runs a pre-1.0 build (`local.workday.tracker`). After installing 1.0.0
   (`./scripts/install.sh` or the DMG): remove the stale "Workday" entry in Login Items if listed, allow
   notifications again, and switch launch at login off if you don't want it.
3. Keep `backup/pre-public-rewrite` local (or move it to an off-repo `git bundle`); never `git push --all/--mirror`.

## Not verified (environment-limited)

Real Gatekeeper "Open Anyway" flow on a quarantined download; Developer ID signing/notarisation (no credentials);
the Release workflow and repository settings are now verified (see above).
