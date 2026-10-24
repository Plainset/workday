# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report privately through GitHub: **Security → Report a vulnerability** on this repository
(private vulnerability reporting). If that option isn't available, open an issue titled "Security contact
request" **without any details**, and the maintainer will reply with a private channel. Include in your report:

* the affected version and macOS version,
* steps to reproduce or a proof of concept,
* the impact you believe it has.

You can expect an acknowledgement within 7 days and a status update within 30 days. Fixes are released as a new
version and credited in the changelog unless you prefer to stay anonymous.

## Scope

In scope: the Workday app, its build and release scripts, and the GitHub Actions workflows in this repository.
Workday is offline and stores data locally (see [PRIVACY.md](PRIVACY.md)); issues that let another local user,
process or file read or alter a user's work history, or that make the app run untrusted code, are especially
relevant.

## Handling of secrets

The repository contains no credentials. Signing and notarisation credentials are provided only through the release
maintainer's environment or encrypted CI secrets and are never used by workflows triggered from pull requests.
Every push and pull request is scanned for secrets in CI.
