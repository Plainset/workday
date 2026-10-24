# Releasing Workday

## Versioning

`VERSION` holds the version (Semantic Versioning). `scripts/build_app.sh` writes it into `Info.plist`
(`CFBundleShortVersionString`); `CFBundleVersion` is the commit count. The release tag must be `v<VERSION>`.

Minimum macOS: **14.0 Sonoma** (`LSMinimumSystemVersion`, `Package.swift` platforms). Universal binary
(arm64 + x86_64).

## Building release artefacts locally

```bash
./scripts/package_release.sh
```

Produces in `dist/release/`:

* `Workday-<version>-macOS.zip` — the app bundle
* `Workday-<version>-macOS.dmg` — disk image with an Applications shortcut
* `SHA256SUMS.txt`

### Developer ID signing and notarisation (optional, needs an Apple Developer account)

Credentials are supplied through the environment only and must never be committed.

1. Install your **Developer ID Application** certificate in the login keychain
   (`security find-identity -v -p codesigning` should list it).
2. Store notarisation credentials once:
   `xcrun notarytool store-credentials workday-notary --apple-id <id> --team-id <TEAMID>`
   (uses an app-specific password, kept in the keychain).
3. Build:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: <Name> (<TEAMID>)" \
NOTARY_PROFILE=workday-notary \
./scripts/package_release.sh
```

The script signs with the hardened runtime and a secure timestamp, notarises and staples both the app and the
DMG, and finishes with `spctl --assess`. Without these variables the app is **ad-hoc signed and not notarised** —
say so in the release notes.

> Status for v1.0.0: no Developer ID identity was available on the build machine, so v1.0.0 artefacts are ad-hoc
> signed and not notarised. The steps above are the remaining owner action to ship notarised builds.

## Release via GitHub

1. Update `VERSION` and `CHANGELOG.md`, commit, make sure CI is green.
2. Tag and push: `git tag -a v1.0.0 -m "Workday 1.0.0" && git push origin v1.0.0`.
3. The **Release** workflow tests, packages and creates a **draft** release with the artefacts and checksums.
4. Review the draft (optionally replace the artefacts with locally notarised ones) and publish it manually.

## Install / update behaviour

Installing or updating replaces only `/Applications/Workday.app`. User data lives in
`~/Library/Application Support/Workday/` and is never touched by installation; the database schema is migrated
in place on launch and a newer schema is refused rather than overwritten. `scripts/install.sh` quits a running
copy first (asking to stop a running timer).

## Release checklist

- [ ] `./scripts/test.sh` passes
- [ ] `./scripts/package_release.sh` succeeds; `SHA256SUMS.txt` verifies
- [ ] Fresh install on a clean user account: first launch opens the calendar, menu bar item appears, timer
      start/stop persists across relaunch, data folder created with 0700 permissions
- [ ] Update over an existing install keeps all sessions and settings
- [ ] CI (build, tests, secret scan) green on the tagged commit
