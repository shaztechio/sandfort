# Releasing

Cutting a release is one command:

```sh
make release
```

That bumps the patch version, runs the tests, commits, tags, and pushes. Pushing
the tag starts the signed build in GitHub Actions, which notarizes the app and
publishes a GitHub Release with the archive and its SHA-256.

For a version that is not a patch bump:

```sh
make release VERSION=1.3.0
```

Preview without changing anything:

```sh
./tools/packaging/release.sh --dry-run
```

## The version lives in Info.plist, not in the tag

`tools/packaging/Info.plist` is the single source of truth. The tag is derived
from it, never the reverse.

That direction is deliberate. A tag cannot change what is inside a built app, so
letting the tag lead would allow a release named `v1.2.3` containing an app that
reports `0.16.0`. The workflow fails the build when the two disagree; `make
release` makes them agree by construction.

Two values change on every release:

- `CFBundleShortVersionString` — the visible version, `x.y.z`.
- `CFBundleVersion` — the build number, which only ever increases, across every
  version. macOS treats a lower build number as a downgrade even when the
  visible version went up.

The short version also keys Help Viewer's cache, which is why a help change can
look like it did not take effect until the version moves. See
[CONTRIBUTING.md](../CONTRIBUTING.md).

## What `make release` refuses to do

It stops before changing anything if:

- the current branch is not `main`,
- the working tree has uncommitted changes,
- `main` and `origin/main` differ,
- the tag already exists.

Tests run before the version is committed, so a failing test leaves nothing
behind. The push is confirmed interactively, because it publishes publicly;
answering anything but `y` deletes the local commit and tag.

## One-time setup

The signed build needs six repository secrets. Without them the workflow builds
and then fails in the signing step.

1. **Enrol in the Apple Developer Program** and create a **Developer ID
   Application** certificate: Xcode → Settings → Accounts → Manage Certificates
   → **+**. An "Apple Development" certificate is a different type and cannot
   sign for distribution.
2. **Export it as a .p12** from Keychain Access, expanding the certificate first
   to confirm its private key is included. Exporting the certificate without the
   key is the usual mistake; it signs nothing.
3. **Create an app-specific password** at
   [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security. A
   normal Apple ID password will not notarize.
4. **Set the secrets.** Put the values in a 1Password item with one field per
   secret name, export it as JSON, then:

   ```sh
   ./tools/packaging/set-release-secrets.sh <export.json>
   ```

   It validates everything before sending any of it, passes values over stdin
   rather than as arguments, and prints only names and lengths. Delete the export
   afterwards: it holds a signing key and an app-specific password.

   Or set them by hand under Settings → Secrets and variables → Actions:

   | Secret | Value |
   | --- | --- |
   | `APPLE_CERTIFICATE_P12` | the .p12, base64 encoded |
   | `APPLE_CERTIFICATE_PASSWORD` | the .p12 export password |
   | `APPLE_SIGN_IDENTITY` | `Developer ID Application: NAME (TEAMID)` |
   | `APPLE_ID` | the Apple ID email |
   | `APPLE_TEAM_ID` | the Developer Team ID |
   | `APPLE_APP_PASSWORD` | the app-specific password |

## Signing locally

`make signed-app` does the same signing and notarization on your Mac, against
whatever `make app` last built. It expects notarization credentials in a
keychain profile:

```sh
xcrun notarytool store-credentials sandfort --apple-id you@example.com --team-id TEAMID
```

## The Apple Events entitlement is load-bearing

Notarization requires the hardened runtime, and the hardened runtime refuses to
send Apple Events unless the app carries
`com.apple.security.automation.apple-events`. Sandfort drives UTM entirely
through Apple Events: starting a VM, stopping one, and removing old
registrations during Rebuild. Measured against UTM 4.7.5 with a signed app
bundle:

| Signing | Result |
| --- | --- |
| hardened runtime, no entitlement | `-1743` `errAEEventNotPermitted`, no prompt |
| hardened runtime, with the entitlement | delivered normally |

Without it a notarized build installs, launches, and never starts a VM, silently:
`-1743` is treated as "the user declined Automation", so the app falls back
rather than reporting an error. The entitlement lives in
`tools/packaging/Sandfort.entitlements`, and both the local script and the
workflow refuse to continue if it is missing from the signed app.

## After a release

The workflow verifies the notarized bundle before publishing — `codesign
--verify --strict`, `spctl --assess`, `stapler validate`, and the entitlement
check. None of that proves the app still works.

Download the published archive and confirm the thing only a real run can show:
**quit UTM, create an environment, and watch the VM start on its own.** That is
the behaviour the hardened runtime can silently break.
