# Contributing to Workday

Thanks for your interest! Bug reports, fixes and thoughtful improvements are welcome.

## Before you start

* For anything larger than a small fix, open an issue first to discuss the idea.
* Workday is deliberately **offline, private and dependency-free**. Changes that add network access, telemetry or
  third-party packages need a strong reason and prior discussion.
* Keep the liquid calendar's look and feel intact; UI changes should include before/after screenshots.

## Development setup

Requirements: macOS 14+, Swift 6 (Xcode 16+ or the Command Line Tools).

```bash
./scripts/test.sh                                   # tests
./scripts/build_app.sh                              # dist/Workday.app
WORKDAY_DATA_DIR=/tmp/workday-dev dist/Workday.app/Contents/MacOS/Workday --seed-demo --show-calendar
```

Use `WORKDAY_DATA_DIR` while developing so you never touch your real work history. Point it at a dedicated empty
folder: Workday makes its data folder owner-only (0700), including an existing one. Never commit databases,
backups (`*.sqlite`, `Backups/`) or anything containing personal data — `.gitignore` blocks the common cases.

`Workday --snapshot <dir>` renders screenshots of the main views from demo data, which is handy for reviewing UI
changes.

## Code guidelines

* Domain logic (time accounting, persistence, recovery, backups) belongs in `Sources/WorkdayCore` with tests in
  `Tests/WorkdayCoreTests`. UI belongs in `Sources/Workday`.
* All totals must come from `WorkLedger`; never accrue time from timers or UI ticks.
* Keep database changes in migrations (`WorkStore.migrate`) that preserve existing user data.
* Match the surrounding style; prefer small, focused pull requests.

## Pull requests

1. Fork and create a branch.
2. Make your change with tests where it makes sense.
3. Run `./scripts/test.sh` and `./scripts/build_app.sh`.
4. Describe what changed and why; add screenshots for UI changes.

CI builds, tests and scans every pull request. By contributing you agree that your contribution is licensed under
the MIT licence of this project.

## Code of conduct

Be kind and constructive. Harassment or discrimination of any kind is not tolerated.
