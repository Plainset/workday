Workday — native macOS work-hours tracker with an animated orange-liquid calendar. Fully offline; no account.
See CHANGELOG.md for what's new.

**Install:** download the DMG (or ZIP), drag **Workday** into **Applications**. Requires macOS 14 or later.

**First launch (this build is ad-hoc signed and not notarised):**
- macOS 15 Sequoia and later: open Workday once, dismiss the warning, then go to **System Settings → Privacy &
  Security**, scroll to *"Workday" was blocked…* and click **Open Anyway**.
- macOS 14 Sonoma: right-click Workday in Applications → **Open** → **Open**.

Your data stays in `~/Library/Application Support/Workday/`; updating replaces only the app.
Verify downloads with `SHA256SUMS.txt` (`shasum -a 256 -c SHA256SUMS.txt`).
